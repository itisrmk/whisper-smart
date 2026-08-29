//! Microphone capture via cpal.
//!
//! Port of `AudioCaptureService.swift`. macOS uses AVAudioEngine with an
//! `AVAudioConverter`; here cpal opens the device in whatever format the
//! hardware offers (PipeWire's ALSA or PulseAudio bridge, in practice) and this
//! module does the format work itself: interleaved multi-channel samples of any
//! type are downmixed to mono, resampled to 16 kHz, and emitted as the
//! `i16` PCM every STT engine in this app expects.
//!
//! Two things leave the capture thread:
//!   * a normalised 0..=1 level, for the overlay and the speech detector;
//!   * the PCM itself, pushed to whichever provider is currently installed.

use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use crossbeam_channel::Sender;

use crate::core::state_machine::{AudioCapturing, Event};

/// Sample rate every STT engine in this app is fed at.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// Level updates roughly every 50 ms, matching the macOS tap size.
const LEVEL_INTERVAL_SAMPLES: usize = (TARGET_SAMPLE_RATE as usize) / 20;

/// Where captured PCM is delivered. Swapped when the provider changes.
pub type PcmSink = Arc<Mutex<Option<Sender<Vec<i16>>>>>;

pub struct AudioCapture {
    /// Events (level, errors) destined for the state machine.
    events: Sender<Event>,
    pcm_sink: PcmSink,
    /// Held for as long as capture runs; dropping it closes the stream.
    stream: Option<cpal::platform::Stream>,
}

// cpal's Stream is not Send on some backends, and the capture is only ever
// started and stopped from the main loop, so the struct stays on that thread.
impl AudioCapture {
    pub fn new(events: Sender<Event>, pcm_sink: PcmSink) -> Self {
        Self {
            events,
            pcm_sink,
            stream: None,
        }
    }
}

impl AudioCapturing for AudioCapture {
    fn start(&mut self, device_name: &str) -> Result<(), String> {
        // An already-running stream would double-feed the provider.
        self.stop();

        let host = cpal::default_host();
        let device = resolve_device(&host, device_name)?;
        let supported = device
            .default_input_config()
            .map_err(|e| format!("No usable input configuration: {e}"))?;

        let sample_format = supported.sample_format();
        let config: cpal::StreamConfig = supported.config();
        let channels = config.channels as usize;
        let source_rate = config.sample_rate;

        if channels == 0 || source_rate == 0 {
            return Err("The input device reported an unusable format.".to_string());
        }

        let mut converter = Converter::new(source_rate, channels);
        let events = self.events.clone();
        let sink = Arc::clone(&self.pcm_sink);

        let error_events = self.events.clone();
        let error_callback = move |err: cpal::Error| {
            tracing::error!("audio stream error: {err}");
            let _ = error_events.send(Event::AudioError(format!(
                "Microphone capture stopped: {err}"
            )));
        };

        // The callback body is identical across sample formats; only the
        // incoming slice type differs, so it is generic over the conversion.
        macro_rules! build {
            ($ty:ty, $to_f32:expr) => {{
                let to_f32: fn($ty) -> f32 = $to_f32;
                device.build_input_stream::<$ty, _, _>(
                    config.clone(),
                    move |data: &[$ty], _| {
                        let mono: Vec<f32> = data.iter().copied().map(to_f32).collect();
                        converter.push(&mono, &events, &sink);
                    },
                    error_callback,
                    None,
                )
            }};
        }

        let stream = match sample_format {
            cpal::SampleFormat::F32 => build!(f32, |s| s),
            cpal::SampleFormat::I16 => build!(i16, |s| s as f32 / 32_768.0),
            cpal::SampleFormat::U16 => build!(u16, |s| (s as f32 - 32_768.0) / 32_768.0),
            cpal::SampleFormat::I32 => build!(i32, |s| s as f32 / 2_147_483_648.0),
            cpal::SampleFormat::I8 => build!(i8, |s| s as f32 / 128.0),
            cpal::SampleFormat::U8 => build!(u8, |s| (s as f32 - 128.0) / 128.0),
            other => {
                return Err(format!("Unsupported microphone sample format: {other:?}"));
            }
        }
        .map_err(|e| format!("Could not open the microphone: {e}"))?;

        stream
            .play()
            .map_err(|e| format!("Could not start the microphone: {e}"))?;
        tracing::info!(
            "capture started: {} ch @ {} Hz ({:?})",
            channels,
            source_rate,
            sample_format
        );
        self.stream = Some(stream);
        Ok(())
    }

    fn stop(&mut self) {
        if let Some(stream) = self.stream.take() {
            let _ = stream.pause();
            drop(stream);
            tracing::debug!("capture stopped");
        }
    }
}

fn resolve_device(
    host: &cpal::platform::Host,
    wanted: &str,
) -> Result<cpal::platform::Device, String> {
    let wanted = wanted.trim();
    if !wanted.is_empty() {
        if let Ok(devices) = host.input_devices() {
            for device in devices {
                if device.to_string() == wanted {
                    return Ok(device);
                }
            }
        }
        // A device that has been unplugged should not block dictation
        // entirely; fall back to the system default and say so.
        tracing::warn!("input device {wanted:?} not found; falling back to the default");
    }

    host.default_input_device().ok_or_else(|| {
        "No microphone is available. Check your PipeWire/PulseAudio setup.".to_string()
    })
}

/// Lists selectable input devices for the settings UI.
///
/// cpal's ALSA host enumerates every entry in the ALSA config, which on a
/// normal desktop means a couple of real microphones buried in ~30 plugin
/// pseudo-devices ("Rate Converter Plugin", "Plugin for channel upmix", …).
/// Presenting that raw would make the picker unusable, so entries that cannot
/// actually capture are dropped and duplicate names collapsed.
pub fn list_input_devices() -> Vec<String> {
    let host = cpal::default_host();
    let devices = match host.input_devices() {
        Ok(devices) => devices,
        Err(err) => {
            tracing::error!("could not enumerate input devices: {err}");
            return Vec::new();
        }
    };

    let mut names: Vec<String> = Vec::new();
    for device in devices {
        let name = device.to_string();
        if !is_selectable_input_name(&name) {
            continue;
        }
        // The authoritative test: a device that cannot report an input config
        // cannot be recorded from.
        if device.default_input_config().is_err() {
            continue;
        }
        // Duplicate names cannot be told apart in a picker anyway, and
        // `resolve_device` would pick the first either way.
        if !names.iter().any(|existing| existing == &name) {
            names.push(name);
        }
    }
    names
}

/// Rejects ALSA plumbing that is technically enumerable but never what a user
/// means by "my microphone".
fn is_selectable_input_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    const REJECTED_SUBSTRINGS: &[&str] = &[
        "plugin",
        "rate converter",
        "surround output",
        "discard all samples",
        "output to front",
        "upmix",
        "downmix",
    ];
    if REJECTED_SUBSTRINGS
        .iter()
        .any(|needle| lower.contains(needle))
    {
        return false;
    }
    // Sound-server entry points are real and useful (they follow whatever the
    // user picked in their mixer), so they are deliberately kept.
    !lower.is_empty()
}

/// Downmixes to mono, resamples to 16 kHz, and emits level + PCM.
struct Converter {
    source_rate: u32,
    channels: usize,
    /// Fractional read position into the mono stream, for linear resampling.
    position: f64,
    /// Last sample of the previous block, so interpolation spans block edges.
    previous: f32,
    have_previous: bool,
    /// Accumulates resampled output until a level update is due.
    pending: Vec<i16>,
    /// Sum of squares for the RMS level of the pending block.
    energy: f64,
    energy_count: usize,
}

impl Converter {
    fn new(source_rate: u32, channels: usize) -> Self {
        Self {
            source_rate,
            channels,
            position: 0.0,
            previous: 0.0,
            have_previous: false,
            pending: Vec::with_capacity(LEVEL_INTERVAL_SAMPLES * 2),
            energy: 0.0,
            energy_count: 0,
        }
    }

    fn push(&mut self, interleaved: &[f32], events: &Sender<Event>, sink: &PcmSink) {
        if interleaved.is_empty() {
            return;
        }

        let mono = downmix(interleaved, self.channels);
        let step = self.source_rate as f64 / TARGET_SAMPLE_RATE as f64;

        // Linear resample. `position` is relative to the start of `mono`, with
        // index -1 meaning "the last sample of the previous block", which is
        // what keeps successive blocks from clicking at the seam.
        while self.position < mono.len() as f64 {
            let idx = self.position.floor();
            let frac = (self.position - idx) as f32;
            let i = idx as isize;

            let a = if i < 0 {
                if self.have_previous {
                    self.previous
                } else {
                    mono[0]
                }
            } else {
                mono[i as usize]
            };
            let b = {
                let next = i + 1;
                if next < mono.len() as isize {
                    mono[next as usize]
                } else {
                    // Not enough data yet: stop and resume on the next block.
                    break;
                }
            };

            let sample = a + (b - a) * frac;
            self.energy += (sample as f64) * (sample as f64);
            self.energy_count += 1;
            self.pending.push(to_i16(sample));
            self.position += step;

            if self.pending.len() >= LEVEL_INTERVAL_SAMPLES {
                self.flush(events, sink);
            }
        }

        self.previous = *mono.last().unwrap_or(&0.0);
        self.have_previous = true;
        // Carry the fractional remainder into the next block.
        self.position -= mono.len() as f64;
    }

    fn flush(&mut self, events: &Sender<Event>, sink: &PcmSink) {
        if self.pending.is_empty() {
            return;
        }

        let level = if self.energy_count > 0 {
            normalized_level((self.energy / self.energy_count as f64).sqrt() as f32)
        } else {
            0.0
        };
        self.energy = 0.0;
        self.energy_count = 0;

        let chunk = std::mem::take(&mut self.pending);
        self.pending = Vec::with_capacity(LEVEL_INTERVAL_SAMPLES * 2);

        if let Ok(guard) = sink.lock() {
            if let Some(tx) = guard.as_ref() {
                // A full or closed channel means the provider went away
                // mid-session; dropping the chunk is better than blocking the
                // audio thread.
                let _ = tx.try_send(chunk);
            }
        }

        let _ = events.try_send(Event::AudioLevel(level));
    }
}

fn downmix(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    interleaved
        .chunks_exact(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

fn to_i16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * 32_767.0) as i16
}

/// Maps roughly -50 dB…0 dB RMS onto 0…1, matching the macOS build so the
/// 0.08 speech threshold means the same thing on both platforms.
pub fn normalized_level(rms: f32) -> f32 {
    let db = 20.0 * rms.max(0.000_01).log10();
    ((db + 50.0) / 50.0).clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_reads_as_zero_and_full_scale_reads_as_one() {
        assert_eq!(normalized_level(0.0), 0.0);
        assert!(normalized_level(1.0) >= 0.999);
    }

    #[test]
    fn a_normal_speaking_level_lands_above_the_speech_threshold() {
        // -40 dBFS RMS is quiet speech; it must still register as speech or
        // the "no speech detected" shortcut would swallow real dictation.
        let quiet_speech = 10f32.powf(-40.0 / 20.0);
        assert!(
            normalized_level(quiet_speech) >= crate::core::state_machine::SPEECH_LEVEL_THRESHOLD,
            "quiet speech must clear the threshold"
        );
    }

    #[test]
    fn room_tone_stays_below_the_speech_threshold() {
        // -55 dBFS is below the mapped floor, so it clamps to zero.
        let room_tone = 10f32.powf(-55.0 / 20.0);
        assert!(normalized_level(room_tone) < crate::core::state_machine::SPEECH_LEVEL_THRESHOLD);
    }

    #[test]
    fn stereo_is_averaged_to_mono() {
        let interleaved = [1.0, 0.0, 0.5, 0.5];
        assert_eq!(downmix(&interleaved, 2), vec![0.5, 0.5]);
    }

    #[test]
    fn mono_input_passes_through_untouched() {
        let mono = [0.1, 0.2, 0.3];
        assert_eq!(downmix(&mono, 1), mono.to_vec());
    }

    #[test]
    fn a_partial_frame_at_the_end_of_a_block_is_dropped_rather_than_skewed() {
        // chunks_exact leaves the remainder out: half a stereo frame averaged
        // as if it were whole would halve that sample's amplitude.
        let interleaved = [1.0, 1.0, 1.0];
        assert_eq!(downmix(&interleaved, 2), vec![1.0]);
    }

    #[test]
    fn sample_conversion_clamps_instead_of_wrapping() {
        assert_eq!(to_i16(2.0), 32_767);
        assert_eq!(to_i16(-2.0), -32_767);
        assert_eq!(to_i16(0.0), 0);
    }

    #[test]
    fn resampling_48k_to_16k_produces_a_third_of_the_samples() {
        let (events_tx, events_rx) = crossbeam_channel::unbounded();
        let (pcm_tx, pcm_rx) = crossbeam_channel::unbounded();
        let sink: PcmSink = Arc::new(Mutex::new(Some(pcm_tx)));

        let mut converter = Converter::new(48_000, 1);
        // One second of 48 kHz mono at a steady level.
        let block: Vec<f32> = (0..48_000)
            .map(|i| ((i % 100) as f32 / 100.0) - 0.5)
            .collect();
        converter.push(&block, &events_tx, &sink);
        converter.flush(&events_tx, &sink);

        let produced: usize = pcm_rx.try_iter().map(|c| c.len()).sum();
        // Allow a couple of samples of slack for the block-edge remainder.
        assert!(
            (produced as i64 - 16_000).abs() <= 4,
            "expected ~16000 samples at 16 kHz, got {produced}"
        );
        assert!(
            events_rx.try_iter().count() > 0,
            "level updates should be emitted"
        );
    }

    #[test]
    fn resampling_is_a_passthrough_when_the_device_is_already_16k() {
        let (events_tx, _events_rx) = crossbeam_channel::unbounded();
        let (pcm_tx, pcm_rx) = crossbeam_channel::unbounded();
        let sink: PcmSink = Arc::new(Mutex::new(Some(pcm_tx)));

        let mut converter = Converter::new(TARGET_SAMPLE_RATE, 1);
        let block: Vec<f32> = (0..1_600).map(|i| (i as f32 / 1_600.0) - 0.5).collect();
        converter.push(&block, &events_tx, &sink);
        converter.flush(&events_tx, &sink);

        let produced: usize = pcm_rx.try_iter().map(|c| c.len()).sum();
        assert!((produced as i64 - 1_600).abs() <= 2, "got {produced}");
    }

    #[test]
    fn conversion_survives_a_provider_with_no_sink_attached() {
        let (events_tx, _rx) = crossbeam_channel::unbounded();
        let sink: PcmSink = Arc::new(Mutex::new(None));
        let mut converter = Converter::new(48_000, 2);
        converter.push(&[0.1; 960], &events_tx, &sink);
        converter.flush(&events_tx, &sink);
        // Reaching here without panicking is the assertion: audio arriving
        // before a provider is installed must not take the app down.
    }

    #[test]
    fn alsa_plumbing_is_not_offered_as_a_microphone() {
        for name in [
            "Rate Converter Plugin Using Libav/FFmpeg Library",
            "Plugin for channel upmix (4,6,8)",
            "Plugin using Speex DSP (resample, agc, denoise, echo, dereverb)",
            "Discard all samples (playback) or generate zero samples (capture)",
            "5.1 Surround output to Front, Center, Rear and Subwoofer speakers",
        ] {
            assert!(
                !is_selectable_input_name(name),
                "{name} should be filtered out"
            );
        }
    }

    #[test]
    fn real_devices_and_sound_servers_are_kept() {
        for name in [
            "PipeWire Sound Server",
            "PulseAudio Sound Server",
            "Default Audio Device",
            "USB Audio, USB Audio",
            "HD-Audio Generic",
        ] {
            assert!(is_selectable_input_name(name), "{name} should be offered");
        }
    }

    #[test]
    fn enumeration_never_returns_duplicate_names() {
        // Duplicate entries cannot be told apart in a picker, and selecting by
        // name would resolve to the first one regardless.
        let devices = list_input_devices();
        let mut sorted = devices.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(
            sorted.len(),
            devices.len(),
            "duplicate device names: {devices:?}"
        );
    }
}

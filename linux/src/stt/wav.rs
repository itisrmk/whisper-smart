//! WAV encoding for engines that take a file or an upload rather than raw PCM.
//!
//! Port of `AudioWAVEncoding.swift`. 16 kHz mono 16-bit is the format every
//! engine in this app agrees on, so there is exactly one encoder.

use std::io::Cursor;
use std::path::{Path, PathBuf};

use crate::platform::audio::TARGET_SAMPLE_RATE;

fn spec() -> hound::WavSpec {
    hound::WavSpec {
        channels: 1,
        sample_rate: TARGET_SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    }
}

/// Encodes PCM to an in-memory WAV, for HTTP uploads.
pub fn encode_to_bytes(pcm: &[i16]) -> anyhow::Result<Vec<u8>> {
    let mut buffer = Cursor::new(Vec::new());
    {
        let mut writer = hound::WavWriter::new(&mut buffer, spec())?;
        for sample in pcm {
            writer.write_sample(*sample)?;
        }
        writer.finalize()?;
    }
    Ok(buffer.into_inner())
}

/// Writes PCM to a WAV file, for engines that only accept a path.
pub fn write_to_file(pcm: &[i16], path: &Path) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut writer = hound::WavWriter::create(path, spec())?;
    for sample in pcm {
        writer.write_sample(*sample)?;
    }
    writer.finalize()?;
    Ok(())
}

/// A scratch WAV that deletes itself when dropped, so a crashed or cancelled
/// transcription cannot leave recorded audio lying around on disk.
pub struct ScratchWav {
    path: PathBuf,
}

impl ScratchWav {
    pub fn create(pcm: &[i16], dir: &Path, name: &str) -> anyhow::Result<Self> {
        let path = dir.join(name);
        write_to_file(pcm, &path)?;
        Ok(Self { path })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for ScratchWav {
    fn drop(&mut self) {
        if let Err(err) = std::fs::remove_file(&self.path) {
            if err.kind() != std::io::ErrorKind::NotFound {
                tracing::warn!(
                    "could not remove scratch audio {}: {err}",
                    self.path.display()
                );
            }
        }
    }
}

/// Duration of a PCM buffer at the app's sample rate.
pub fn duration(pcm: &[i16]) -> std::time::Duration {
    std::time::Duration::from_secs_f64(pcm.len() as f64 / TARGET_SAMPLE_RATE as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoded_bytes_are_a_riff_wave_at_16k_mono() {
        let pcm: Vec<i16> = (0..1_600).map(|i| (i % 100) as i16).collect();
        let bytes = encode_to_bytes(&pcm).unwrap();

        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");

        let mut reader = hound::WavReader::new(Cursor::new(bytes)).unwrap();
        let spec = reader.spec();
        assert_eq!(spec.channels, 1);
        assert_eq!(spec.sample_rate, TARGET_SAMPLE_RATE);
        assert_eq!(spec.bits_per_sample, 16);

        let decoded: Vec<i16> = reader.samples::<i16>().map(Result::unwrap).collect();
        assert_eq!(decoded, pcm, "samples must round-trip exactly");
    }

    #[test]
    fn an_empty_buffer_still_produces_a_valid_wav() {
        // Engines reject truncated files, so a silent session must not emit
        // a header-less blob.
        let bytes = encode_to_bytes(&[]).unwrap();
        let reader = hound::WavReader::new(Cursor::new(bytes)).unwrap();
        assert_eq!(reader.len(), 0);
    }

    #[test]
    fn a_scratch_file_deletes_itself_when_dropped() {
        let dir = std::env::temp_dir().join(format!("ws-wav-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        let path = {
            let scratch = ScratchWav::create(&[1, 2, 3], &dir, "scratch.wav").unwrap();
            assert!(scratch.path().exists());
            scratch.path().to_path_buf()
        };
        assert!(
            !path.exists(),
            "recorded audio must not outlive the transcription"
        );
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn duration_matches_the_sample_count() {
        assert_eq!(
            duration(&vec![0; 16_000]),
            std::time::Duration::from_secs(1)
        );
        assert_eq!(duration(&[]), std::time::Duration::ZERO);
    }
}

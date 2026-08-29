//! Whisper Smart for Linux — hold-to-talk dictation for the desktop.

use whisper_smart::app;
use whisper_smart::core::settings::SettingsStore;
use whisper_smart::core::{model_catalog, paths};
use whisper_smart::platform::diagnostics::{self, CheckStatus};
use whisper_smart::stt::runtime::{self, Progress};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    match args.first().map(String::as_str) {
        Some("--version" | "-V") => {
            println!("whisper-smart {}", env!("CARGO_PKG_VERSION"));
        }
        Some("--check") => std::process::exit(run_checks()),
        Some("--download-model") => {
            std::process::exit(download_model(args.get(1).map(String::as_str)))
        }
        Some("--transcribe") => match args.get(1) {
            Some(path) => std::process::exit(transcribe_file(path)),
            None => {
                eprintln!("--transcribe needs a path to a WAV file");
                std::process::exit(2);
            }
        },
        Some("--list-models") => list_models(),
        Some("--list-devices") => list_devices(),
        Some("--mic-test") => std::process::exit(mic_test(args.get(1).map(String::as_str))),
        Some("--help" | "-h") => print_help(),
        Some(other) => {
            eprintln!("Unknown argument: {other}\n");
            print_help();
            std::process::exit(2);
        }
        None => std::process::exit(app::run()),
    }
}

fn print_help() {
    println!(
        "Whisper Smart {} — hold-to-talk dictation

USAGE:
    whisper-smart                    Run the app (tray icon + global hotkey)
    whisper-smart --check            Report whether the system is set up correctly
    whisper-smart --list-models      List the available speech models
    whisper-smart --list-devices     List microphones you can select
    whisper-smart --mic-test [SECS]  Record and report the level, to check the mic
    whisper-smart --download-model [ID]
                                     Download a model, or the selected one
    whisper-smart --transcribe FILE  Transcribe a WAV with the current provider
    whisper-smart --version          Print the version
    whisper-smart --help             Show this message

Settings live in {}.
Set RUST_LOG=whisper_smart=debug for verbose logging.",
        env!("CARGO_PKG_VERSION"),
        paths::config_file().display()
    );
}

/// Runs the readiness checks and prints them. Exit code 1 if anything is
/// blocked, so this is usable from a shell script or a systemd `ExecStartPre`.
fn run_checks() -> i32 {
    let settings = SettingsStore::load().get();
    let checks = diagnostics::run_checks(&settings);
    let mut blocked = false;

    for check in &checks {
        let marker = match check.status {
            CheckStatus::Ok => "ok",
            CheckStatus::Warning => "warn",
            CheckStatus::Blocked => {
                blocked = true;
                "FAIL"
            }
        };
        println!(
            "[{marker:>4}] {}: {}",
            check.title,
            check.detail.replace('\n', " ")
        );
        if let Some(remedy) = &check.remedy {
            println!("         fix: {remedy}");
        }
    }

    i32::from(blocked)
}

/// Lists the microphones the app can record from, as named in `config.toml`.
fn list_devices() {
    let selected = SettingsStore::load().get().general.input_device;
    let devices = whisper_smart::platform::audio::list_input_devices();

    if devices.is_empty() {
        println!("No input devices found. Check that PipeWire or PulseAudio is running.");
        return;
    }

    let marker = if selected.trim().is_empty() { "*" } else { " " };
    println!("{marker} (system default)");
    for device in devices {
        let marker = if device == selected { "*" } else { " " };
        println!("{marker} {device}");
    }
    println!("\n* = selected. Set it under [general] input_device in config.toml.");
}

/// Records briefly and reports the level, so "why does nothing transcribe?"
/// can be answered without guessing whether the microphone is the problem.
fn mic_test(seconds: Option<&str>) -> i32 {
    use whisper_smart::core::state_machine::{AudioCapturing, Event, SPEECH_LEVEL_THRESHOLD};
    use whisper_smart::platform::audio::AudioCapture;

    let seconds: f64 = seconds.and_then(|s| s.parse().ok()).unwrap_or(5.0);
    let settings = SettingsStore::load().get();
    let device = settings.general.input_device.clone();

    let (events_tx, events_rx) = crossbeam_channel::unbounded::<Event>();
    let pcm_sink: whisper_smart::platform::audio::PcmSink =
        std::sync::Arc::new(std::sync::Mutex::new(None));
    let (pcm_tx, pcm_rx) = crossbeam_channel::unbounded::<Vec<i16>>();
    *pcm_sink.lock().unwrap() = Some(pcm_tx);

    let mut capture = AudioCapture::new(events_tx, std::sync::Arc::clone(&pcm_sink));

    let label = if device.trim().is_empty() {
        "system default"
    } else {
        device.as_str()
    };
    println!("Recording {seconds:.0}s from {label}. Speak now…");

    if let Err(err) = capture.start(&device) {
        eprintln!("Could not open the microphone: {err}");
        return 1;
    }

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs_f64(seconds);
    let mut peak = 0.0f32;
    let mut level_updates = 0usize;
    let mut samples = 0usize;

    while std::time::Instant::now() < deadline {
        while let Ok(event) = events_rx.try_recv() {
            match event {
                Event::AudioLevel(level) => {
                    level_updates += 1;
                    peak = peak.max(level);
                }
                Event::AudioError(err) => {
                    eprintln!("Capture error: {err}");
                    capture.stop();
                    return 1;
                }
                _ => {}
            }
        }
        while let Ok(chunk) = pcm_rx.try_recv() {
            samples += chunk.len();
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    capture.stop();

    println!("  level updates: {level_updates}");
    println!(
        "  samples captured: {samples} ({:.1}s at 16 kHz)",
        samples as f64 / 16_000.0
    );
    println!("  peak level: {peak:.3} (speech threshold {SPEECH_LEVEL_THRESHOLD})");

    if level_updates == 0 || samples == 0 {
        println!(
            "\nThe microphone delivered no audio at all. Check that the right device is \
                  selected (--list-devices) and that it is not muted."
        );
        return 1;
    }
    if peak < SPEECH_LEVEL_THRESHOLD {
        println!(
            "\nAudio is arriving but never crossed the speech threshold, so dictation \
                  would skip transcription. Raise the input volume, or pick a different device."
        );
        return 1;
    }
    println!("\nMicrophone is working.");
    0
}

/// Lists the catalog, marking what is already on disk.
fn list_models() {
    let settings = SettingsStore::load().get();
    let selected: Vec<&str> = [
        settings.provider.whisper_cpp_model.as_str(),
        settings.provider.faster_whisper_model.as_str(),
        settings.provider.parakeet_model.as_str(),
    ]
    .to_vec();

    for model in model_catalog::all() {
        let installed = if diagnostics::is_model_installed(&model) {
            "installed"
        } else {
            "-"
        };
        let marker = if selected.contains(&model.id) {
            "*"
        } else {
            " "
        };
        println!(
            "{marker} {:<28} {:<10} {:<28} {}",
            model.id,
            model.approx_size_label,
            model.engine.display_name(),
            installed
        );
    }
    println!("\n* = selected for its engine. Download with: whisper-smart --download-model ID");
}

/// Downloads a model without needing the GUI, for scripted and headless setup.
fn download_model(id: Option<&str>) -> i32 {
    let settings = SettingsStore::load().get();

    let model = match id {
        Some(id) => match model_catalog::model(id) {
            Some(model) => model,
            None => {
                eprintln!("Unknown model: {id}\nRun --list-models to see the options.");
                return 2;
            }
        },
        None => match settings.selected_model() {
            Some(model) => model,
            None => {
                eprintln!("The selected provider does not use a local model.");
                return 2;
            }
        },
    };

    if diagnostics::is_model_installed(&model) {
        println!("{} is already downloaded.", model.display_name);
        return 0;
    }

    println!(
        "Downloading {} ({})…",
        model.display_name, model.approx_size_label
    );

    // Progress is reported as a single rewritten line so this stays readable in
    // a terminal without pulling in a progress-bar dependency.
    let sink: runtime::ProgressSink = Box::new(|update| match update {
        Progress::Step(text) => println!("{text}"),
        Progress::Fraction(fraction) => {
            let percent = (fraction * 100.0).round() as u32;
            let filled = (fraction * 40.0).round() as usize;
            eprint!(
                "\r  [{}{}] {percent:>3}%",
                "#".repeat(filled),
                " ".repeat(40 - filled)
            );
        }
        Progress::Done => eprintln!(),
        Progress::Failed(err) => eprintln!("\n{err}"),
    });

    match runtime::download_model(&model, &sink) {
        Ok(()) => {
            println!("{} is ready.", model.display_name);
            0
        }
        Err(err) => {
            eprintln!("Download failed: {err}");
            1
        }
    }
}

/// Transcribes a WAV file with the configured provider.
///
/// This is the quickest way to confirm the speech engine works at all, without
/// involving the microphone, the hotkey, or text insertion.
fn transcribe_file(path: &str) -> i32 {
    use whisper_smart::core::provider::ProviderKind;
    use whisper_smart::stt::{openai, whisper_cpp, Transcriber};

    let settings = SettingsStore::load().get();

    let pcm = match read_wav_16k_mono(path) {
        Ok(pcm) => pcm,
        Err(err) => {
            eprintln!("Could not read {path}: {err}");
            return 2;
        }
    };

    let built: Result<Box<dyn Transcriber>, String> = match settings.provider.kind {
        ProviderKind::WhisperCpp => whisper_cpp::WhisperCppTranscriber::new(&settings)
            .map(|t| Box::new(t) as Box<dyn Transcriber>),
        ProviderKind::FasterWhisper | ProviderKind::Parakeet => {
            whisper_smart::stt::daemon::DaemonTranscriber::new(&settings)
                .map(|t| Box::new(t) as Box<dyn Transcriber>)
        }
        ProviderKind::OpenAiApi => {
            openai::OpenAiTranscriber::new(&settings).map(|t| Box::new(t) as Box<dyn Transcriber>)
        }
        ProviderKind::Stub => {
            eprintln!("The stub provider cannot transcribe.");
            return 2;
        }
    };

    let mut transcriber = match built {
        Ok(transcriber) => transcriber,
        Err(err) => {
            eprintln!("{err}");
            return 1;
        }
    };

    eprintln!(
        "Transcribing {:.1}s of audio with {}…",
        pcm.len() as f64 / 16_000.0,
        transcriber.name()
    );
    transcriber.prewarm();

    let started = std::time::Instant::now();
    match transcriber.transcribe(&pcm) {
        Ok(text) => {
            eprintln!("Done in {:.2}s.", started.elapsed().as_secs_f64());
            println!("{text}");
            0
        }
        Err(err) => {
            eprintln!("Transcription failed: {err}");
            1
        }
    }
}

/// Reads a WAV into the 16 kHz mono PCM every engine here expects, converting
/// sample rate and channel count if needed.
fn read_wav_16k_mono(path: &str) -> Result<Vec<i16>, String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| e.to_string())?;
    let spec = reader.spec();

    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader
            .samples::<f32>()
            .collect::<Result<_, _>>()
            .map_err(|e| e.to_string())?,
        hound::SampleFormat::Int => match spec.bits_per_sample {
            16 => reader
                .samples::<i16>()
                .map(|s| s.map(|v| v as f32 / 32_768.0))
                .collect::<Result<_, _>>()
                .map_err(|e| e.to_string())?,
            32 => reader
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / 2_147_483_648.0))
                .collect::<Result<_, _>>()
                .map_err(|e| e.to_string())?,
            bits => return Err(format!("unsupported bit depth: {bits}")),
        },
    };

    let channels = spec.channels.max(1) as usize;
    let mono: Vec<f32> = if channels == 1 {
        samples
    } else {
        samples
            .chunks_exact(channels)
            .map(|f| f.iter().sum::<f32>() / channels as f32)
            .collect()
    };

    // Linear resample, matching the capture path's approach.
    let resampled: Vec<f32> = if spec.sample_rate == 16_000 {
        mono
    } else {
        let ratio = 16_000.0 / spec.sample_rate as f64;
        let target = (mono.len() as f64 * ratio).round() as usize;
        (0..target)
            .map(|i| {
                let pos = i as f64 / ratio;
                let index = pos.floor() as usize;
                let frac = (pos - index as f64) as f32;
                let a = mono.get(index).copied().unwrap_or(0.0);
                let b = mono.get(index + 1).copied().unwrap_or(a);
                a + (b - a) * frac
            })
            .collect()
    };

    Ok(resampled
        .iter()
        .map(|s| (s.clamp(-1.0, 1.0) * 32_767.0) as i16)
        .collect())
}

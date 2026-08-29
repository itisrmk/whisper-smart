//! Local speech-to-text model catalog for Linux.
//!
//! ## Why this file exists
//!
//! The macOS build runs every local model through MLX, Apple's array framework.
//! MLX targets Apple Silicon's unified memory and has no Linux backend, so the
//! `mlx-community/*` repositories the Mac app downloads are unusable here —
//! the weights are packaged for MLX specifically, not just "some GPU".
//!
//! Linux therefore gets three engines, each carrying the *same model families*
//! in a format that engine can actually load:
//!
//! | Engine          | Format             | Why it is here                                  |
//! |-----------------|--------------------|-------------------------------------------------|
//! | `FasterWhisper` | CTranslate2        | Closest match to MLX Whisper: same weights, GPU  |
//! | `WhisperCpp`    | GGUF               | No Python/CUDA wheels at all; most robust        |
//! | `ParakeetOnnx`  | ONNX Runtime       | Keeps Parakeet TDT parity with the Mac default   |
//!
//! Model IDs are stable and engine-qualified, because the same underlying
//! weights (say Whisper large-v3-turbo) exist in two different engines here and
//! the user's selection has to say which one it means.

use serde::{Deserialize, Serialize};

/// Which runtime loads a given model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelEngine {
    /// CTranslate2 Whisper via the `faster-whisper` Python package.
    FasterWhisper,
    /// GGUF Whisper via the `whisper-cli` binary from the `whisper-cpp` package.
    WhisperCpp,
    /// NVIDIA Parakeet TDT via ONNX Runtime (`onnx-asr` Python package).
    ParakeetOnnx,
}

impl ModelEngine {
    pub fn display_name(self) -> &'static str {
        match self {
            ModelEngine::FasterWhisper => "faster-whisper (CTranslate2)",
            ModelEngine::WhisperCpp => "whisper.cpp (GGUF)",
            ModelEngine::ParakeetOnnx => "Parakeet (ONNX Runtime)",
        }
    }

    /// Whether this engine runs inside the managed Python sidecar.
    /// whisper.cpp is a standalone binary and needs no Python at all, which is
    /// why it is the recommended fallback when CUDA wheels misbehave.
    pub fn needs_python_runtime(self) -> bool {
        match self {
            ModelEngine::FasterWhisper | ModelEngine::ParakeetOnnx => true,
            ModelEngine::WhisperCpp => false,
        }
    }
}

/// How a model's weights are fetched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelSource {
    /// A Hugging Face repo snapshot, downloaded by the Python sidecar.
    HuggingFaceRepo { repo: &'static str },
    /// A single file downloaded directly over HTTPS (whisper.cpp GGUF).
    DirectFile {
        url: &'static str,
        file_name: &'static str,
    },
}

/// One installable local model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalModel {
    /// Stable identifier persisted in `config.toml`.
    pub id: &'static str,
    pub display_name: &'static str,
    pub engine: ModelEngine,
    pub source: ModelSource,
    pub approx_size_label: &'static str,
    pub quality_band: &'static str,
    /// True when the model is large enough that CPU-only inference will feel
    /// slow. Surfaced in the UI rather than blocking the choice.
    pub prefers_gpu: bool,
}

impl LocalModel {
    /// Repo id for HF-backed models, if any.
    pub fn repo(&self) -> Option<&'static str> {
        match self.source {
            ModelSource::HuggingFaceRepo { repo } => Some(repo),
            ModelSource::DirectFile { .. } => None,
        }
    }
}

// ---------------------------------------------------------------------------
// faster-whisper (CTranslate2)
// ---------------------------------------------------------------------------

pub const FW_TINY: LocalModel = LocalModel {
    id: "fw-whisper-tiny",
    display_name: "Whisper Tiny",
    engine: ModelEngine::FasterWhisper,
    source: ModelSource::HuggingFaceRepo {
        repo: "Systran/faster-whisper-tiny",
    },
    approx_size_label: "75 MB",
    quality_band: "Fastest · lower accuracy",
    prefers_gpu: false,
};

pub const FW_BASE: LocalModel = LocalModel {
    id: "fw-whisper-base",
    display_name: "Whisper Base",
    engine: ModelEngine::FasterWhisper,
    source: ModelSource::HuggingFaceRepo {
        repo: "Systran/faster-whisper-base",
    },
    approx_size_label: "145 MB",
    quality_band: "Fast · light",
    prefers_gpu: false,
};

pub const FW_SMALL: LocalModel = LocalModel {
    id: "fw-whisper-small",
    display_name: "Whisper Small",
    engine: ModelEngine::FasterWhisper,
    source: ModelSource::HuggingFaceRepo {
        repo: "Systran/faster-whisper-small",
    },
    approx_size_label: "484 MB",
    quality_band: "Balanced",
    prefers_gpu: false,
};

pub const FW_LARGE_V3_TURBO: LocalModel = LocalModel {
    id: "fw-whisper-large-v3-turbo",
    display_name: "Whisper Large-v3 Turbo",
    engine: ModelEngine::FasterWhisper,
    source: ModelSource::HuggingFaceRepo {
        repo: "deepdml/faster-whisper-large-v3-turbo-ct2",
    },
    approx_size_label: "1.6 GB",
    quality_band: "Highest accuracy",
    prefers_gpu: true,
};

pub const FW_DISTIL_LARGE_V3: LocalModel = LocalModel {
    id: "fw-distil-whisper-large-v3",
    display_name: "Distil-Whisper Large-v3",
    engine: ModelEngine::FasterWhisper,
    source: ModelSource::HuggingFaceRepo {
        repo: "Systran/faster-distil-whisper-large-v3",
    },
    approx_size_label: "1.5 GB",
    quality_band: "High accuracy · faster than Large",
    prefers_gpu: true,
};

// ---------------------------------------------------------------------------
// whisper.cpp (GGUF) — no Python runtime required
// ---------------------------------------------------------------------------

pub const CPP_BASE: LocalModel = LocalModel {
    id: "cpp-whisper-base",
    display_name: "Whisper Base (whisper.cpp)",
    engine: ModelEngine::WhisperCpp,
    source: ModelSource::DirectFile {
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
        file_name: "ggml-base.bin",
    },
    approx_size_label: "148 MB",
    quality_band: "Fast · no Python needed",
    prefers_gpu: false,
};

pub const CPP_SMALL: LocalModel = LocalModel {
    id: "cpp-whisper-small",
    display_name: "Whisper Small (whisper.cpp)",
    engine: ModelEngine::WhisperCpp,
    source: ModelSource::DirectFile {
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
        file_name: "ggml-small.bin",
    },
    approx_size_label: "488 MB",
    quality_band: "Balanced · no Python needed",
    prefers_gpu: false,
};

pub const CPP_LARGE_V3_TURBO: LocalModel = LocalModel {
    id: "cpp-whisper-large-v3-turbo",
    display_name: "Whisper Large-v3 Turbo (whisper.cpp)",
    engine: ModelEngine::WhisperCpp,
    source: ModelSource::DirectFile {
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
        file_name: "ggml-large-v3-turbo.bin",
    },
    approx_size_label: "1.6 GB",
    quality_band: "Highest accuracy · no Python needed",
    prefers_gpu: true,
};

// ---------------------------------------------------------------------------
// Parakeet TDT (ONNX Runtime) — parity with the macOS default engine
// ---------------------------------------------------------------------------

pub const PARAKEET_V3: LocalModel = LocalModel {
    id: "parakeet-tdt-0.6b-v3",
    display_name: "Parakeet TDT 0.6B v3",
    engine: ModelEngine::ParakeetOnnx,
    source: ModelSource::HuggingFaceRepo {
        repo: "istupakov/parakeet-tdt-0.6b-v3-onnx",
    },
    approx_size_label: "2.5 GB",
    quality_band: "Best speed · 25 languages",
    prefers_gpu: true,
};

pub const PARAKEET_V2: LocalModel = LocalModel {
    id: "parakeet-tdt-0.6b-v2",
    display_name: "Parakeet TDT 0.6B v2",
    engine: ModelEngine::ParakeetOnnx,
    source: ModelSource::HuggingFaceRepo {
        repo: "istupakov/parakeet-tdt-0.6b-v2-onnx",
    },
    approx_size_label: "2.5 GB",
    quality_band: "Best speed · English",
    prefers_gpu: true,
};

/// Every model the Linux build offers.
pub fn all() -> Vec<LocalModel> {
    vec![
        PARAKEET_V3,
        PARAKEET_V2,
        FW_TINY,
        FW_BASE,
        FW_SMALL,
        FW_LARGE_V3_TURBO,
        FW_DISTIL_LARGE_V3,
        CPP_BASE,
        CPP_SMALL,
        CPP_LARGE_V3_TURBO,
    ]
}

pub fn models_for(engine: ModelEngine) -> Vec<LocalModel> {
    all().into_iter().filter(|m| m.engine == engine).collect()
}

pub fn model(id: &str) -> Option<LocalModel> {
    all().into_iter().find(|m| m.id == id)
}

/// The model a given engine falls back to when nothing is selected.
pub fn default_model(engine: ModelEngine) -> LocalModel {
    match engine {
        ModelEngine::FasterWhisper => FW_LARGE_V3_TURBO,
        ModelEngine::WhisperCpp => CPP_LARGE_V3_TURBO,
        ModelEngine::ParakeetOnnx => PARAKEET_V3,
    }
}

/// Translates a model ID from the macOS (MLX) catalog to its nearest Linux
/// equivalent, so a config copied from a Mac install keeps the user's intent
/// instead of silently resetting. Whisper models map to faster-whisper because
/// it is the closest analogue to MLX Whisper in both weights and GPU usage.
pub fn from_macos_model_id(mac_id: &str) -> Option<LocalModel> {
    let mapped = match mac_id {
        "parakeet-tdt-0.6b-v3" => PARAKEET_V3,
        "parakeet-tdt-0.6b-v2" => PARAKEET_V2,
        // MLX ships a tiny Whisper; faster-whisper's smallest is also tiny.
        "whisper-tiny" => FW_TINY,
        "whisper-base" => FW_BASE,
        "whisper-small" => FW_SMALL,
        "whisper-large-v3-turbo" => FW_LARGE_V3_TURBO,
        "distil-whisper-large-v3" => FW_DISTIL_LARGE_V3,
        _ => return None,
    };
    Some(mapped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_model_id_is_unique() {
        let mut ids: Vec<&str> = all().iter().map(|m| m.id).collect();
        let total = ids.len();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), total, "duplicate model id in catalog");
    }

    #[test]
    fn no_mlx_repositories_survive_the_port() {
        // MLX weights are Apple-Silicon only. If one of these ever sneaks back
        // into the catalog the model would download and then fail to load.
        for m in all() {
            if let Some(repo) = m.repo() {
                assert!(
                    !repo.starts_with("mlx-community/"),
                    "{} still points at an MLX repo: {repo}",
                    m.id
                );
            }
        }
    }

    #[test]
    fn whisper_cpp_models_need_no_python() {
        for m in models_for(ModelEngine::WhisperCpp) {
            assert!(!m.engine.needs_python_runtime());
            assert!(matches!(m.source, ModelSource::DirectFile { .. }));
        }
    }

    #[test]
    fn macos_selections_migrate_to_a_linux_engine() {
        assert_eq!(
            from_macos_model_id("parakeet-tdt-0.6b-v3").unwrap().id,
            PARAKEET_V3.id
        );
        assert_eq!(
            from_macos_model_id("whisper-large-v3-turbo").unwrap().id,
            FW_LARGE_V3_TURBO.id
        );
        assert!(from_macos_model_id("not-a-model").is_none());
    }

    #[test]
    fn each_engine_has_a_default_model_belonging_to_it() {
        for engine in [
            ModelEngine::FasterWhisper,
            ModelEngine::WhisperCpp,
            ModelEngine::ParakeetOnnx,
        ] {
            let m = default_model(engine);
            assert_eq!(m.engine, engine);
            assert!(
                model(m.id).is_some(),
                "default model {} missing from catalog",
                m.id
            );
        }
    }
}

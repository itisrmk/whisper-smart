//! Speech-to-text provider selection.
//!
//! The macOS build defaults to Apple Speech because it is on-device, free, and
//! already installed — a zero-setup fallback that always works. Linux has no
//! equivalent system recogniser, so the zero-friction slot goes to whisper.cpp:
//! it is a single distro package plus one GGUF file, with no Python runtime,
//! no CUDA wheels, and no virtualenv bootstrap in the way.

use serde::{Deserialize, Serialize};

use crate::core::model_catalog::ModelEngine;

/// The available STT backends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    /// whisper.cpp via the `whisper-cli` binary. Default.
    #[default]
    WhisperCpp,
    /// CTranslate2 Whisper via the managed Python sidecar.
    FasterWhisper,
    /// NVIDIA Parakeet TDT via ONNX Runtime in the managed Python sidecar.
    Parakeet,
    /// OpenAI's hosted Whisper endpoint (or any OpenAI-compatible base URL).
    OpenAiApi,
    /// Test-only no-op provider. Never produces text.
    Stub,
}

impl ProviderKind {
    pub fn all() -> Vec<ProviderKind> {
        vec![
            ProviderKind::WhisperCpp,
            ProviderKind::FasterWhisper,
            ProviderKind::Parakeet,
            ProviderKind::OpenAiApi,
        ]
    }

    pub fn display_name(self) -> &'static str {
        match self {
            ProviderKind::WhisperCpp => "Whisper (whisper.cpp, local)",
            ProviderKind::FasterWhisper => "Whisper (faster-whisper, local)",
            ProviderKind::Parakeet => "Parakeet (ONNX, local)",
            ProviderKind::OpenAiApi => "OpenAI Whisper API",
            ProviderKind::Stub => "Stub (testing only)",
        }
    }

    /// A one-line explanation of the trade-off, shown under the picker.
    pub fn summary(self) -> &'static str {
        match self {
            ProviderKind::WhisperCpp => {
                "No Python runtime. Uses the system whisper-cli binary with CUDA or Vulkan if it was built with them."
            }
            ProviderKind::FasterWhisper => {
                "Fastest local Whisper when a matching CUDA build is available; falls back to CPU otherwise."
            }
            ProviderKind::Parakeet => {
                "Same engine family as the macOS default. English and multilingual TDT models via ONNX Runtime."
            }
            ProviderKind::OpenAiApi => "Cloud transcription. Requires an API key; audio leaves your machine.",
            ProviderKind::Stub => "Testing only.",
        }
    }

    /// The local model engine this provider drives, if it is a local provider.
    pub fn engine(self) -> Option<ModelEngine> {
        match self {
            ProviderKind::WhisperCpp => Some(ModelEngine::WhisperCpp),
            ProviderKind::FasterWhisper => Some(ModelEngine::FasterWhisper),
            ProviderKind::Parakeet => Some(ModelEngine::ParakeetOnnx),
            ProviderKind::OpenAiApi | ProviderKind::Stub => None,
        }
    }

    /// Whether the provider needs model weights on disk before it can run.
    pub fn requires_model_download(self) -> bool {
        self.engine().is_some()
    }

    /// Whether the provider needs the managed Python virtualenv.
    pub fn requires_python_runtime(self) -> bool {
        self.engine().is_some_and(ModelEngine::needs_python_runtime)
    }

    /// Whether transcription audio is sent off the machine.
    pub fn is_cloud(self) -> bool {
        matches!(self, ProviderKind::OpenAiApi)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_provider_needs_no_python_runtime() {
        // The default must be reachable without bootstrapping a virtualenv,
        // otherwise a fresh install cannot dictate until pip succeeds.
        let default = ProviderKind::default();
        assert_eq!(default, ProviderKind::WhisperCpp);
        assert!(!default.requires_python_runtime());
    }

    #[test]
    fn only_openai_is_cloud() {
        for kind in ProviderKind::all() {
            assert_eq!(kind.is_cloud(), kind == ProviderKind::OpenAiApi);
        }
    }

    #[test]
    fn only_local_providers_report_an_engine_and_need_a_model() {
        for kind in ProviderKind::all() {
            assert_eq!(
                kind.engine().is_some(),
                kind.requires_model_download(),
                "{kind:?}"
            );
        }
        assert!(ProviderKind::OpenAiApi.engine().is_none());
    }

    #[test]
    fn provider_kind_round_trips_through_toml() {
        #[derive(Serialize, Deserialize, PartialEq, Debug)]
        struct Wrapper {
            provider: ProviderKind,
        }
        let w = Wrapper {
            provider: ProviderKind::Parakeet,
        };
        let text = toml::to_string(&w).unwrap();
        assert!(text.contains("parakeet"));
        assert_eq!(toml::from_str::<Wrapper>(&text).unwrap(), w);
    }
}

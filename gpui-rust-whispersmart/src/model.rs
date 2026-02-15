#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UiState {
    Idle,
    Recording,
    Transcribing,
    Success,
    Error(String),
}

impl UiState {
    pub fn label(&self) -> &'static str {
        match self {
            UiState::Idle => "Idle",
            UiState::Recording => "Recording",
            UiState::Transcribing => "Transcribing",
            UiState::Success => "Success",
            UiState::Error(_) => "Error",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DictationSession {
    pub partial_text: String,
    pub final_text: Option<String>,
}

impl Default for DictationSession {
    fn default() -> Self {
        Self {
            partial_text: String::new(),
            final_text: None,
        }
    }
}

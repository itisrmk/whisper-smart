use anyhow::Result;

use crate::{
    clipboard::ClipboardInserter,
    model::{DictationSession, UiState},
    provider::SttProvider,
    services::AudioCaptureService,
};

pub struct DictationStateMachine {
    pub state: UiState,
    pub session: DictationSession,
    provider: Box<dyn SttProvider>,
    audio: Box<dyn AudioCaptureService>,
    clipboard: Box<dyn ClipboardInserter>,
}

impl DictationStateMachine {
    pub fn new(
        provider: Box<dyn SttProvider>,
        audio: Box<dyn AudioCaptureService>,
        clipboard: Box<dyn ClipboardInserter>,
    ) -> Self {
        Self {
            state: UiState::Idle,
            session: DictationSession::default(),
            provider,
            audio,
            clipboard,
        }
    }

    pub fn start_recording(&mut self) -> Result<()> {
        self.provider.begin_session()?;
        self.audio.start_capture()?;
        self.session = DictationSession::default();
        self.state = UiState::Recording;
        Ok(())
    }

    pub fn stop_and_transcribe(&mut self) -> Result<()> {
        self.state = UiState::Transcribing;
        let chunk = self.audio.read_mono_chunk()?;
        self.provider.feed_audio_chunk(&chunk)?;
        self.audio.stop_capture()?;

        let result = self.provider.end_session()?;
        self.session.final_text = Some(result.text.clone());

        if !result.text.trim().is_empty() {
            self.clipboard.insert_text(&result.text)?;
            self.state = UiState::Success;
        } else {
            self.state = UiState::Error("No transcript returned".to_string());
        }

        Ok(())
    }

    pub fn reset_to_idle(&mut self) {
        self.state = UiState::Idle;
        self.session.partial_text.clear();
    }

    pub fn fail(&mut self, reason: impl Into<String>) {
        self.state = UiState::Error(reason.into());
    }
}

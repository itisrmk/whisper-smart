use anyhow::Result;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderResult {
    pub text: String,
    pub is_partial: bool,
}

pub trait SttProvider: Send {
    fn display_name(&self) -> &'static str;
    fn begin_session(&mut self) -> Result<()>;
    fn feed_audio_chunk(&mut self, _pcm: &[f32]) -> Result<()>;
    fn end_session(&mut self) -> Result<ProviderResult>;
}

#[derive(Default)]
pub struct PlaceholderProvider {
    buffered_frames: usize,
}

impl SttProvider for PlaceholderProvider {
    fn display_name(&self) -> &'static str {
        "Placeholder (simulated)"
    }

    fn begin_session(&mut self) -> Result<()> {
        self.buffered_frames = 0;
        Ok(())
    }

    fn feed_audio_chunk(&mut self, pcm: &[f32]) -> Result<()> {
        self.buffered_frames += pcm.len();
        Ok(())
    }

    fn end_session(&mut self) -> Result<ProviderResult> {
        Ok(ProviderResult {
            text: format!(
                "Simulated transcript from {} frames.",
                self.buffered_frames
            ),
            is_partial: false,
        })
    }
}

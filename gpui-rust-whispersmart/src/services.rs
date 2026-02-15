use anyhow::Result;

pub trait HotkeyService: Send {
    fn start_monitoring(&mut self) -> Result<()>;
    fn stop_monitoring(&mut self) -> Result<()>;
}

pub trait AudioCaptureService: Send {
    fn start_capture(&mut self) -> Result<()>;
    fn stop_capture(&mut self) -> Result<()>;
    fn read_mono_chunk(&mut self) -> Result<Vec<f32>>;
}

#[derive(Default)]
pub struct StubHotkeyService;

impl HotkeyService for StubHotkeyService {
    fn start_monitoring(&mut self) -> Result<()> {
        Ok(())
    }

    fn stop_monitoring(&mut self) -> Result<()> {
        Ok(())
    }
}

#[derive(Default)]
pub struct StubAudioCaptureService;

impl AudioCaptureService for StubAudioCaptureService {
    fn start_capture(&mut self) -> Result<()> {
        Ok(())
    }

    fn stop_capture(&mut self) -> Result<()> {
        Ok(())
    }

    fn read_mono_chunk(&mut self) -> Result<Vec<f32>> {
        Ok(vec![0.1; 1600])
    }
}

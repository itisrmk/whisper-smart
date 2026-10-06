//! Windows platform integration: audio, input, injection, desktop services.

pub mod audio;
pub mod diagnostics;
pub mod focus;
pub mod hotkey;
pub mod injector;
pub mod notify;
pub mod scheduler;

/// Keeps a spawned console program (python, whisper-cli, nvidia-smi) from
/// flashing a console window: this app is a GUI-subsystem process, and every
/// child process it starts is plumbing the user never asked to see.
#[cfg(windows)]
pub fn hide_console(command: &mut std::process::Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
pub fn hide_console(_command: &mut std::process::Command) {}

/// The primary monitor's work area (the desktop minus the taskbar), in
/// logical points — the coordinate space egui positions windows in.
///
/// Exists because the overlay's parent window is parked off-screen, where
/// winit cannot resolve a monitor, so egui reports no `monitor_size` to
/// position against until the overlay itself has settled on a monitor.
#[cfg(windows)]
pub fn primary_work_area_points() -> Option<(f32, f32)> {
    use windows::Win32::Foundation::RECT;
    use windows::Win32::UI::HiDpi::GetDpiForSystem;
    use windows::Win32::UI::WindowsAndMessaging::{
        SystemParametersInfoW, SPI_GETWORKAREA, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
    };

    unsafe {
        let mut rect = RECT::default();
        SystemParametersInfoW(
            SPI_GETWORKAREA,
            0,
            Some(&mut rect as *mut RECT as *mut core::ffi::c_void),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
        .ok()?;

        let dpi = GetDpiForSystem();
        if dpi == 0 {
            return None;
        }
        let scale = dpi as f32 / 96.0;
        let width = (rect.right - rect.left) as f32 / scale;
        let height = (rect.bottom - rect.top) as f32 / scale;
        (width > 1.0 && height > 1.0).then_some((width, height))
    }
}

#[cfg(not(windows))]
pub fn primary_work_area_points() -> Option<(f32, f32)> {
    None
}

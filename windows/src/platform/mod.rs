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

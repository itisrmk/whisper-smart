//! Brand font installation.
//!
//! The macOS build registers `Archivo-Variable.ttf` at launch with
//! `CTFontManagerRegisterFontsForURL`, so the font ships inside the app and
//! never has to be installed system-wide. GTK has no equivalent process-scoped
//! registration — Pango resolves families through fontconfig, which only looks
//! at directories on disk — so the font is written into the user's font
//! directory on first run instead.
//!
//! This is deliberately a user-level install: it touches only
//! `$XDG_DATA_HOME/fonts`, needs no privileges, and is skipped entirely when a
//! packaged copy of Archivo is already present.

use std::path::PathBuf;

/// The font, compiled into the binary so a `cargo run` from a checkout looks
/// the same as a packaged install.
const ARCHIVO: &[u8] = include_bytes!("../../resources/Archivo-Variable.ttf");

const FILE_NAME: &str = "WhisperSmart-Archivo-Variable.ttf";

/// Where the font is written if it is not already available.
fn install_path() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| {
            dirs::home_dir()
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join(".local/share")
        })
        .join("fonts")
        .join(FILE_NAME)
}

/// Installs the brand font if it is missing, then returns whether Archivo
/// should be available to Pango.
///
/// Failure is not fatal anywhere: [`crate::ui::tokens::FONT_FAMILY`] lists
/// fallbacks, so the UI degrades to a similar grotesque rather than breaking.
pub fn ensure_installed() -> bool {
    if system_has_archivo() {
        tracing::debug!("Archivo is already installed system-wide");
        return true;
    }

    let path = install_path();
    if path.is_file() {
        // Written by a previous run.
        return true;
    }

    let Some(parent) = path.parent() else {
        return false;
    };
    if let Err(err) = std::fs::create_dir_all(parent) {
        tracing::warn!("could not create the font directory: {err}");
        return false;
    }
    if let Err(err) = std::fs::write(&path, ARCHIVO) {
        tracing::warn!("could not install the brand font: {err}");
        return false;
    }

    tracing::info!("installed the brand font to {}", path.display());
    refresh_font_cache(parent);
    true
}

/// True when some copy of Archivo is already on the system, so a packaged
/// install is not shadowed by our own copy.
fn system_has_archivo() -> bool {
    for root in ["/usr/share/fonts", "/usr/local/share/fonts"] {
        if directory_contains_archivo(std::path::Path::new(root)) {
            return true;
        }
    }
    false
}

fn directory_contains_archivo(dir: &std::path::Path) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if directory_contains_archivo(&path) {
                return true;
            }
        } else if path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.to_ascii_lowercase().starts_with("archivo"))
        {
            return true;
        }
    }
    false
}

/// Nudges fontconfig so the font is visible without a re-login.
///
/// fontconfig rescans a directory whose mtime changed, so this is usually
/// unnecessary — but it is cheap, and without it the very first launch after
/// install can fall back to the secondary family.
fn refresh_font_cache(dir: &std::path::Path) {
    let result = std::process::Command::new("fc-cache")
        .arg("-f")
        .arg(dir)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    if let Err(err) = result {
        tracing::debug!("fc-cache unavailable ({err}); fontconfig will pick the font up itself");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_font_is_compiled_into_the_binary() {
        // A missing asset would silently drop the product's typeface.
        assert!(ARCHIVO.len() > 100_000, "the font asset looks truncated");
        // TrueType/OpenType magic.
        assert!(
            ARCHIVO.starts_with(&[0x00, 0x01, 0x00, 0x00]) || ARCHIVO.starts_with(b"OTTO"),
            "the font asset is not a TrueType file"
        );
    }

    #[test]
    fn the_install_path_is_inside_the_users_font_directory() {
        let path = install_path();
        assert!(path.ends_with(FILE_NAME));
        assert!(
            path.to_string_lossy().contains("fonts"),
            "fontconfig only scans font directories: {}",
            path.display()
        );
    }

    #[test]
    fn a_directory_without_archivo_is_reported_as_such() {
        let dir = std::env::temp_dir().join(format!("ws-fonts-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("SomethingElse.ttf"), b"x").unwrap();
        assert!(!directory_contains_archivo(&dir));

        std::fs::write(dir.join("Archivo-Regular.ttf"), b"x").unwrap();
        assert!(directory_contains_archivo(&dir));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_missing_directory_is_not_an_error() {
        assert!(!directory_contains_archivo(std::path::Path::new(
            "/nonexistent/fonts"
        )));
    }
}

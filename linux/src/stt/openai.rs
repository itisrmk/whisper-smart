//! OpenAI Whisper API provider.
//!
//! Port of `OpenAIWhisperAPISTTProvider.swift`. The base URL is configurable so
//! any OpenAI-compatible endpoint (Groq, LocalAI, a self-hosted gateway) works
//! with the same code path.
//!
//! This is the only provider that sends audio off the machine, so it is never
//! selected implicitly: [`resolve_provider`](crate::platform::diagnostics::resolve_provider)
//! will only fall back to it when the user has explicitly enabled cloud
//! fallback *and* saved a key.

use std::time::Duration;

use crate::core::settings::Settings;
use crate::stt::{wav, Transcriber};

/// Multipart boundary. Fixed rather than random because the body is built by
/// hand and nothing in a WAV or a model name can collide with it.
const BOUNDARY: &str = "----whisper-smart-boundary-4f1c8a2e";

pub struct OpenAiTranscriber {
    api_key: String,
    base_url: String,
    model: String,
    language: String,
}

impl OpenAiTranscriber {
    pub fn new(settings: &Settings) -> Result<Self, String> {
        let api_key = crate::core::credentials::read_openai_key().ok_or_else(|| {
            "No OpenAI API key is saved. Add one in Settings → Provider.".to_string()
        })?;

        let base_url = settings
            .provider
            .openai
            .base_url
            .trim()
            .trim_end_matches('/')
            .to_string();
        if base_url.is_empty() {
            return Err("The OpenAI base URL is empty.".to_string());
        }

        Ok(Self {
            api_key,
            base_url,
            model: settings.provider.openai.model.trim().to_string(),
            language: settings.provider.language.trim().to_string(),
        })
    }

    fn endpoint(&self) -> String {
        format!("{}/audio/transcriptions", self.base_url)
    }
}

impl Transcriber for OpenAiTranscriber {
    fn name(&self) -> String {
        format!("OpenAI · {}", self.model)
    }

    fn timeout(&self) -> Duration {
        Duration::from_secs(60)
    }

    fn transcribe(&mut self, pcm: &[i16]) -> Result<String, String> {
        if pcm.is_empty() {
            return Ok(String::new());
        }

        let audio =
            wav::encode_to_bytes(pcm).map_err(|e| format!("Could not encode audio: {e}"))?;
        let body = build_multipart(&audio, &self.model, &self.language);

        let response = ureq::post(&self.endpoint())
            .header("Authorization", &format!("Bearer {}", self.api_key))
            .header(
                "Content-Type",
                &format!("multipart/form-data; boundary={BOUNDARY}"),
            )
            .send(&body[..]);

        let mut response = match response {
            Ok(response) => response,
            Err(ureq::Error::StatusCode(code)) => {
                return Err(status_message(code));
            }
            Err(err) => {
                return Err(format!("Could not reach the transcription service: {err}"));
            }
        };

        let text = response
            .body_mut()
            .read_to_string()
            .map_err(|e| format!("Could not read the transcription response: {e}"))?;

        parse_response(&text)
    }
}

/// Maps HTTP failures onto messages that say what the user should do.
fn status_message(code: u16) -> String {
    match code {
        401 | 403 => {
            "The OpenAI API rejected the key. Check it in Settings → Provider.".to_string()
        }
        429 => "The OpenAI API is rate limiting this key. Try again shortly.".to_string(),
        413 => "The recording is too long for the API. Try a shorter dictation.".to_string(),
        500..=599 => format!("The transcription service returned a server error ({code})."),
        other => format!("The transcription request failed (HTTP {other})."),
    }
}

/// Builds the `multipart/form-data` body by hand.
///
/// Assembling this manually keeps the dependency tree to a blocking HTTP client
/// with no async runtime, which matters for an app that is otherwise entirely
/// thread-and-channel based.
fn build_multipart(audio: &[u8], model: &str, language: &str) -> Vec<u8> {
    let mut body = Vec::with_capacity(audio.len() + 512);

    let field = |name: &str, value: &str, body: &mut Vec<u8>| {
        body.extend_from_slice(format!("--{BOUNDARY}\r\n").as_bytes());
        body.extend_from_slice(
            format!("Content-Disposition: form-data; name=\"{name}\"\r\n\r\n").as_bytes(),
        );
        body.extend_from_slice(value.as_bytes());
        body.extend_from_slice(b"\r\n");
    };

    field("model", model, &mut body);
    field("response_format", "json", &mut body);
    if !language.is_empty() {
        field("language", language, &mut body);
    }

    body.extend_from_slice(format!("--{BOUNDARY}\r\n").as_bytes());
    body.extend_from_slice(
        b"Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n",
    );
    body.extend_from_slice(b"Content-Type: audio/wav\r\n\r\n");
    body.extend_from_slice(audio);
    body.extend_from_slice(b"\r\n");
    body.extend_from_slice(format!("--{BOUNDARY}--\r\n").as_bytes());

    body
}

/// Extracts the transcript, preferring the API's structured error message over
/// a generic parse failure.
fn parse_response(body: &str) -> Result<String, String> {
    let json: serde_json::Value = serde_json::from_str(body)
        .map_err(|_| "The transcription service returned an unreadable response.".to_string())?;

    if let Some(message) = json
        .get("error")
        .and_then(|e| e.get("message"))
        .and_then(|m| m.as_str())
    {
        return Err(format!("The transcription service reported: {message}"));
    }

    json.get("text")
        .and_then(|t| t.as_str())
        .map(|t| t.trim().to_string())
        .ok_or_else(|| "The transcription response contained no text.".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_successful_response_yields_the_transcript() {
        assert_eq!(
            parse_response(r#"{"text":"  hello world "}"#).unwrap(),
            "hello world"
        );
    }

    #[test]
    fn an_api_error_is_reported_verbatim_rather_than_as_a_parse_failure() {
        let body =
            r#"{"error":{"message":"Invalid API key provided","type":"invalid_request_error"}}"#;
        let err = parse_response(body).unwrap_err();
        assert!(err.contains("Invalid API key provided"));
    }

    #[test]
    fn a_response_without_text_is_an_error_not_an_empty_transcript() {
        // Silently injecting nothing would look like the app dropped the
        // recording; the user should be told the response was unusable.
        assert!(parse_response(r#"{"duration":1.0}"#).is_err());
    }

    #[test]
    fn non_json_is_reported_clearly() {
        let err = parse_response("<html>502 Bad Gateway</html>").unwrap_err();
        assert!(err.contains("unreadable"));
    }

    #[test]
    fn auth_failures_point_at_the_settings_screen() {
        assert!(status_message(401).contains("Settings"));
        assert!(status_message(403).contains("Settings"));
    }

    #[test]
    fn rate_limits_and_server_errors_read_differently() {
        assert!(status_message(429).contains("rate limit"));
        assert!(status_message(503).contains("server error"));
    }

    #[test]
    fn the_multipart_body_carries_every_required_field() {
        let body = build_multipart(b"RIFFfake", "whisper-1", "en");
        let text = String::from_utf8_lossy(&body);

        assert!(text.contains(&format!("--{BOUNDARY}\r\n")));
        assert!(text.contains("name=\"model\""));
        assert!(text.contains("whisper-1"));
        assert!(text.contains("name=\"language\""));
        assert!(text.contains("filename=\"audio.wav\""));
        assert!(text.contains("Content-Type: audio/wav"));
        assert!(text.ends_with(&format!("--{BOUNDARY}--\r\n")));
        assert!(text.contains("RIFFfake"));
    }

    #[test]
    fn an_empty_language_is_omitted_so_the_api_auto_detects() {
        let body = build_multipart(b"x", "whisper-1", "");
        let text = String::from_utf8_lossy(&body);
        assert!(!text.contains("name=\"language\""));
    }

    #[test]
    fn binary_audio_survives_the_body_intact() {
        // A hand-built multipart body must not mangle bytes that happen to
        // look like text.
        let audio: Vec<u8> = (0u8..=255).collect();
        let body = build_multipart(&audio, "whisper-1", "");
        let needle_start = body
            .windows(audio.len())
            .position(|w| w == audio.as_slice())
            .expect("audio bytes should appear verbatim");
        assert!(needle_start > 0);
    }
}

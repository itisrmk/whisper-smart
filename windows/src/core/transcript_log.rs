//! Rolling transcript history, backed by a JSONL file.
//!
//! Port of `TranscriptLogStore.swift`. JSONL rather than a plist so the history
//! is greppable and appending does not require rewriting the whole file.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TranscriptEntry {
    /// Unix epoch seconds. Stored as a number so `jq` can filter on it.
    pub timestamp: u64,
    pub text: String,
    /// Provider display name that produced this transcript.
    #[serde(default)]
    pub provider: String,
}

pub struct TranscriptLog {
    path: PathBuf,
    max_entries: usize,
}

impl TranscriptLog {
    pub fn new(path: PathBuf, max_entries: usize) -> Self {
        Self {
            path,
            max_entries: max_entries.max(1),
        }
    }

    /// Appends an entry, trimming the file when it exceeds `max_entries`.
    pub fn append(&self, entry: &TranscriptEntry) -> anyhow::Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let line = serde_json::to_string(entry)?;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        writeln!(file, "{line}")?;
        drop(file);

        // Trimming rewrites the file, so only do it when there is real slack to
        // reclaim rather than on every single dictation.
        if self.count()? > self.max_entries * 2 {
            self.trim()?;
        }
        Ok(())
    }

    /// Reads entries, newest first, capped at `max_entries`.
    pub fn read(&self) -> anyhow::Result<Vec<TranscriptEntry>> {
        let mut entries = self.read_all()?;
        entries.reverse();
        entries.truncate(self.max_entries);
        Ok(entries)
    }

    pub fn clear(&self) -> anyhow::Result<()> {
        match std::fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(err.into()),
        }
    }

    fn read_all(&self) -> anyhow::Result<Vec<TranscriptEntry>> {
        let file = match std::fs::File::open(&self.path) {
            Ok(f) => f,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(err) => return Err(err.into()),
        };
        let entries = BufReader::new(file)
            .lines()
            .map_while(Result::ok)
            // Skip malformed lines rather than failing the whole read: a
            // partial write from a kill -9 must not hide the entire history.
            .filter_map(|line| serde_json::from_str::<TranscriptEntry>(&line).ok())
            .collect();
        Ok(entries)
    }

    fn count(&self) -> anyhow::Result<usize> {
        Ok(self.read_all()?.len())
    }

    fn trim(&self) -> anyhow::Result<()> {
        let all = self.read_all()?;
        let keep = all.len().saturating_sub(self.max_entries);
        let retained = &all[keep..];
        let mut text = String::new();
        for entry in retained {
            text.push_str(&serde_json::to_string(entry)?);
            text.push('\n');
        }
        let tmp = self.path.with_extension("jsonl.tmp");
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// Current wall-clock time in Unix epoch seconds.
pub fn now_epoch_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_log(name: &str, max: usize) -> (TranscriptLog, PathBuf) {
        let dir = std::env::temp_dir().join(format!("ws-log-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("transcripts.jsonl");
        let _ = std::fs::remove_file(&path);
        (TranscriptLog::new(path.clone(), max), dir)
    }

    fn entry(text: &str) -> TranscriptEntry {
        TranscriptEntry {
            timestamp: 1,
            text: text.to_string(),
            provider: "test".into(),
        }
    }

    #[test]
    fn reads_back_entries_newest_first() {
        let (log, dir) = temp_log("order", 10);
        log.append(&entry("first")).unwrap();
        log.append(&entry("second")).unwrap();
        let read = log.read().unwrap();
        assert_eq!(read.len(), 2);
        assert_eq!(read[0].text, "second");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn missing_file_reads_as_empty_rather_than_erroring() {
        let (log, dir) = temp_log("missing", 10);
        assert!(log.read().unwrap().is_empty());
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn a_corrupt_line_does_not_hide_the_rest_of_the_history() {
        let (log, dir) = temp_log("corrupt", 10);
        log.append(&entry("good")).unwrap();
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(log.path())
            .unwrap();
        writeln!(f, "{{ this is not json").unwrap();
        drop(f);
        log.append(&entry("also good")).unwrap();

        let read = log.read().unwrap();
        assert_eq!(read.len(), 2);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn history_is_trimmed_once_it_grows_past_twice_the_cap() {
        let (log, dir) = temp_log("trim", 3);
        for i in 0..10 {
            log.append(&entry(&format!("entry {i}"))).unwrap();
        }
        let read = log.read().unwrap();
        assert!(
            read.len() <= 3,
            "expected trimming to the cap, got {}",
            read.len()
        );
        // Trimming keeps the newest entries.
        assert_eq!(read[0].text, "entry 9");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn clear_removes_everything() {
        let (log, dir) = temp_log("clear", 10);
        log.append(&entry("gone")).unwrap();
        log.clear().unwrap();
        assert!(log.read().unwrap().is_empty());
        // Clearing twice is not an error.
        log.clear().unwrap();
        std::fs::remove_dir_all(dir).ok();
    }
}

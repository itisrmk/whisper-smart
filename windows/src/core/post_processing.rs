//! Transcript post-processing pipeline.
//!
//! A direct port of `TranscriptPostProcessing.swift` and the subset of
//! `AdvancedTranscriptProcessors.swift` that does not depend on macOS APIs.
//! Every processor is pure text-in/text-out, which keeps the whole pipeline
//! trivially testable and identical in behaviour to the Mac build.
//!
//! Processors run in a fixed order. `is_final` gates the ones that would look
//! wrong mid-utterance: trimming filler words or appending a trailing period
//! while the user is still speaking makes the live overlay jitter.

use once_cell::sync::Lazy;
use regex::Regex;

use crate::core::settings::{Correction, TextSettings, WritingStyle};

/// Context handed to each processor.
#[derive(Debug, Clone, Copy)]
pub struct ProcessingContext {
    /// False for streaming partials, true for the finalised transcript.
    pub is_final: bool,
}

/// A single text transformation.
pub trait Processor: Send + Sync {
    fn process(&self, text: &str, ctx: ProcessingContext) -> String;
}

/// Ordered collection of processors.
pub struct Pipeline {
    processors: Vec<Box<dyn Processor>>,
}

impl Pipeline {
    pub fn new(processors: Vec<Box<dyn Processor>>) -> Self {
        Self { processors }
    }

    /// Builds the pipeline described by the user's text settings.
    pub fn from_settings(settings: &TextSettings) -> Self {
        let mut processors: Vec<Box<dyn Processor>> = Vec::new();

        if settings.voice_command_formatting {
            processors.push(Box::new(VoiceCommandFormatting));
        }
        if settings.trim_filler_words {
            processors.push(Box::new(FillerWordTrimmer));
        }
        if !settings.corrections.is_empty() {
            processors.push(Box::new(CorrectionDictionary::new(
                settings.corrections.clone(),
            )));
        }
        if settings.normalize_spacing {
            processors.push(Box::new(SpacingAndPunctuationNormalizer));
        }
        processors.push(Box::new(SmartSentenceCasing));
        processors.push(Box::new(WritingStyleProcessor {
            style: settings.writing_style,
        }));

        Self::new(processors)
    }

    pub fn process(&self, text: &str, is_final: bool) -> String {
        let ctx = ProcessingContext { is_final };
        self.processors
            .iter()
            .fold(text.to_string(), |acc, p| p.process(&acc, ctx))
    }
}

// ---------------------------------------------------------------------------
// Processors
// ---------------------------------------------------------------------------

/// Strips leading "um", "uh", "erm" … from the finalised transcript.
pub struct FillerWordTrimmer;

static LEADING_FILLER: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)^(?:\s*(?:(?:uh|um|erm|hmm|mm-hmm)[,\s.!?]*)+)+").expect("static regex")
});

impl Processor for FillerWordTrimmer {
    fn process(&self, text: &str, ctx: ProcessingContext) -> String {
        if !ctx.is_final {
            return text.to_string();
        }
        LEADING_FILLER.replace(text, "").trim().to_string()
    }
}

/// Collapses runs of whitespace and fixes spacing around punctuation.
pub struct SpacingAndPunctuationNormalizer;

static MULTI_SPACE: Lazy<Regex> = Lazy::new(|| Regex::new(r"[ \t]{2,}").expect("static regex"));
static SPACE_BEFORE_PUNCT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[ \t]+([,.;:!?])").expect("static regex"));
// The `regex` crate has no backreferences, so a run of one repeated mark is
// spelled out per character. This also means a deliberate mixed run like
// "?!" survives, which reads better than macOS collapsing it to "!".
static REPEATED_PUNCT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?:,{2,}|\.{2,}|;{2,}|:{2,}|!{2,}|\?{2,})").expect("static regex"));
static PUNCT_NO_SPACE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"([,.;:!?])([^\s\d])").expect("static regex"));

impl Processor for SpacingAndPunctuationNormalizer {
    fn process(&self, text: &str, _ctx: ProcessingContext) -> String {
        if text.is_empty() {
            return String::new();
        }
        let out = MULTI_SPACE.replace_all(text, " ");
        let out = SPACE_BEFORE_PUNCT.replace_all(&out, "$1");
        let out = REPEATED_PUNCT.replace_all(&out, |caps: &regex::Captures| {
            caps[0].chars().next().map(String::from).unwrap_or_default()
        });
        // Re-space after punctuation, but never inside a decimal ("3.14") and
        // never before a newline that `new paragraph` just inserted.
        let out = PUNCT_NO_SPACE.replace_all(&out, "$1 $2");
        out.trim().to_string()
    }
}

/// Turns spoken punctuation into characters ("new line" → `\n`).
pub struct VoiceCommandFormatting;

static VOICE_COMMANDS: Lazy<Vec<(Regex, &'static str)>> = Lazy::new(|| {
    // Order matters: "new paragraph" must win over "new line" would-be
    // substrings, and multi-word phrases must be tried before single words.
    let specs: &[(&str, &str)] = &[
        (r"(?i)\bnew paragraph\b", "\n\n"),
        (r"(?i)\bnew line\b", "\n"),
        (r"(?i)\bopen parenthesis\b", "("),
        (r"(?i)\bclose parenthesis\b", ")"),
        (r"(?i)\bquestion mark\b", "?"),
        (r"(?i)\bexclamation mark\b", "!"),
        (r"(?i)\bsemicolon\b", ";"),
        (r"(?i)\bcolon\b", ":"),
        (r"(?i)\bcomma\b", ","),
        (r"(?i)\bperiod\b", "."),
    ];
    specs
        .iter()
        .map(|(p, r)| (Regex::new(p).expect("static regex"), *r))
        .collect()
});

impl Processor for VoiceCommandFormatting {
    fn process(&self, text: &str, _ctx: ProcessingContext) -> String {
        let mut out = text.to_string();
        for (pattern, replacement) in VOICE_COMMANDS.iter() {
            out = pattern.replace_all(&out, *replacement).into_owned();
        }
        out
    }
}

/// Applies the user's literal find/replace pairs, case-insensitively but
/// preserving the replacement exactly as written.
pub struct CorrectionDictionary {
    rules: Vec<(Regex, String)>,
}

impl CorrectionDictionary {
    pub fn new(corrections: Vec<Correction>) -> Self {
        let rules = corrections
            .into_iter()
            .filter(|c| !c.from.trim().is_empty())
            .filter_map(|c| {
                // `from` is user input, so escape it: a stray "(" must not be
                // read as a capture group and break the whole pipeline.
                let pattern = format!(r"(?i)\b{}\b", regex::escape(c.from.trim()));
                Regex::new(&pattern).ok().map(|re| (re, c.to))
            })
            .collect();
        Self { rules }
    }
}

impl Processor for CorrectionDictionary {
    fn process(&self, text: &str, ctx: ProcessingContext) -> String {
        if !ctx.is_final {
            return text.to_string();
        }
        let mut out = text.to_string();
        for (pattern, replacement) in &self.rules {
            // NoExpand: a replacement containing "$1" is a literal, not a group.
            out = pattern
                .replace_all(&out, regex::NoExpand(replacement))
                .into_owned();
        }
        out
    }
}

/// Capitalises sentence starts and the standalone pronoun "i", and appends a
/// terminal period to long finalised transcripts.
pub struct SmartSentenceCasing;

static STANDALONE_I: Lazy<Regex> = Lazy::new(|| Regex::new(r"\bi\b").expect("static regex"));
static SENTENCE_START: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"([.!?]\s+)([a-z])").expect("static regex"));

impl Processor for SmartSentenceCasing {
    fn process(&self, text: &str, ctx: ProcessingContext) -> String {
        if text.is_empty() {
            return String::new();
        }

        let mut out = STANDALONE_I.replace_all(text, "I").into_owned();

        // Uppercase the very first letter.
        if let Some(first) = out.chars().next() {
            if first.is_lowercase() {
                let upper: String = first.to_uppercase().collect();
                out = format!("{upper}{}", &out[first.len_utf8()..]);
            }
        }

        // Uppercase the letter after each sentence terminator.
        out = SENTENCE_START
            .replace_all(&out, |caps: &regex::Captures| {
                format!("{}{}", &caps[1], caps[2].to_uppercase())
            })
            .into_owned();

        // Only add a period to something long enough to be a real sentence;
        // a dictated search term should not gain punctuation it never had.
        if ctx.is_final && out.chars().count() > 24 && !out.ends_with(['.', '!', '?']) {
            out.push('.');
        }

        out
    }
}

/// Light tone adjustments. These are deliberately conservative — the Mac build
/// leaves heavier rewriting to an optional LLM pass, and silently changing a
/// user's words is worse than leaving them alone.
pub struct WritingStyleProcessor {
    pub style: WritingStyle,
}

static CONTRACTIONS: &[(&str, &str)] = &[
    ("can't", "cannot"),
    ("won't", "will not"),
    ("don't", "do not"),
    ("doesn't", "does not"),
    ("didn't", "did not"),
    ("isn't", "is not"),
    ("aren't", "are not"),
    ("wasn't", "was not"),
    ("weren't", "were not"),
    ("it's", "it is"),
    ("i'm", "I am"),
    ("i've", "I have"),
    ("we're", "we are"),
    ("they're", "they are"),
];

impl Processor for WritingStyleProcessor {
    fn process(&self, text: &str, ctx: ProcessingContext) -> String {
        if !ctx.is_final || text.is_empty() {
            return text.to_string();
        }

        match self.style {
            WritingStyle::Neutral | WritingStyle::Casual => text.to_string(),
            WritingStyle::Formal => {
                // Expand contractions; formal prose avoids them.
                let mut out = text.to_string();
                for (short, long) in CONTRACTIONS {
                    let pattern = format!(r"(?i)\b{}\b", regex::escape(short));
                    if let Ok(re) = Regex::new(&pattern) {
                        out = re.replace_all(&out, regex::NoExpand(long)).into_owned();
                    }
                }
                out
            }
            WritingStyle::Concise => {
                // Drop hedging openers that add nothing to a dictated note.
                static HEDGES: Lazy<Regex> = Lazy::new(|| {
                    Regex::new(r"(?i)^(?:so|well|basically|actually|i mean|you know)[,\s]+")
                        .expect("static regex")
                });
                HEDGES.replace(text, "").trim().to_string()
            }
            WritingStyle::Developer => {
                // Spoken code punctuation, mirroring DeveloperDictationProcessor.
                static DEV: Lazy<Vec<(Regex, &'static str)>> = Lazy::new(|| {
                    let specs: &[(&str, &str)] = &[
                        (r"(?i)\bopen brace\b", "{"),
                        (r"(?i)\bclose brace\b", "}"),
                        (r"(?i)\bopen bracket\b", "["),
                        (r"(?i)\bclose bracket\b", "]"),
                        (r"(?i)\bunderscore\b", "_"),
                        (r"(?i)\bdash\b", "-"),
                        (r"(?i)\bdot\b", "."),
                        (r"(?i)\barrow\b", "->"),
                        (r"(?i)\bequals\b", "="),
                    ];
                    specs
                        .iter()
                        .map(|(p, r)| (Regex::new(p).expect("static regex"), *r))
                        .collect()
                });
                let mut out = text.to_string();
                for (pattern, replacement) in DEV.iter() {
                    out = pattern.replace_all(&out, *replacement).into_owned();
                }
                out
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn final_ctx() -> ProcessingContext {
        ProcessingContext { is_final: true }
    }

    fn partial_ctx() -> ProcessingContext {
        ProcessingContext { is_final: false }
    }

    #[test]
    fn filler_words_are_trimmed_only_when_final() {
        let p = FillerWordTrimmer;
        assert_eq!(p.process("um, hello there", final_ctx()), "hello there");
        assert_eq!(p.process("uh um hello", final_ctx()), "hello");
        // Mid-utterance the text must pass through untouched or the live
        // overlay flickers as words are removed and re-added.
        assert_eq!(
            p.process("um, hello there", partial_ctx()),
            "um, hello there"
        );
    }

    #[test]
    fn filler_trimmer_leaves_interior_fillers_alone() {
        let p = FillerWordTrimmer;
        assert_eq!(p.process("hello um there", final_ctx()), "hello um there");
    }

    #[test]
    fn spacing_normalizer_fixes_punctuation_gaps() {
        let p = SpacingAndPunctuationNormalizer;
        assert_eq!(p.process("hello  world", final_ctx()), "hello world");
        assert_eq!(p.process("hello , world", final_ctx()), "hello, world");
        assert_eq!(p.process("hello,world", final_ctx()), "hello, world");
        assert_eq!(p.process("hello.. world", final_ctx()), "hello. world");
    }

    #[test]
    fn spacing_normalizer_leaves_decimals_intact() {
        let p = SpacingAndPunctuationNormalizer;
        assert_eq!(
            p.process("pi is 3.14 exactly", final_ctx()),
            "pi is 3.14 exactly"
        );
    }

    #[test]
    fn voice_commands_become_punctuation() {
        let p = VoiceCommandFormatting;
        assert_eq!(
            p.process("hello comma world period", final_ctx()),
            "hello , world ."
        );
        assert_eq!(
            p.process("line one new line line two", final_ctx()),
            "line one \n line two"
        );
    }

    #[test]
    fn new_paragraph_wins_over_new_line() {
        let p = VoiceCommandFormatting;
        assert_eq!(p.process("a new paragraph b", final_ctx()), "a \n\n b");
    }

    #[test]
    fn voice_commands_do_not_fire_inside_longer_words() {
        let p = VoiceCommandFormatting;
        // "periodic" contains "period" but is not a command.
        assert_eq!(p.process("periodic table", final_ctx()), "periodic table");
    }

    #[test]
    fn corrections_are_applied_literally_and_escaped() {
        let p = CorrectionDictionary::new(vec![
            Correction {
                from: "cloud code".into(),
                to: "Claude Code".into(),
            },
            // Regex metacharacters in user input must not blow up the rule.
            Correction {
                from: "c++".into(),
                to: "C++".into(),
            },
        ]);
        assert_eq!(
            p.process("i love cloud code", final_ctx()),
            "i love Claude Code"
        );
        assert_eq!(
            p.process("Cloud Code rocks", final_ctx()),
            "Claude Code rocks"
        );
    }

    #[test]
    fn corrections_replacement_is_never_treated_as_a_capture_group() {
        let p = CorrectionDictionary::new(vec![Correction {
            from: "price".into(),
            to: "$1 million".into(),
        }]);
        assert_eq!(
            p.process("the price today", final_ctx()),
            "the $1 million today"
        );
    }

    #[test]
    fn corrections_skip_partials() {
        let p = CorrectionDictionary::new(vec![Correction {
            from: "cloud code".into(),
            to: "Claude Code".into(),
        }]);
        assert_eq!(p.process("cloud code", partial_ctx()), "cloud code");
    }

    #[test]
    fn sentence_casing_capitalises_starts_and_the_pronoun_i() {
        let p = SmartSentenceCasing;
        assert_eq!(p.process("hello there", partial_ctx()), "Hello there");
        assert_eq!(
            p.process("i think i am right", partial_ctx()),
            "I think I am right"
        );
        assert_eq!(
            p.process("one. two. three", partial_ctx()),
            "One. Two. Three"
        );
    }

    #[test]
    fn sentence_casing_adds_a_period_only_to_long_final_text() {
        let p = SmartSentenceCasing;
        let long = "this sentence is definitely longer than the threshold";
        assert!(p.process(long, final_ctx()).ends_with('.'));
        // Short text: a dictated search term should not gain punctuation.
        assert_eq!(p.process("hello", final_ctx()), "Hello");
        // Partials never gain a period.
        assert!(!p.process(long, partial_ctx()).ends_with('.'));
    }

    #[test]
    fn sentence_casing_handles_multibyte_leading_characters() {
        let p = SmartSentenceCasing;
        // A naive byte-index slice would panic here.
        assert_eq!(p.process("étoile filante", partial_ctx()), "Étoile filante");
        assert_eq!(
            p.process("日本語のテキスト", partial_ctx()),
            "日本語のテキスト"
        );
    }

    #[test]
    fn formal_style_expands_contractions() {
        let p = WritingStyleProcessor {
            style: WritingStyle::Formal,
        };
        assert_eq!(p.process("i can't do it", final_ctx()), "i cannot do it");
    }

    #[test]
    fn concise_style_drops_leading_hedges() {
        let p = WritingStyleProcessor {
            style: WritingStyle::Concise,
        };
        assert_eq!(
            p.process("basically, we should ship", final_ctx()),
            "we should ship"
        );
        assert_eq!(
            p.process("so we should ship", final_ctx()),
            "we should ship"
        );
    }

    #[test]
    fn neutral_style_is_a_passthrough() {
        let p = WritingStyleProcessor {
            style: WritingStyle::Neutral,
        };
        let input = "so, basically i can't do it";
        assert_eq!(p.process(input, final_ctx()), input);
    }

    #[test]
    fn developer_style_converts_spoken_code_punctuation() {
        let p = WritingStyleProcessor {
            style: WritingStyle::Developer,
        };
        assert_eq!(p.process("foo underscore bar", final_ctx()), "foo _ bar");
    }

    #[test]
    fn full_pipeline_from_default_settings_cleans_a_realistic_transcript() {
        let settings = TextSettings::default();
        let pipeline = Pipeline::from_settings(&settings);
        let out = pipeline.process("um, so  i think this is going to work well", true);
        assert_eq!(out, "So I think this is going to work well.");
    }

    #[test]
    fn full_pipeline_leaves_an_empty_transcript_empty() {
        let pipeline = Pipeline::from_settings(&TextSettings::default());
        assert_eq!(pipeline.process("", true), "");
        assert_eq!(pipeline.process("   ", true), "");
    }
}

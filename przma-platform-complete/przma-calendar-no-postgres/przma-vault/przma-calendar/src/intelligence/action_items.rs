// przma-calendar/src/intelligence/action_items.rs
//
// Action item extraction from meeting transcripts.
// Phase 4: rule-based pattern matching with confidence scoring.
// Phase 6: TFLite NER model replaces pattern matching.

use crate::intelligence::transcript::{ExtractedActionItem, SpeakerTurn};
use regex::Regex;

// ─── EXTRACTION ENGINE ───────────────────────────────────────────────────────

pub struct ActionItemExtractor {
    action_patterns:   Vec<ActionPattern>,
    assignee_patterns: Vec<Regex>,
    due_patterns:      Vec<DuePattern>,
}

struct ActionPattern {
    regex:      Regex,
    confidence: f32,
    category:   &'static str,
}

struct DuePattern {
    regex:  Regex,
    label:  &'static str,
}

impl ActionItemExtractor {
    pub fn new() -> Self {
        let action_patterns = vec![
            ActionPattern {
                regex:      Regex::new(r"(?i)\b(will|should|need to|going to|must|have to|shall)\s+([\w\s]+?)(?:[.,;]|$)").unwrap(),
                confidence: 0.75,
                category:   "commitment",
            },
            ActionPattern {
                regex:      Regex::new(r"(?i)\b(send|write|create|prepare|update|review|check|follow[- ]up on|schedule|book|arrange|make sure)\s+([\w\s]+?)(?:[.,;]|$)").unwrap(),
                confidence: 0.85,
                category:   "action",
            },
            ActionPattern {
                regex:      Regex::new(r"(?i)\baction item[s]?:?\s*([\w\s,]+?)(?:[.\n]|$)").unwrap(),
                confidence: 0.95,
                category:   "explicit",
            },
            ActionPattern {
                regex:      Regex::new(r"(?i)\btodo:?\s*([\w\s,]+?)(?:[.\n]|$)").unwrap(),
                confidence: 0.95,
                category:   "explicit",
            },
            ActionPattern {
                regex:      Regex::new(r"(?i)\bcan you\s+([\w\s]+?)(?:[?.,]|$)").unwrap(),
                confidence: 0.70,
                category:   "request",
            },
            ActionPattern {
                regex:      Regex::new(r"(?i)\blet['']s\s+([\w\s]+?)(?:[.,]|$)").unwrap(),
                confidence: 0.65,
                category:   "collective",
            },
        ];

        let assignee_patterns = vec![
            Regex::new(r"(?i)\b([A-Z][a-z]+)\s+(?:will|should|needs? to|is going to)").unwrap(),
            Regex::new(r"(?i)(?:ask|tell|have)\s+([A-Z][a-z]+)\s+to").unwrap(),
            Regex::new(r"(?i)([A-Z][a-z]+)[:,]\s+(?:please|can you|could you)").unwrap(),
        ];

        let due_patterns = vec![
            DuePattern {
                regex: Regex::new(r"(?i)\bby\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b").unwrap(),
                label: "this week",
            },
            DuePattern {
                regex: Regex::new(r"(?i)\b(by|before)\s+end of (day|week|month)\b").unwrap(),
                label: "end of period",
            },
            DuePattern {
                regex: Regex::new(r"(?i)\b(next|this)\s+(week|month|quarter)\b").unwrap(),
                label: "next period",
            },
            DuePattern {
                regex: Regex::new(r"(?i)\bby\s+(\d{1,2}(?:st|nd|rd|th)?\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*)\b").unwrap(),
                label: "specific date",
            },
            DuePattern {
                regex: Regex::new(r"(?i)\bin\s+(\d+)\s+(days?|hours?|weeks?)\b").unwrap(),
                label: "relative time",
            },
            DuePattern {
                regex: Regex::new(r"(?i)\bASAP\b").unwrap(),
                label: "ASAP",
            },
            DuePattern {
                regex: Regex::new(r"(?i)\btoday\b").unwrap(),
                label: "today",
            },
            DuePattern {
                regex: Regex::new(r"(?i)\btomorrow\b").unwrap(),
                label: "tomorrow",
            },
        ];

        Self { action_patterns, assignee_patterns, due_patterns }
    }

    /// Extract action items from a full transcript text
    pub fn extract_from_text(&self, text: &str) -> Vec<ExtractedActionItem> {
        let mut items     = vec![];
        let mut seen_text = std::collections::HashSet::new();

        for (line_idx, line) in text.lines().enumerate() {
            let line_items = self.extract_from_line(line, line_idx as f32 * 5.0);
            for item in line_items {
                let normalized = item.text.to_lowercase();
                if !seen_text.contains(&normalized) && item.text.len() > 5 {
                    seen_text.insert(normalized);
                    items.push(item);
                }
            }
        }

        // Sort by confidence descending, then by position
        items.sort_by(|a, b| {
            b.confidence.partial_cmp(&a.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        items.truncate(20); // cap at 20 action items per transcript
        items
    }

    /// Extract action items from speaker turns (more context-aware)
    pub fn extract_from_turns(&self, turns: &[SpeakerTurn]) -> Vec<ExtractedActionItem> {
        let mut items = vec![];

        for turn in turns {
            let mut line_items = self.extract_from_line(&turn.text, turn.start_secs);

            // Boost confidence if the turn speaker is identifiable
            if turn.speaker_did.is_some() {
                for item in &mut line_items {
                    item.confidence = (item.confidence * 1.1).min(1.0);
                    if item.assignee_hint.is_none() {
                        item.assignee_hint = turn.speaker_did.clone();
                    }
                }
            }
            items.extend(line_items);
        }

        items.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap_or(std::cmp::Ordering::Equal));
        items.truncate(20);
        items
    }

    fn extract_from_line(&self, line: &str, position_secs: f32) -> Vec<ExtractedActionItem> {
        let mut items = vec![];

        // Strip speaker prefix: "Alice: text" → "text"
        let text = strip_speaker_prefix(line);

        for pattern in &self.action_patterns {
            if let Some(captures) = pattern.regex.captures(text) {
                let matched_text = captures.get(captures.len() - 1)
                    .map(|m| m.as_str().trim())
                    .unwrap_or("")
                    .to_string();

                if matched_text.len() < 4 { continue; }

                let assignee = self.find_assignee(text);
                let due_hint  = self.find_due_hint(text);

                items.push(ExtractedActionItem {
                    text:          clean_action_text(&matched_text),
                    assignee_hint: assignee,
                    due_hint,
                    confidence:    pattern.confidence,
                    start_secs:    position_secs,
                    confirmed:     false,
                });
            }
        }
        items
    }

    fn find_assignee(&self, text: &str) -> Option<String> {
        for pattern in &self.assignee_patterns {
            if let Some(captures) = pattern.captures(text) {
                if let Some(name) = captures.get(1) {
                    let name_str = name.as_str().trim();
                    // Filter out common false positives
                    if !["We", "I", "They", "It", "This", "That"].contains(&name_str) {
                        return Some(name_str.to_string());
                    }
                }
            }
        }
        None
    }

    fn find_due_hint(&self, text: &str) -> Option<String> {
        for pattern in &self.due_patterns {
            if let Some(m) = pattern.regex.find(text) {
                return Some(m.as_str().trim().to_string());
            }
        }
        None
    }
}

// ─── DEDUPLICATION ───────────────────────────────────────────────────────────

/// Merge duplicate action items across multiple extraction passes
pub fn deduplicate(items: Vec<ExtractedActionItem>) -> Vec<ExtractedActionItem> {
    let mut seen: Vec<ExtractedActionItem> = vec![];
    'outer: for item in items {
        for existing in &mut seen {
            if text_similarity(&item.text, &existing.text) > 0.8 {
                // Keep higher confidence version
                if item.confidence > existing.confidence {
                    existing.confidence   = item.confidence;
                    existing.assignee_hint = item.assignee_hint.clone();
                    existing.due_hint      = item.due_hint.clone();
                }
                continue 'outer;
            }
        }
        seen.push(item);
    }
    seen
}

/// Simple Jaccard similarity on word tokens
fn text_similarity(a: &str, b: &str) -> f32 {
    let words_a: std::collections::HashSet<&str> = a.split_whitespace().collect();
    let words_b: std::collections::HashSet<&str> = b.split_whitespace().collect();
    let intersection = words_a.intersection(&words_b).count();
    let union        = words_a.union(&words_b).count();
    if union == 0 { return 0.0; }
    intersection as f32 / union as f32
}

fn strip_speaker_prefix(line: &str) -> &str {
    if let Some(pos) = line.find(':') {
        let prefix = &line[..pos];
        // Check it looks like a name (not a URL or timestamp)
        if prefix.len() < 30 && !prefix.contains('/') && !prefix.contains('.') {
            return line[pos + 1..].trim();
        }
    }
    line
}

fn clean_action_text(text: &str) -> String {
    text.trim()
        .trim_end_matches(|c: char| c == '.' || c == ',' || c == ';')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn extractor() -> ActionItemExtractor {
        ActionItemExtractor::new()
    }

    #[test]
    fn test_extract_explicit_action_item() {
        let e = extractor();
        let items = e.extract_from_text("Action item: send the proposal by Friday");
        assert!(!items.is_empty(), "Should find action item");
        assert!(items[0].confidence >= 0.90);
    }

    #[test]
    fn test_extract_will_commitment() {
        let e = extractor();
        let items = e.extract_from_text("Alice will send the contract by end of week");
        assert!(!items.is_empty());
    }

    #[test]
    fn test_extract_assignee() {
        let e = extractor();
        let items = e.extract_from_text("Bob will review the document tomorrow");
        let assignee = items.iter().find_map(|i| i.assignee_hint.as_ref());
        assert_eq!(assignee, Some(&"Bob".to_string()));
    }

    #[test]
    fn test_extract_due_hint() {
        let e = extractor();
        let items = e.extract_from_text("We need to send the proposal by Friday");
        let due = items.iter().find_map(|i| i.due_hint.as_ref());
        assert!(due.is_some(), "Should find due hint");
    }

    #[test]
    fn test_todo_pattern() {
        let e = extractor();
        let items = e.extract_from_text("TODO: Update the slides before the next meeting");
        assert!(!items.is_empty());
        assert!(items[0].confidence >= 0.90);
    }

    #[test]
    fn test_deduplication() {
        let items = vec![
            ExtractedActionItem {
                text: "send the contract draft".to_string(),
                assignee_hint: None, due_hint: None,
                confidence: 0.8, start_secs: 10.0, confirmed: false,
            },
            ExtractedActionItem {
                text: "send the contract draft".to_string(),
                assignee_hint: Some("Alice".to_string()), due_hint: Some("by Friday".to_string()),
                confidence: 0.9, start_secs: 12.0, confirmed: false,
            },
        ];
        let deduped = deduplicate(items);
        assert_eq!(deduped.len(), 1);
        assert_eq!(deduped[0].confidence, 0.9);
        assert_eq!(deduped[0].assignee_hint, Some("Alice".to_string()));
    }

    #[test]
    fn test_speaker_prefix_stripping() {
        let e = extractor();
        let items = e.extract_from_text("Alice: I will send the report by tomorrow");
        assert!(!items.is_empty());
    }

    #[test]
    fn test_text_similarity() {
        assert!(text_similarity("send the contract", "send the contract") > 0.99);
        assert!(text_similarity("send the contract", "review the document") < 0.5);
    }
}

/// Build the review prompt (background diff review, matches Phoenix template).
pub fn build_review_prompt(raw_diff: &str) -> String {
    format!(
        r#"Review the following diff. Provide:
1. A brief summary of the overall changes (2-3 sentences).
2. Per-file annotations for notable lines. Use NEW file line numbers.

Respond ONLY with JSON in this exact structure:
{{
  "summary": "...",
  "annotations": [
    {{
      "file": "path/to/file",
      "start_line": 10,
      "end_line": 12,
      "comment": "...",
      "severity": "info|warning|issue"
    }}
  ]
}}

The diff:
{raw_diff}"#
    )
}

/// Build the line-comment prompt (user selects lines + writes a comment).
pub fn build_line_prompt(
    file: &str,
    start_line: u32,
    end_line: u32,
    selected_text: &str,
    comment: &str,
) -> String {
    format!(
        "File: {file}\nLines {start_line}-{end_line}:\n```\n{selected_text}\n```\n\n{comment}"
    )
}

/// The JSON schema for review responses (passed to --json-schema).
pub const REVIEW_SCHEMA: &str = r#"{
  "type": "object",
  "required": ["summary", "annotations"],
  "properties": {
    "summary": {"type": "string"},
    "annotations": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["file", "start_line", "end_line", "comment", "severity"],
        "properties": {
          "file": {"type": "string"},
          "start_line": {"type": "integer"},
          "end_line": {"type": "integer"},
          "comment": {"type": "string"},
          "severity": {"type": "string", "enum": ["info", "warning", "issue"]}
        }
      }
    }
  }
}"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn review_prompt_contains_diff() {
        let prompt = build_review_prompt("+fn main() {}");
        assert!(prompt.contains("+fn main() {}"));
        assert!(prompt.contains("annotations"));
        assert!(prompt.contains("severity"));
    }

    #[test]
    fn line_prompt_format() {
        let prompt = build_line_prompt("src/main.rs", 10, 15, "+code here", "fix this");
        assert!(prompt.contains("File: src/main.rs"));
        assert!(prompt.contains("Lines 10-15"));
        assert!(prompt.contains("+code here"));
        assert!(prompt.contains("fix this"));
    }

    #[test]
    fn review_schema_is_valid_json() {
        let parsed: serde_json::Value = serde_json::from_str(REVIEW_SCHEMA).unwrap();
        assert_eq!(parsed["type"], "object");
        assert!(parsed["required"].is_array());
    }
}

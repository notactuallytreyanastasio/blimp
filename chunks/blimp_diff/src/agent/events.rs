use serde::{Deserialize, Serialize};

/// Event types from Claude CLI `--output-format stream-json` (NDJSON).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ClaudeEvent {
    #[serde(rename = "system")]
    System {
        subtype: Option<String>,
        session_id: Option<String>,
        model: Option<String>,
    },
    #[serde(rename = "text")]
    Text {
        content: String,
    },
    #[serde(rename = "tool_use")]
    ToolUse {
        name: String,
        input: serde_json::Value,
    },
    #[serde(rename = "tool_result")]
    ToolResult {
        name: String,
        output: Option<String>,
    },
    #[serde(rename = "result")]
    Result {
        result: Option<String>,
        is_error: Option<bool>,
        usage: Option<Usage>,
    },
    #[serde(rename = "permission_request")]
    PermissionRequest {
        tool: String,
        input: serde_json::Value,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Usage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}

/// Rendered block for the TUI -- accumulated from events.
#[derive(Debug, Clone)]
pub enum Block {
    System {
        model: String,
        session_id: Option<String>,
    },
    Text(String),
    ToolUse {
        name: String,
        input: String,
        output: Option<String>,
    },
    Result {
        text: String,
        is_error: bool,
        tokens: Option<(u64, u64)>,
    },
    PermissionRequest {
        tool: String,
        input: String,
        approved: Option<bool>,
    },
}

/// Parse a single NDJSON line into a ClaudeEvent.
pub fn parse_event(line: &str) -> Option<ClaudeEvent> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    serde_json::from_str(trimmed).ok()
}

/// Convert a ClaudeEvent into a displayable Block.
pub fn event_to_block(event: &ClaudeEvent) -> Option<Block> {
    match event {
        ClaudeEvent::System {
            model, session_id, ..
        } => Some(Block::System {
            model: model.clone().unwrap_or_default(),
            session_id: session_id.clone(),
        }),
        ClaudeEvent::Text { content } => Some(Block::Text(content.clone())),
        ClaudeEvent::ToolUse { name, input } => Some(Block::ToolUse {
            name: name.clone(),
            input: serde_json::to_string_pretty(input).unwrap_or_default(),
            output: None,
        }),
        ClaudeEvent::Result {
            result,
            is_error,
            usage,
        } => Some(Block::Result {
            text: result.clone().unwrap_or_default(),
            is_error: is_error.unwrap_or(false),
            tokens: usage.as_ref().and_then(|u| {
                Some((u.input_tokens?, u.output_tokens?))
            }),
        }),
        ClaudeEvent::PermissionRequest { tool, input } => Some(Block::PermissionRequest {
            tool: tool.clone(),
            input: serde_json::to_string_pretty(input).unwrap_or_default(),
            approved: None,
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_system_event() {
        let line = r#"{"type":"system","subtype":"init","session_id":"abc123","model":"claude-sonnet-4-20250514"}"#;
        let event = parse_event(line).unwrap();
        match event {
            ClaudeEvent::System { session_id, model, .. } => {
                assert_eq!(session_id.as_deref(), Some("abc123"));
                assert_eq!(model.as_deref(), Some("claude-sonnet-4-20250514"));
            }
            _ => panic!("expected System event"),
        }
    }

    #[test]
    fn parse_text_event() {
        let line = r#"{"type":"text","content":"Hello, I'll fix that bug."}"#;
        let event = parse_event(line).unwrap();
        match event {
            ClaudeEvent::Text { content } => {
                assert_eq!(content, "Hello, I'll fix that bug.");
            }
            _ => panic!("expected Text event"),
        }
    }

    #[test]
    fn parse_tool_use_event() {
        let line = r#"{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/test.rs"}}"#;
        let event = parse_event(line).unwrap();
        match event {
            ClaudeEvent::ToolUse { name, input } => {
                assert_eq!(name, "Read");
                assert_eq!(input["file_path"], "/tmp/test.rs");
            }
            _ => panic!("expected ToolUse event"),
        }
    }

    #[test]
    fn parse_result_event() {
        let line = r#"{"type":"result","result":"Done fixing the bug.","is_error":false,"usage":{"input_tokens":500,"output_tokens":200}}"#;
        let event = parse_event(line).unwrap();
        match event {
            ClaudeEvent::Result { result, is_error, usage } => {
                assert_eq!(result.as_deref(), Some("Done fixing the bug."));
                assert_eq!(is_error, Some(false));
                let u = usage.unwrap();
                assert_eq!(u.input_tokens, Some(500));
                assert_eq!(u.output_tokens, Some(200));
            }
            _ => panic!("expected Result event"),
        }
    }

    #[test]
    fn parse_permission_request() {
        let line = r#"{"type":"permission_request","tool":"Bash","input":{"command":"rm -rf /"}}"#;
        let event = parse_event(line).unwrap();
        match event {
            ClaudeEvent::PermissionRequest { tool, input } => {
                assert_eq!(tool, "Bash");
                assert_eq!(input["command"], "rm -rf /");
            }
            _ => panic!("expected PermissionRequest"),
        }
    }

    #[test]
    fn parse_unknown_event() {
        let line = r#"{"type":"some_future_type","data":123}"#;
        let event = parse_event(line).unwrap();
        assert!(matches!(event, ClaudeEvent::Unknown));
    }

    #[test]
    fn parse_empty_line() {
        assert!(parse_event("").is_none());
        assert!(parse_event("  \n").is_none());
    }

    #[test]
    fn parse_invalid_json() {
        assert!(parse_event("not json").is_none());
    }

    #[test]
    fn event_to_block_text() {
        let event = ClaudeEvent::Text { content: "hello".into() };
        let block = event_to_block(&event).unwrap();
        match block {
            Block::Text(s) => assert_eq!(s, "hello"),
            _ => panic!("expected Text block"),
        }
    }

    #[test]
    fn event_to_block_result_with_tokens() {
        let event = ClaudeEvent::Result {
            result: Some("done".into()),
            is_error: Some(false),
            usage: Some(Usage { input_tokens: Some(100), output_tokens: Some(50) }),
        };
        let block = event_to_block(&event).unwrap();
        match block {
            Block::Result { text, is_error, tokens } => {
                assert_eq!(text, "done");
                assert!(!is_error);
                assert_eq!(tokens, Some((100, 50)));
            }
            _ => panic!("expected Result block"),
        }
    }
}

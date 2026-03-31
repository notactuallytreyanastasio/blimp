use std::path::Path;
use std::process::{Command, Child, Stdio};

#[derive(Debug)]
pub struct Claude {
    pub allowed_tools: String,
}

#[derive(Debug)]
pub enum ClaudeError {
    SpawnFailed(std::io::Error),
    InvalidOutput(String),
}

impl std::fmt::Display for ClaudeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClaudeError::SpawnFailed(e) => write!(f, "failed to spawn claude: {}", e),
            ClaudeError::InvalidOutput(s) => write!(f, "invalid claude output: {}", s),
        }
    }
}

impl Default for Claude {
    fn default() -> Self {
        Self {
            allowed_tools: "Read,Grep,Glob,Bash(git:*)".to_string(),
        }
    }
}

impl Claude {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_tools(tools: &str) -> Self {
        Self {
            allowed_tools: tools.to_string(),
        }
    }

    /// Build a prompt from selected diff lines + user comment
    pub fn build_prompt(
        file: &str,
        start_line: u32,
        end_line: u32,
        selected_text: &str,
        comment: &str,
    ) -> String {
        format!(
            "File: {}\nLines {}-{}:\n```\n{}\n```\n\n{}",
            file, start_line, end_line, selected_text, comment,
        )
    }

    /// Spawn a claude process for an agent task.
    /// Returns the Child so the caller can read stdout.
    pub fn dispatch(&self, prompt: &str, repo_path: &Path) -> Result<Child, ClaudeError> {
        Command::new("claude")
            .args([
                "-p",
                prompt,
                "--allowedTools",
                &self.allowed_tools,
                "--output-format",
                "json",
            ])
            .current_dir(repo_path)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(ClaudeError::SpawnFailed)
    }

    /// Spawn a background review of a diff.
    pub fn spawn_review(&self, diff: &str, repo_path: &Path) -> Result<Child, ClaudeError> {
        let prompt = format!(
            "Review this diff for bugs, style issues, and potential problems. \
             Be concise. Output JSON with format: \
             {{\"annotations\": [{{\"file\": \"...\", \"line\": N, \"comment\": \"...\", \
             \"severity\": \"info|warning|error\"}}]}}\n\n```diff\n{}\n```",
            diff,
        );

        self.dispatch(&prompt, repo_path)
    }

    /// Parse the JSON result from a claude invocation.
    pub fn parse_result(output: &str) -> Result<serde_json::Value, ClaudeError> {
        serde_json::from_str(output)
            .map_err(|e| ClaudeError::InvalidOutput(format!("{}: {}", e, output)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_prompt_format() {
        let prompt = Claude::build_prompt(
            "src/main.rs",
            10,
            15,
            "+    println!(\"hello\");\n+    let x = 1;",
            "This looks wrong, fix the variable name",
        );
        assert!(prompt.contains("File: src/main.rs"));
        assert!(prompt.contains("Lines 10-15"));
        assert!(prompt.contains("println!"));
        assert!(prompt.contains("fix the variable name"));
    }

    #[test]
    fn default_tools() {
        let claude = Claude::new();
        assert!(claude.allowed_tools.contains("Read"));
        assert!(claude.allowed_tools.contains("Grep"));
        assert!(claude.allowed_tools.contains("Bash"));
    }

    #[test]
    fn custom_tools() {
        let claude = Claude::with_tools("Read,Write");
        assert_eq!(claude.allowed_tools, "Read,Write");
    }

    #[test]
    fn parse_valid_json() {
        let json = r#"{"result": "fixed the bug"}"#;
        let val = Claude::parse_result(json).unwrap();
        assert_eq!(val["result"], "fixed the bug");
    }

    #[test]
    fn parse_annotations_json() {
        let json = r#"{"annotations": [{"file": "main.rs", "line": 5, "comment": "unused var", "severity": "warning"}]}"#;
        let val = Claude::parse_result(json).unwrap();
        assert_eq!(val["annotations"][0]["file"], "main.rs");
        assert_eq!(val["annotations"][0]["severity"], "warning");
    }

    #[test]
    fn parse_invalid_json_errors() {
        let result = Claude::parse_result("not json");
        assert!(result.is_err());
    }

    // NOTE: dispatch() and spawn_review() are integration tests that
    // require the `claude` binary to be installed. We test the interface
    // not the subprocess. The multiplexer tests below cover the threading.
}

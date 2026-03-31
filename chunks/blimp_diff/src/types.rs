use std::collections::HashMap;
use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Added,
    Modified,
    Deleted,
    Renamed,
    Untracked,
    None,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileEntry {
    pub path: String,
    pub orig_path: Option<String>,
    pub staged: Status,
    pub unstaged: Status,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineKind {
    Addition,
    Deletion,
    Context,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffLine {
    pub kind: LineKind,
    pub content: String,
    pub old_line: Option<u32>,
    pub new_line: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct Hunk {
    pub header: String,
    pub old_start: u32,
    pub old_count: u32,
    pub new_start: u32,
    pub new_count: u32,
    pub lines: Vec<DiffLine>,
    pub collapsed: bool,
    pub highlighted_at: Option<Instant>,
}

#[derive(Debug, Clone)]
pub struct FileDiff {
    pub path: String,
    pub hunks: Vec<Hunk>,
    pub binary: bool,
    pub additions: u32,
    pub deletions: u32,
}

#[derive(Debug, Clone)]
pub struct RepoState {
    pub files: Vec<FileEntry>,
    pub diffs: HashMap<String, FileDiff>,
    pub branch: String,
    pub last_updated: Instant,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogEntry {
    pub hash: String,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_entry_equality() {
        let a = FileEntry {
            path: "src/main.rs".into(),
            orig_path: None,
            staged: Status::Modified,
            unstaged: Status::None,
        };
        let b = a.clone();
        assert_eq!(a, b);
    }

    #[test]
    fn file_entry_rename_has_orig_path() {
        let entry = FileEntry {
            path: "new_name.rs".into(),
            orig_path: Some("old_name.rs".into()),
            staged: Status::Renamed,
            unstaged: Status::None,
        };
        assert_eq!(entry.orig_path.as_deref(), Some("old_name.rs"));
    }

    #[test]
    fn diff_line_kinds() {
        let add = DiffLine {
            kind: LineKind::Addition,
            content: "new line".into(),
            old_line: None,
            new_line: Some(5),
        };
        let del = DiffLine {
            kind: LineKind::Deletion,
            content: "old line".into(),
            old_line: Some(3),
            new_line: None,
        };
        let ctx = DiffLine {
            kind: LineKind::Context,
            content: "unchanged".into(),
            old_line: Some(2),
            new_line: Some(4),
        };
        assert_eq!(add.kind, LineKind::Addition);
        assert_eq!(del.kind, LineKind::Deletion);
        assert_eq!(ctx.kind, LineKind::Context);
    }

    #[test]
    fn hunk_empty_lines() {
        let hunk = Hunk {
            header: "@@ -0,0 +1,0 @@".into(),
            old_start: 0,
            old_count: 0,
            new_start: 1,
            new_count: 0,
            lines: vec![],
            collapsed: false,
            highlighted_at: None,
        };
        assert!(hunk.lines.is_empty());
    }

    #[test]
    fn file_diff_binary() {
        let diff = FileDiff {
            path: "image.png".into(),
            hunks: vec![],
            binary: true,
            additions: 0,
            deletions: 0,
        };
        assert!(diff.binary);
        assert!(diff.hunks.is_empty());
    }

    #[test]
    fn log_entry_equality() {
        let a = LogEntry {
            hash: "abc1234".into(),
            message: "fix: parser bug".into(),
        };
        let b = a.clone();
        assert_eq!(a, b);
    }
}

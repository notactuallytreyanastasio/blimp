use crate::types::{FileEntry, Status};

pub fn parse_status(input: &str) -> Vec<FileEntry> {
    input
        .lines()
        .filter(|line| line.len() >= 4)
        .filter_map(|line| {
            let x = line.as_bytes()[0];
            let y = line.as_bytes()[1];
            let rest = &line[3..];

            // Special case: ?? means untracked (staged=None, unstaged=Untracked)
            let (staged, unstaged) = if x == b'?' && y == b'?' {
                (Status::None, Status::Untracked)
            } else {
                (char_to_status(x), char_to_status(y))
            };

            // Handle renames: "R  old -> new"
            if staged == Status::Renamed || unstaged == Status::Renamed {
                if let Some(arrow) = rest.find(" -> ") {
                    let orig = rest[..arrow].to_string();
                    let path = rest[arrow + 4..].to_string();
                    return Some(FileEntry {
                        path,
                        orig_path: Some(orig),
                        staged,
                        unstaged,
                    });
                }
            }

            Some(FileEntry {
                path: rest.to_string(),
                orig_path: None,
                staged,
                unstaged,
            })
        })
        .collect()
}

fn char_to_status(c: u8) -> Status {
    match c {
        b'M' => Status::Modified,
        b'A' => Status::Added,
        b'D' => Status::Deleted,
        b'R' => Status::Renamed,
        b'?' => Status::Untracked,
        _ => Status::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_returns_empty() {
        assert!(parse_status("").is_empty());
    }

    #[test]
    fn single_modified_unstaged() {
        let entries = parse_status(" M src/main.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "src/main.rs");
        assert_eq!(entries[0].staged, Status::None);
        assert_eq!(entries[0].unstaged, Status::Modified);
    }

    #[test]
    fn single_modified_staged() {
        let entries = parse_status("M  src/main.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].staged, Status::Modified);
        assert_eq!(entries[0].unstaged, Status::None);
    }

    #[test]
    fn both_staged_and_unstaged() {
        let entries = parse_status("MM src/lib.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].staged, Status::Modified);
        assert_eq!(entries[0].unstaged, Status::Modified);
    }

    #[test]
    fn untracked_file() {
        let entries = parse_status("?? new_file.txt\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "new_file.txt");
        assert_eq!(entries[0].staged, Status::None);
        assert_eq!(entries[0].unstaged, Status::Untracked);
    }

    #[test]
    fn added_file() {
        let entries = parse_status("A  src/new.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].staged, Status::Added);
        assert_eq!(entries[0].unstaged, Status::None);
    }

    #[test]
    fn deleted_staged() {
        let entries = parse_status("D  old_file.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].staged, Status::Deleted);
        assert_eq!(entries[0].unstaged, Status::None);
    }

    #[test]
    fn deleted_unstaged() {
        let entries = parse_status(" D old_file.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].staged, Status::None);
        assert_eq!(entries[0].unstaged, Status::Deleted);
    }

    #[test]
    fn renamed_file() {
        let entries = parse_status("R  old_name.rs -> new_name.rs\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "new_name.rs");
        assert_eq!(entries[0].orig_path.as_deref(), Some("old_name.rs"));
        assert_eq!(entries[0].staged, Status::Renamed);
    }

    #[test]
    fn multiple_files() {
        let input = " M src/main.rs\nA  src/new.rs\n?? README.md\n";
        let entries = parse_status(input);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].path, "src/main.rs");
        assert_eq!(entries[1].path, "src/new.rs");
        assert_eq!(entries[2].path, "README.md");
    }

    #[test]
    fn path_with_spaces() {
        let entries = parse_status(" M path with spaces/file.rs\n");
        assert_eq!(entries[0].path, "path with spaces/file.rs");
    }

    #[test]
    fn no_trailing_newline() {
        let entries = parse_status(" M src/main.rs");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "src/main.rs");
    }

    #[test]
    fn blank_lines_ignored() {
        let entries = parse_status(" M src/main.rs\n\n\nA  other.rs\n");
        assert_eq!(entries.len(), 2);
    }
}

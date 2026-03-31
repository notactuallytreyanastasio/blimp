use crate::types::LogEntry;

pub fn parse_log(input: &str) -> Vec<LogEntry> {
    input
        .lines()
        .filter(|line| !line.is_empty())
        .filter_map(|line| {
            let (hash, message) = line.split_once(' ')?;
            Some(LogEntry {
                hash: hash.to_string(),
                message: message.to_string(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_returns_empty() {
        assert!(parse_log("").is_empty());
    }

    #[test]
    fn single_entry() {
        let entries = parse_log("abc1234 fix: parser bug\n");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].hash, "abc1234");
        assert_eq!(entries[0].message, "fix: parser bug");
    }

    #[test]
    fn multiple_entries() {
        let input = "abc1234 fix: parser bug\ndef5678 feat: add actors\nghi9012 refactor: types\n";
        let entries = parse_log(input);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].hash, "abc1234");
        assert_eq!(entries[1].hash, "def5678");
        assert_eq!(entries[2].hash, "ghi9012");
        assert_eq!(entries[2].message, "refactor: types");
    }

    #[test]
    fn no_trailing_newline() {
        let entries = parse_log("abc1234 some message");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].message, "some message");
    }

    #[test]
    fn message_with_spaces() {
        let entries = parse_log("abc1234 fix: this has many words in it\n");
        assert_eq!(entries[0].message, "fix: this has many words in it");
    }

    #[test]
    fn long_hash() {
        let entries = parse_log("abc1234567890 full hash message\n");
        assert_eq!(entries[0].hash, "abc1234567890");
        assert_eq!(entries[0].message, "full hash message");
    }

    #[test]
    fn blank_lines_ignored() {
        let entries = parse_log("abc1234 first\n\ndef5678 second\n");
        assert_eq!(entries.len(), 2);
    }
}

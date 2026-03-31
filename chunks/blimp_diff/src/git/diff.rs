use crate::types::{DiffLine, FileDiff, Hunk, LineKind};

pub fn parse_diff(input: &str) -> Vec<FileDiff> {
    if input.is_empty() {
        return vec![];
    }

    let mut diffs = vec![];
    // Split on "diff --git" boundaries, skip the empty first element
    let sections: Vec<&str> = input.split("diff --git ").collect();

    for section in sections.iter().skip(1) {
        let lines: Vec<&str> = section.lines().collect();
        if lines.is_empty() {
            continue;
        }

        // Check for binary
        let is_binary = lines.iter().any(|l| l.starts_with("Binary files "));
        if is_binary {
            let path = extract_path_from_header(lines[0]);
            diffs.push(FileDiff {
                path,
                hunks: vec![],
                binary: true,
                additions: 0,
                deletions: 0,
            });
            continue;
        }

        // Extract path from +++ line, fallback to --- or header
        let path = lines
            .iter()
            .find(|l| l.starts_with("+++ "))
            .map(|l| {
                let p = l.trim_start_matches("+++ ");
                if p == "/dev/null" {
                    // Deleted file: get path from --- line
                    lines
                        .iter()
                        .find(|l| l.starts_with("--- ") && !l.starts_with("--- /dev/null"))
                        .map(|l| l.trim_start_matches("--- a/").to_string())
                        .unwrap_or_else(|| extract_path_from_header(lines[0]))
                } else {
                    p.trim_start_matches("b/").to_string()
                }
            })
            .unwrap_or_else(|| extract_path_from_header(lines[0]));

        // Parse hunks
        let mut hunks = vec![];
        let mut additions: u32 = 0;
        let mut deletions: u32 = 0;
        let mut current_hunk: Option<HunkBuilder> = None;

        for line in &lines {
            if line.starts_with("@@ ") {
                if let Some(builder) = current_hunk.take() {
                    hunks.push(builder.build());
                }
                if let Some(builder) = parse_hunk_header(line) {
                    current_hunk = Some(builder);
                }
            } else if line.starts_with('\\') {
                // "\ No newline at end of file" -- skip
                continue;
            } else if let Some(ref mut builder) = current_hunk {
                if let Some(first) = line.as_bytes().first() {
                    match first {
                        b'+' => {
                            builder.lines.push(DiffLine {
                                kind: LineKind::Addition,
                                content: line[1..].to_string(),
                                old_line: None,
                                new_line: Some(builder.new_line),
                            });
                            builder.new_line += 1;
                            additions += 1;
                        }
                        b'-' => {
                            builder.lines.push(DiffLine {
                                kind: LineKind::Deletion,
                                content: line[1..].to_string(),
                                old_line: Some(builder.old_line),
                                new_line: None,
                            });
                            builder.old_line += 1;
                            deletions += 1;
                        }
                        b' ' => {
                            builder.lines.push(DiffLine {
                                kind: LineKind::Context,
                                content: line[1..].to_string(),
                                old_line: Some(builder.old_line),
                                new_line: Some(builder.new_line),
                            });
                            builder.old_line += 1;
                            builder.new_line += 1;
                        }
                        _ => {}
                    }
                }
            }
        }

        if let Some(builder) = current_hunk.take() {
            hunks.push(builder.build());
        }

        diffs.push(FileDiff {
            path,
            hunks,
            binary: false,
            additions,
            deletions,
        });
    }

    diffs
}

struct HunkBuilder {
    header: String,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    old_line: u32,
    new_line: u32,
    lines: Vec<DiffLine>,
}

impl HunkBuilder {
    fn build(self) -> Hunk {
        Hunk {
            header: self.header,
            old_start: self.old_start,
            old_count: self.old_count,
            new_start: self.new_start,
            new_count: self.new_count,
            lines: self.lines,
            collapsed: false,
            highlighted_at: None,
        }
    }
}

fn extract_path_from_header(header: &str) -> String {
    // Header format: "a/path b/path"
    if let Some(b_part) = header.split(" b/").last() {
        b_part.to_string()
    } else {
        header.to_string()
    }
}

fn parse_hunk_header(line: &str) -> Option<HunkBuilder> {
    // Format: "@@ -old_start,old_count +new_start,new_count @@"
    let inner = line.trim_start_matches("@@ ").split(" @@").next()?;
    let parts: Vec<&str> = inner.split_whitespace().collect();
    if parts.len() < 2 {
        return None;
    }

    let (old_start, old_count) = parse_range(parts[0].trim_start_matches('-'))?;
    let (new_start, new_count) = parse_range(parts[1].trim_start_matches('+'))?;

    Some(HunkBuilder {
        header: line.to_string(),
        old_start,
        old_count,
        new_start,
        new_count,
        old_line: old_start,
        new_line: new_start,
        lines: vec![],
    })
}

fn parse_range(s: &str) -> Option<(u32, u32)> {
    if let Some((start, count)) = s.split_once(',') {
        Some((start.parse().ok()?, count.parse().ok()?))
    } else {
        let start: u32 = s.parse().ok()?;
        Some((start, 1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_returns_empty() {
        assert!(parse_diff("").is_empty());
    }

    #[test]
    fn single_file_single_hunk() {
        let input = "\
diff --git a/src/main.rs b/src/main.rs
--- a/src/main.rs
+++ b/src/main.rs
@@ -1,3 +1,4 @@
 fn main() {
+    println!(\"hello\");
     let x = 1;
 }
";
        let diffs = parse_diff(input);
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].path, "src/main.rs");
        assert!(!diffs[0].binary);
        assert_eq!(diffs[0].hunks.len(), 1);

        let hunk = &diffs[0].hunks[0];
        assert_eq!(hunk.old_start, 1);
        assert_eq!(hunk.old_count, 3);
        assert_eq!(hunk.new_start, 1);
        assert_eq!(hunk.new_count, 4);
        assert_eq!(hunk.lines.len(), 4);

        // First line is context
        assert_eq!(hunk.lines[0].kind, LineKind::Context);
        assert_eq!(hunk.lines[0].content, "fn main() {");
        assert_eq!(hunk.lines[0].old_line, Some(1));
        assert_eq!(hunk.lines[0].new_line, Some(1));

        // Second line is addition
        assert_eq!(hunk.lines[1].kind, LineKind::Addition);
        assert_eq!(hunk.lines[1].content, "    println!(\"hello\");");
        assert_eq!(hunk.lines[1].old_line, None);
        assert_eq!(hunk.lines[1].new_line, Some(2));

        // Third line is context
        assert_eq!(hunk.lines[2].kind, LineKind::Context);
        assert_eq!(hunk.lines[2].old_line, Some(2));
        assert_eq!(hunk.lines[2].new_line, Some(3));

        // Fourth line is context
        assert_eq!(hunk.lines[3].kind, LineKind::Context);
        assert_eq!(hunk.lines[3].old_line, Some(3));
        assert_eq!(hunk.lines[3].new_line, Some(4));
    }

    #[test]
    fn addition_and_deletion_counts() {
        let input = "\
diff --git a/file.rs b/file.rs
--- a/file.rs
+++ b/file.rs
@@ -1,3 +1,3 @@
 line1
-old line
+new line
 line3
";
        let diffs = parse_diff(input);
        assert_eq!(diffs[0].additions, 1);
        assert_eq!(diffs[0].deletions, 1);
    }

    #[test]
    fn multiple_hunks() {
        let input = "\
diff --git a/file.rs b/file.rs
--- a/file.rs
+++ b/file.rs
@@ -1,3 +1,4 @@
 first
+added
 second
 third
@@ -10,3 +11,3 @@
 ten
-eleven
+ELEVEN
 twelve
";
        let diffs = parse_diff(input);
        assert_eq!(diffs[0].hunks.len(), 2);
        assert_eq!(diffs[0].hunks[0].old_start, 1);
        assert_eq!(diffs[0].hunks[1].old_start, 10);
    }

    #[test]
    fn multiple_files() {
        let input = "\
diff --git a/a.rs b/a.rs
--- a/a.rs
+++ b/a.rs
@@ -1,1 +1,2 @@
 line
+added
diff --git a/b.rs b/b.rs
--- a/b.rs
+++ b/b.rs
@@ -1,1 +1,1 @@
-old
+new
";
        let diffs = parse_diff(input);
        assert_eq!(diffs.len(), 2);
        assert_eq!(diffs[0].path, "a.rs");
        assert_eq!(diffs[1].path, "b.rs");
    }

    #[test]
    fn new_file() {
        let input = "\
diff --git a/new.rs b/new.rs
--- /dev/null
+++ b/new.rs
@@ -0,0 +1,3 @@
+line1
+line2
+line3
";
        let diffs = parse_diff(input);
        assert_eq!(diffs[0].path, "new.rs");
        assert_eq!(diffs[0].additions, 3);
        assert_eq!(diffs[0].deletions, 0);
    }

    #[test]
    fn deleted_file() {
        let input = "\
diff --git a/old.rs b/old.rs
--- a/old.rs
+++ /dev/null
@@ -1,2 +0,0 @@
-line1
-line2
";
        let diffs = parse_diff(input);
        assert_eq!(diffs[0].path, "old.rs");
        assert_eq!(diffs[0].additions, 0);
        assert_eq!(diffs[0].deletions, 2);
    }

    #[test]
    fn binary_file() {
        let input = "\
diff --git a/image.png b/image.png
Binary files a/image.png and b/image.png differ
";
        let diffs = parse_diff(input);
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].path, "image.png");
        assert!(diffs[0].binary);
        assert!(diffs[0].hunks.is_empty());
    }

    #[test]
    fn no_newline_at_end_of_file() {
        let input = "\
diff --git a/file.rs b/file.rs
--- a/file.rs
+++ b/file.rs
@@ -1,1 +1,1 @@
-old
\\ No newline at end of file
+new
\\ No newline at end of file
";
        let diffs = parse_diff(input);
        assert_eq!(diffs[0].hunks[0].lines.len(), 2);
        // The "no newline" markers should not create extra lines
    }

    #[test]
    fn line_numbers_track_correctly() {
        let input = "\
diff --git a/f.rs b/f.rs
--- a/f.rs
+++ b/f.rs
@@ -5,4 +5,5 @@
 context at 5
-deleted at 6
+added at 6
+added at 7
 context at 7->8
 context at 8->9
";
        let diffs = parse_diff(input);
        let lines = &diffs[0].hunks[0].lines;

        // context at old=5, new=5
        assert_eq!(lines[0].old_line, Some(5));
        assert_eq!(lines[0].new_line, Some(5));

        // deletion at old=6
        assert_eq!(lines[1].old_line, Some(6));
        assert_eq!(lines[1].new_line, None);

        // addition at new=6
        assert_eq!(lines[2].old_line, None);
        assert_eq!(lines[2].new_line, Some(6));

        // addition at new=7
        assert_eq!(lines[3].old_line, None);
        assert_eq!(lines[3].new_line, Some(7));

        // context at old=7, new=8
        assert_eq!(lines[4].old_line, Some(7));
        assert_eq!(lines[4].new_line, Some(8));

        // context at old=8, new=9
        assert_eq!(lines[5].old_line, Some(8));
        assert_eq!(lines[5].new_line, Some(9));
    }
}

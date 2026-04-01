#include "git/diff_parser.h"
#include "test_framework.h"

TEST(diff_parser_empty) {
    auto result = blimp::git::parse_diff("");
    ASSERT_EQ(result.size(), 0u);
}

TEST(diff_parser_single_file) {
    std::string input =
        "diff --git a/src/main.cpp b/src/main.cpp\n"
        "index abc123..def456 100644\n"
        "--- a/src/main.cpp\n"
        "+++ b/src/main.cpp\n"
        "@@ -1,3 +1,4 @@\n"
        " #include <stdio.h>\n"
        "+#include <stdlib.h>\n"
        " \n"
        " int main() {\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "src/main.cpp");
    ASSERT_EQ(result[0].hunks.size(), 1u);
    ASSERT_EQ(result[0].additions, 1);
    ASSERT_EQ(result[0].deletions, 0);

    auto& hunk = result[0].hunks[0];
    ASSERT_EQ(hunk.old_start, 1);
    ASSERT_EQ(hunk.old_count, 3);
    ASSERT_EQ(hunk.new_start, 1);
    ASSERT_EQ(hunk.new_count, 4);
    ASSERT_EQ(hunk.lines.size(), 4u);
    ASSERT_EQ(hunk.lines[0].kind, blimp::LineKind::Context);
    ASSERT_EQ(hunk.lines[1].kind, blimp::LineKind::Addition);
    ASSERT_EQ(hunk.lines[1].content, "#include <stdlib.h>");
}

TEST(diff_parser_additions_deletions) {
    std::string input =
        "diff --git a/foo.txt b/foo.txt\n"
        "--- a/foo.txt\n"
        "+++ b/foo.txt\n"
        "@@ -1,3 +1,3 @@\n"
        "-old line\n"
        "+new line\n"
        " unchanged\n"
        " also unchanged\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].additions, 1);
    ASSERT_EQ(result[0].deletions, 1);
}

TEST(diff_parser_binary) {
    std::string input =
        "diff --git a/image.png b/image.png\n"
        "Binary files a/image.png and b/image.png differ\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_TRUE(result[0].binary);
}

TEST(diff_parser_multiple_hunks) {
    std::string input =
        "diff --git a/big.cpp b/big.cpp\n"
        "--- a/big.cpp\n"
        "+++ b/big.cpp\n"
        "@@ -1,2 +1,2 @@\n"
        "-a\n"
        "+b\n"
        " c\n"
        "@@ -10,2 +10,3 @@\n"
        " x\n"
        "+y\n"
        " z\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hunks.size(), 2u);
    ASSERT_EQ(result[0].hunks[0].old_start, 1);
    ASSERT_EQ(result[0].hunks[1].old_start, 10);
}

TEST(diff_parser_line_numbers) {
    std::string input =
        "diff --git a/f.txt b/f.txt\n"
        "--- a/f.txt\n"
        "+++ b/f.txt\n"
        "@@ -5,3 +5,4 @@\n"
        " context\n"
        "+added\n"
        " more context\n"
        "-removed\n";

    auto result = blimp::git::parse_diff(input);
    auto& lines = result[0].hunks[0].lines;

    // Context: old=5, new=5
    ASSERT_EQ(lines[0].old_line.value(), 5);
    ASSERT_EQ(lines[0].new_line.value(), 5);

    // Addition: no old, new=6
    ASSERT_FALSE(lines[1].old_line.has_value());
    ASSERT_EQ(lines[1].new_line.value(), 6);

    // Context: old=6, new=7
    ASSERT_EQ(lines[2].old_line.value(), 6);
    ASSERT_EQ(lines[2].new_line.value(), 7);

    // Deletion: old=7, no new
    ASSERT_EQ(lines[3].old_line.value(), 7);
    ASSERT_FALSE(lines[3].new_line.has_value());
}

// ── Edge case tests ─────────────────────────────────────────────────────────

TEST(diff_parser_no_newline_marker) {
    std::string input =
        "diff --git a/f.txt b/f.txt\n"
        "--- a/f.txt\n"
        "+++ b/f.txt\n"
        "@@ -1,2 +1,2 @@\n"
        "-old line\n"
        "+new line\n"
        "\\ No newline at end of file\n"
        " context\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hunks.size(), 1u);
    // The "\ No newline" marker should be skipped, not counted as a line
    auto& lines = result[0].hunks[0].lines;
    ASSERT_EQ(lines.size(), 3u);
    ASSERT_EQ(lines[0].kind, blimp::LineKind::Deletion);
    ASSERT_EQ(lines[0].content, "old line");
    ASSERT_EQ(lines[1].kind, blimp::LineKind::Addition);
    ASSERT_EQ(lines[1].content, "new line");
    ASSERT_EQ(lines[2].kind, blimp::LineKind::Context);
}

TEST(diff_parser_new_file_only_additions) {
    std::string input =
        "diff --git a/new.txt b/new.txt\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        "+++ b/new.txt\n"
        "@@ -0,0 +1,3 @@\n"
        "+line one\n"
        "+line two\n"
        "+line three\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "new.txt");
    ASSERT_EQ(result[0].additions, 3);
    ASSERT_EQ(result[0].deletions, 0);
    ASSERT_EQ(result[0].hunks.size(), 1u);
    ASSERT_EQ(result[0].hunks[0].old_start, 0);
    ASSERT_EQ(result[0].hunks[0].old_count, 0);
    ASSERT_EQ(result[0].hunks[0].new_start, 1);
    ASSERT_EQ(result[0].hunks[0].new_count, 3);

    for (const auto& line : result[0].hunks[0].lines) {
        ASSERT_EQ(line.kind, blimp::LineKind::Addition);
    }
}

TEST(diff_parser_deleted_file_only_deletions) {
    std::string input =
        "diff --git a/old.txt b/old.txt\n"
        "deleted file mode 100644\n"
        "--- a/old.txt\n"
        "+++ /dev/null\n"
        "@@ -1,3 +0,0 @@\n"
        "-line one\n"
        "-line two\n"
        "-line three\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].additions, 0);
    ASSERT_EQ(result[0].deletions, 3);
    ASSERT_EQ(result[0].hunks.size(), 1u);

    for (const auto& line : result[0].hunks[0].lines) {
        ASSERT_EQ(line.kind, blimp::LineKind::Deletion);
    }
}

TEST(diff_parser_multiple_files) {
    std::string input =
        "diff --git a/a.cpp b/a.cpp\n"
        "--- a/a.cpp\n"
        "+++ b/a.cpp\n"
        "@@ -1,2 +1,3 @@\n"
        " existing\n"
        "+added in a\n"
        " end\n"
        "diff --git a/b.cpp b/b.cpp\n"
        "--- a/b.cpp\n"
        "+++ b/b.cpp\n"
        "@@ -1,2 +1,2 @@\n"
        "-old in b\n"
        "+new in b\n"
        " end\n"
        "diff --git a/c.cpp b/c.cpp\n"
        "--- a/c.cpp\n"
        "+++ b/c.cpp\n"
        "@@ -1,1 +1,1 @@\n"
        "-c old\n"
        "+c new\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 3u);
    ASSERT_EQ(result[0].path, "a.cpp");
    ASSERT_EQ(result[0].additions, 1);
    ASSERT_EQ(result[1].path, "b.cpp");
    ASSERT_EQ(result[1].additions, 1);
    ASSERT_EQ(result[1].deletions, 1);
    ASSERT_EQ(result[2].path, "c.cpp");
    ASSERT_EQ(result[2].additions, 1);
    ASSERT_EQ(result[2].deletions, 1);
}

TEST(diff_parser_empty_hunk) {
    // A hunk with 0,0 range -- technically valid for new/deleted files
    std::string input =
        "diff --git a/empty.txt b/empty.txt\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        "+++ b/empty.txt\n"
        "@@ -0,0 +0,0 @@\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hunks.size(), 1u);
    ASSERT_EQ(result[0].hunks[0].lines.size(), 0u);
    ASSERT_EQ(result[0].hunks[0].old_count, 0);
    ASSERT_EQ(result[0].hunks[0].new_count, 0);
}

TEST(diff_parser_hunk_count_one_no_comma) {
    // When count is 1, git omits the comma: "@@ -5 +5 @@"
    std::string input =
        "diff --git a/f.txt b/f.txt\n"
        "--- a/f.txt\n"
        "+++ b/f.txt\n"
        "@@ -5 +5 @@\n"
        "-old\n"
        "+new\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hunks.size(), 1u);
    ASSERT_EQ(result[0].hunks[0].old_start, 5);
    ASSERT_EQ(result[0].hunks[0].old_count, 1);
    ASSERT_EQ(result[0].hunks[0].new_start, 5);
    ASSERT_EQ(result[0].hunks[0].new_count, 1);
}

TEST(diff_parser_very_long_lines) {
    std::string long_content(2000, 'x');
    std::string input =
        "diff --git a/f.txt b/f.txt\n"
        "--- a/f.txt\n"
        "+++ b/f.txt\n"
        "@@ -1,1 +1,1 @@\n"
        "-" + long_content + "\n"
        "+" + long_content + "y\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hunks[0].lines.size(), 2u);
    ASSERT_EQ(result[0].hunks[0].lines[0].content.size(), 2000u);
    ASSERT_EQ(result[0].hunks[0].lines[1].content.size(), 2001u);
}

TEST(diff_parser_file_path_extraction) {
    // extract_path should get path from "diff --git a/foo b/foo"
    std::string input =
        "diff --git a/src/deep/nested/file.cpp b/src/deep/nested/file.cpp\n"
        "--- a/src/deep/nested/file.cpp\n"
        "+++ b/src/deep/nested/file.cpp\n"
        "@@ -1,1 +1,1 @@\n"
        "-old\n"
        "+new\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "src/deep/nested/file.cpp");
}

TEST(diff_parser_no_index_format) {
    // diff --no-index output uses a/ and b/ prefixed paths like normal
    std::string input =
        "diff --git a/untracked.txt b/untracked.txt\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        "+++ b/untracked.txt\n"
        "@@ -0,0 +1,2 @@\n"
        "+hello\n"
        "+world\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "untracked.txt");
    ASSERT_EQ(result[0].additions, 2);
}

TEST(diff_parser_hunk_header_with_function_context) {
    // Git often appends function context after @@: "@@ -1,3 +1,4 @@ void foo()"
    std::string input =
        "diff --git a/f.cpp b/f.cpp\n"
        "--- a/f.cpp\n"
        "+++ b/f.cpp\n"
        "@@ -10,3 +10,4 @@ void foo() {\n"
        " existing;\n"
        "+added;\n"
        " more;\n"
        " end;\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hunks.size(), 1u);
    ASSERT_EQ(result[0].hunks[0].old_start, 10);
    ASSERT_EQ(result[0].hunks[0].new_count, 4);
}

TEST(diff_parser_path_from_plus_line_overrides) {
    // The +++ b/path line should override the diff --git path
    std::string input =
        "diff --git a/old_name.cpp b/new_name.cpp\n"
        "--- a/old_name.cpp\n"
        "+++ b/new_name.cpp\n"
        "@@ -1,1 +1,1 @@\n"
        "-old\n"
        "+new\n";

    auto result = blimp::git::parse_diff(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "new_name.cpp");
}

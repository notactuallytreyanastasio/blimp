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

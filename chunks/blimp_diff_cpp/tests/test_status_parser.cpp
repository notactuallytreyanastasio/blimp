#include "git/status_parser.h"
#include "test_framework.h"

TEST(status_parser_empty) {
    auto result = blimp::git::parse_status("");
    ASSERT_EQ(result.size(), 0u);
}

TEST(status_parser_modified) {
    auto result = blimp::git::parse_status(" M src/main.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "src/main.cpp");
    ASSERT_EQ(result[0].staged, blimp::Status::None);
    ASSERT_EQ(result[0].unstaged, blimp::Status::Modified);
}

TEST(status_parser_staged_added) {
    auto result = blimp::git::parse_status("A  src/new.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].staged, blimp::Status::Added);
    ASSERT_EQ(result[0].unstaged, blimp::Status::None);
}

TEST(status_parser_untracked) {
    auto result = blimp::git::parse_status("?? build/\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "build/");
    ASSERT_EQ(result[0].unstaged, blimp::Status::Untracked);
}

TEST(status_parser_renamed) {
    auto result = blimp::git::parse_status("R  old.cpp -> new.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "new.cpp");
    ASSERT_EQ(result[0].orig_path, "old.cpp");
    ASSERT_EQ(result[0].staged, blimp::Status::Renamed);
}

TEST(status_parser_multiple) {
    auto result = blimp::git::parse_status(
        " M src/a.cpp\n"
        "M  src/b.cpp\n"
        "?? src/c.cpp\n"
    );
    ASSERT_EQ(result.size(), 3u);
    ASSERT_EQ(result[0].path, "src/a.cpp");
    ASSERT_EQ(result[1].path, "src/b.cpp");
    ASSERT_EQ(result[2].path, "src/c.cpp");
}

TEST(status_parser_partial) {
    auto result = blimp::git::parse_status("MM src/both.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].staged, blimp::Status::Modified);
    ASSERT_EQ(result[0].unstaged, blimp::Status::Modified);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

TEST(status_parser_deleted_staged) {
    auto result = blimp::git::parse_status("D  src/old.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "src/old.cpp");
    ASSERT_EQ(result[0].staged, blimp::Status::Deleted);
    ASSERT_EQ(result[0].unstaged, blimp::Status::None);
}

TEST(status_parser_deleted_unstaged) {
    auto result = blimp::git::parse_status(" D src/old.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "src/old.cpp");
    ASSERT_EQ(result[0].staged, blimp::Status::None);
    ASSERT_EQ(result[0].unstaged, blimp::Status::Deleted);
}

TEST(status_parser_staged_and_unstaged_modified) {
    // MM = staged modified + unstaged modified (edited after staging)
    auto result = blimp::git::parse_status("MM src/both.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "src/both.cpp");
    ASSERT_EQ(result[0].staged, blimp::Status::Modified);
    ASSERT_EQ(result[0].unstaged, blimp::Status::Modified);
}

TEST(status_parser_empty_lines_in_output) {
    // Empty lines and lines shorter than 4 chars should be skipped
    auto result = blimp::git::parse_status(
        "\n"
        " M src/a.cpp\n"
        "\n"
        "\n"
        "M  src/b.cpp\n"
        "\n"
    );
    ASSERT_EQ(result.size(), 2u);
    ASSERT_EQ(result[0].path, "src/a.cpp");
    ASSERT_EQ(result[1].path, "src/b.cpp");
}

TEST(status_parser_file_path_with_spaces) {
    auto result = blimp::git::parse_status(" M path with spaces/my file.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "path with spaces/my file.cpp");
    ASSERT_EQ(result[0].unstaged, blimp::Status::Modified);
}

TEST(status_parser_renamed_with_unstaged_modification) {
    // RM = staged rename + unstaged modification
    auto result = blimp::git::parse_status("RM old.cpp -> new.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "new.cpp");
    ASSERT_EQ(result[0].orig_path, "old.cpp");
    ASSERT_EQ(result[0].staged, blimp::Status::Renamed);
    ASSERT_EQ(result[0].unstaged, blimp::Status::Modified);
}

TEST(status_parser_added_and_modified) {
    // AM = staged added + unstaged modified
    auto result = blimp::git::parse_status("AM src/new.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].path, "src/new.cpp");
    ASSERT_EQ(result[0].staged, blimp::Status::Added);
    ASSERT_EQ(result[0].unstaged, blimp::Status::Modified);
}

TEST(status_parser_short_line_ignored) {
    // Lines shorter than 4 characters should be skipped
    auto result = blimp::git::parse_status("XY\n");
    ASSERT_EQ(result.size(), 0u);
}

TEST(status_parser_deleted_both) {
    // DD = staged deleted + unstaged deleted (conflict marker)
    auto result = blimp::git::parse_status("DD src/conflict.cpp\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].staged, blimp::Status::Deleted);
    ASSERT_EQ(result[0].unstaged, blimp::Status::Deleted);
}

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

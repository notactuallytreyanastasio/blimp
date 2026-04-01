#include "git/log_parser.h"
#include "test_framework.h"

TEST(log_parser_empty) {
    auto result = blimp::git::parse_log("");
    ASSERT_EQ(result.size(), 0u);
}

TEST(log_parser_single) {
    auto result = blimp::git::parse_log("abc1234 Fix the bug\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hash, "abc1234");
    ASSERT_EQ(result[0].message, "Fix the bug");
}

TEST(log_parser_multiple) {
    auto result = blimp::git::parse_log(
        "abc1234 First commit\n"
        "def5678 Second commit\n"
        "ghi9012 Third commit\n"
    );
    ASSERT_EQ(result.size(), 3u);
    ASSERT_EQ(result[0].hash, "abc1234");
    ASSERT_EQ(result[2].message, "Third commit");
}

TEST(log_parser_hash_only) {
    auto result = blimp::git::parse_log("abc1234\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hash, "abc1234");
    ASSERT_EQ(result[0].message, "");
}

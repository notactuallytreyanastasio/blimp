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

// ── Edge case tests ─────────────────────────────────────────────────────────

TEST(log_parser_special_characters_in_message) {
    auto result = blimp::git::parse_log(
        "abc1234 fix: handle \"quotes\" & <angles> in (parens)\n"
    );
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hash, "abc1234");
    ASSERT_EQ(result[0].message, "fix: handle \"quotes\" & <angles> in (parens)");
}

TEST(log_parser_very_long_message) {
    std::string long_msg(500, 'a');
    std::string input = "deadbeef " + long_msg + "\n";
    auto result = blimp::git::parse_log(input);
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hash, "deadbeef");
    ASSERT_EQ(result[0].message.size(), 500u);
}

TEST(log_parser_empty_lines_skipped) {
    auto result = blimp::git::parse_log(
        "abc1234 First\n"
        "\n"
        "def5678 Second\n"
        "\n"
    );
    ASSERT_EQ(result.size(), 2u);
    ASSERT_EQ(result[0].message, "First");
    ASSERT_EQ(result[1].message, "Second");
}

TEST(log_parser_full_length_hash) {
    auto result = blimp::git::parse_log(
        "abc1234567890abcdef1234567890abcdef123456 Full hash commit\n"
    );
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hash, "abc1234567890abcdef1234567890abcdef123456");
    ASSERT_EQ(result[0].message, "Full hash commit");
}

TEST(log_parser_message_with_multiple_spaces) {
    // Only the first space separates hash from message
    auto result = blimp::git::parse_log("abc1234  double  spaces  here\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hash, "abc1234");
    ASSERT_EQ(result[0].message, " double  spaces  here");
}

TEST(log_parser_unicode_in_message) {
    auto result = blimp::git::parse_log("abc1234 feat: add emoji support \xF0\x9F\x9A\x80\n");
    ASSERT_EQ(result.size(), 1u);
    ASSERT_EQ(result[0].hash, "abc1234");
    ASSERT_TRUE(result[0].message.find("\xF0\x9F\x9A\x80") != std::string::npos);
}

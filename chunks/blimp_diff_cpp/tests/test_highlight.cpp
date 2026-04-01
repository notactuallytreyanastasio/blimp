#include "ui/highlight.h"
#include "ui/theme.h"
#include "test_framework.h"

using namespace blimp::ui;

TEST(detect_lang_cpp) {
    ASSERT_EQ(detect_lang("src/main.cpp"), Lang::Cpp);
    ASSERT_EQ(detect_lang("foo.h"), Lang::Cpp);
    ASSERT_EQ(detect_lang("bar.c"), Lang::Cpp);
}

TEST(detect_lang_rust) {
    ASSERT_EQ(detect_lang("src/lib.rs"), Lang::Rust);
}

TEST(detect_lang_python) {
    ASSERT_EQ(detect_lang("script.py"), Lang::Python);
}

TEST(detect_lang_js_ts) {
    ASSERT_EQ(detect_lang("app.js"), Lang::JavaScript);
    ASSERT_EQ(detect_lang("index.tsx"), Lang::TypeScript);
}

TEST(detect_lang_elixir) {
    ASSERT_EQ(detect_lang("lib/app.ex"), Lang::Elixir);
    ASSERT_EQ(detect_lang("test.exs"), Lang::Elixir);
}

TEST(detect_lang_zig) {
    ASSERT_EQ(detect_lang("main.zig"), Lang::Zig);
}

TEST(detect_lang_unknown) {
    ASSERT_EQ(detect_lang("data.bin"), Lang::Unknown);
    ASSERT_EQ(detect_lang("noext"), Lang::Unknown);
}

TEST(highlight_keywords) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("if (x > 0) return true;", Lang::Cpp, colors);
    ASSERT_TRUE(spans.size() > 0u);
    // First span should be "if" keyword
    ASSERT_EQ(spans[0].text, "if");
    ASSERT_EQ(spans[0].fg, 2u); // keyword color
}

TEST(highlight_string) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("let s = \"hello\";", Lang::Rust, colors);
    // Find the string span
    bool found_string = false;
    for (const auto& span : spans) {
        if (span.text == "\"hello\"") {
            ASSERT_EQ(span.fg, 4u); // string color
            found_string = true;
        }
    }
    ASSERT_TRUE(found_string);
}

TEST(highlight_comment) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("x = 1 // comment", Lang::Cpp, colors);
    // Last span should be the comment
    ASSERT_TRUE(spans.size() > 0u);
    ASSERT_EQ(spans.back().fg, 5u); // comment color
}

TEST(highlight_number) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("let x = 42;", Lang::Rust, colors);
    bool found_number = false;
    for (const auto& span : spans) {
        if (span.text == "42") {
            ASSERT_EQ(span.fg, 6u);
            found_number = true;
        }
    }
    ASSERT_TRUE(found_number);
}

TEST(highlight_type) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("let v: Vec<String> = Vec::new();", Lang::Rust, colors);
    bool found_type = false;
    for (const auto& span : spans) {
        if (span.text == "Vec" || span.text == "String") {
            ASSERT_EQ(span.fg, 3u); // type color (CamelCase)
            found_type = true;
        }
    }
    ASSERT_TRUE(found_type);
}

TEST(highlight_empty_and_unknown) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("", Lang::Unknown, colors);
    ASSERT_EQ(spans.size(), 1u);
    ASSERT_TRUE(spans[0].text.empty());

    auto spans2 = highlight_line("just plain text", Lang::Unknown, colors);
    ASSERT_EQ(spans2.size(), 1u);
    ASSERT_EQ(spans2[0].fg, 1u); // plain
}

TEST(highlight_python_comment) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("x = 1 # comment", Lang::Python, colors);
    ASSERT_TRUE(spans.size() > 0u);
    ASSERT_EQ(spans.back().fg, 5u);
}

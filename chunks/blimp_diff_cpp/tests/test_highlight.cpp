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

// ── Edge case tests ─────────────────────────────────────────────────────────

TEST(highlight_rust_attribute) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("#[derive(Debug)]", Lang::Rust, colors);
    ASSERT_TRUE(spans.size() > 0u);
    // The #[derive(Debug)] should be highlighted as keyword (attribute)
    bool found_attr = false;
    for (const auto& span : spans) {
        if (span.text.find("#[") != std::string::npos) {
            ASSERT_EQ(span.fg, 2u); // keyword color for attributes
            found_attr = true;
        }
    }
    ASSERT_TRUE(found_attr);
}

TEST(highlight_rust_lifetime) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    // Lifetimes use single quote -- should not crash or produce infinite loop
    auto spans = highlight_line("fn foo<'a>(x: &'a str) {}", Lang::Rust, colors);
    ASSERT_TRUE(spans.size() > 0u);
    // Just verify it parses without crashing and produces some spans
    // The 'a will be parsed as a string literal starting with '
    bool found_fn = false;
    for (const auto& span : spans) {
        if (span.text == "fn") {
            ASSERT_EQ(span.fg, 2u); // keyword
            found_fn = true;
        }
    }
    ASSERT_TRUE(found_fn);
}

TEST(highlight_go_keywords) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("func main() {", Lang::Go, colors);
    ASSERT_TRUE(spans.size() > 0u);
    ASSERT_EQ(spans[0].text, "func");
    ASSERT_EQ(spans[0].fg, 2u); // keyword

    auto spans2 = highlight_line("go defer select chan", Lang::Go, colors);
    bool found_go = false;
    bool found_defer = false;
    for (const auto& span : spans2) {
        if (span.text == "go") { found_go = true; ASSERT_EQ(span.fg, 2u); }
        if (span.text == "defer") { found_defer = true; ASSERT_EQ(span.fg, 2u); }
    }
    ASSERT_TRUE(found_go);
    ASSERT_TRUE(found_defer);
}

TEST(highlight_elixir_hash_comment) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("x = 1 # this is a comment", Lang::Elixir, colors);
    ASSERT_TRUE(spans.size() > 0u);
    ASSERT_EQ(spans.back().fg, 5u); // comment color
    ASSERT_TRUE(spans.back().text.find("# this is a comment") != std::string::npos);
}

TEST(highlight_ruby_hash_comment) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("puts 'hello' # comment", Lang::Ruby, colors);
    ASSERT_TRUE(spans.size() > 0u);
    ASSERT_EQ(spans.back().fg, 5u); // comment
}

TEST(highlight_nested_string_quotes) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    // Double quotes containing escaped double quotes
    auto spans = highlight_line("let s = \"he said \\\"hi\\\"\";", Lang::Rust, colors);
    bool found_string = false;
    for (const auto& span : spans) {
        if (span.fg == 4u && span.text.find("he said") != std::string::npos) {
            found_string = true;
        }
    }
    ASSERT_TRUE(found_string);
}

TEST(highlight_empty_string_literal) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("let s = \"\";", Lang::Rust, colors);
    bool found_empty_str = false;
    for (const auto& span : spans) {
        if (span.text == "\"\"") {
            ASSERT_EQ(span.fg, 4u); // string color
            found_empty_str = true;
        }
    }
    ASSERT_TRUE(found_empty_str);
}

TEST(highlight_line_only_operators) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("===", Lang::JavaScript, colors);
    ASSERT_TRUE(spans.size() > 0u);
    // Should be parsed as operators, not crash
    bool all_op = true;
    for (const auto& span : spans) {
        if (span.fg != 7u) all_op = false;
    }
    ASSERT_TRUE(all_op);
}

TEST(highlight_line_only_whitespace) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("    ", Lang::Cpp, colors);
    ASSERT_TRUE(spans.size() > 0u);
    // Whitespace should be plain
    ASSERT_EQ(spans[0].fg, 1u);
}

TEST(highlight_very_long_line) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    // 1200 character line: "int x = 0; " repeated many times
    std::string long_line;
    for (int i = 0; i < 120; i++) {
        long_line += "int x = 0; ";
    }
    auto spans = highlight_line(long_line, Lang::Cpp, colors);
    ASSERT_TRUE(spans.size() > 0u);
    // Verify no crash and some keywords detected
    bool found_int = false;
    for (const auto& span : spans) {
        if (span.text == "int") { found_int = true; break; }
    }
    ASSERT_TRUE(found_int);
}

TEST(highlight_c_preprocessor) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    // #include should be treated as keyword/preprocessor in C++
    auto spans = highlight_line("#include <stdio.h>", Lang::Cpp, colors);
    ASSERT_TRUE(spans.size() > 0u);
    // The # triggers preprocessor handling -- rest of line is keyword
    ASSERT_EQ(spans[0].fg, 2u); // keyword color

    auto spans2 = highlight_line("#define MAX 100", Lang::Cpp, colors);
    ASSERT_TRUE(spans2.size() > 0u);
    ASSERT_EQ(spans2[0].fg, 2u); // keyword color
}

TEST(highlight_hex_number) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("int x = 0xff;", Lang::Cpp, colors);
    bool found_hex = false;
    for (const auto& span : spans) {
        if (span.text.find("0xff") != std::string::npos || span.text == "0xff") {
            ASSERT_EQ(span.fg, 6u); // number color
            found_hex = true;
        }
    }
    ASSERT_TRUE(found_hex);
}

TEST(highlight_binary_number) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("let mask = 0b1010;", Lang::Rust, colors);
    bool found_bin = false;
    for (const auto& span : spans) {
        if (span.text.find("0b1010") != std::string::npos || span.text == "0b1010") {
            ASSERT_EQ(span.fg, 6u); // number color
            found_bin = true;
        }
    }
    ASSERT_TRUE(found_bin);
}

TEST(highlight_float_number) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("let pi = 3.14;", Lang::Rust, colors);
    bool found_float = false;
    for (const auto& span : spans) {
        if (span.text.find("3.14") != std::string::npos) {
            ASSERT_EQ(span.fg, 6u); // number color
            found_float = true;
        }
    }
    ASSERT_TRUE(found_float);
}

TEST(highlight_negative_number) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    // Negative numbers: the - is an operator, the digits are a number
    auto spans = highlight_line("int x = -42;", Lang::Cpp, colors);
    bool found_minus = false;
    bool found_num = false;
    for (const auto& span : spans) {
        if (span.text == "-") { found_minus = true; ASSERT_EQ(span.fg, 7u); } // op
        if (span.text == "42" || span.text.find("42") != std::string::npos) {
            found_num = true;
            ASSERT_EQ(span.fg, 6u); // number
        }
    }
    ASSERT_TRUE(found_minus);
    ASSERT_TRUE(found_num);
}

TEST(highlight_function_call_detection) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("foo(bar(), baz())", Lang::Cpp, colors);
    bool found_foo = false;
    bool found_bar = false;
    for (const auto& span : spans) {
        if (span.text == "foo") {
            ASSERT_EQ(span.fg, 8u); // function color
            found_foo = true;
        }
        if (span.text == "bar") {
            ASSERT_EQ(span.fg, 8u); // function color
            found_bar = true;
        }
    }
    ASSERT_TRUE(found_foo);
    ASSERT_TRUE(found_bar);
}

TEST(highlight_camelcase_type_detection) {
    auto colors = HighlightColors{
        .plain = 1, .keyword = 2, .type_name = 3, .string = 4,
        .comment = 5, .number = 6, .op = 7, .function = 8,
    };

    auto spans = highlight_line("MyStruct x = SomeType::new();", Lang::Rust, colors);
    bool found_mystruct = false;
    bool found_sometype = false;
    for (const auto& span : spans) {
        if (span.text == "MyStruct") {
            ASSERT_EQ(span.fg, 3u); // type_name color
            found_mystruct = true;
        }
        if (span.text == "SomeType") {
            ASSERT_EQ(span.fg, 3u); // type_name color
            found_sometype = true;
        }
    }
    ASSERT_TRUE(found_mystruct);
    ASSERT_TRUE(found_sometype);
}

TEST(highlight_detect_lang_go) {
    ASSERT_EQ(detect_lang("main.go"), Lang::Go);
    ASSERT_EQ(detect_lang("src/server.go"), Lang::Go);
}

TEST(highlight_detect_lang_ruby) {
    ASSERT_EQ(detect_lang("app.rb"), Lang::Ruby);
}

TEST(highlight_detect_lang_shell) {
    ASSERT_EQ(detect_lang("script.sh"), Lang::Shell);
    ASSERT_EQ(detect_lang("build.bash"), Lang::Shell);
    ASSERT_EQ(detect_lang("Makefile"), Lang::Shell);
    ASSERT_EQ(detect_lang("Dockerfile"), Lang::Shell);
}

TEST(highlight_detect_lang_various) {
    ASSERT_EQ(detect_lang("style.css"), Lang::Css);
    ASSERT_EQ(detect_lang("page.html"), Lang::Html);
    ASSERT_EQ(detect_lang("config.yml"), Lang::Yaml);
    ASSERT_EQ(detect_lang("config.yaml"), Lang::Yaml);
    ASSERT_EQ(detect_lang("Cargo.toml"), Lang::Toml);
    ASSERT_EQ(detect_lang("data.json"), Lang::Json);
    ASSERT_EQ(detect_lang("README.md"), Lang::Markdown);
    ASSERT_EQ(detect_lang("Main.java"), Lang::Java);
    ASSERT_EQ(detect_lang("Program.cs"), Lang::CSharp);
    ASSERT_EQ(detect_lang("init.lua"), Lang::Lua);
}

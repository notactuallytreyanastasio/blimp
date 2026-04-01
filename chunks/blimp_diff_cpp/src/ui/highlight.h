#pragma once
#include "types.h"
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace blimp::ui {

// A colored span within a line
struct Span {
    std::string text;
    uint32_t fg; // RGB channel
};

enum class TokenKind : uint8_t {
    Plain,
    Keyword,
    Type,
    String,
    Comment,
    Number,
    Operator,
    Function,
};

enum class Lang : uint8_t {
    Unknown,
    Cpp,
    Rust,
    Python,
    JavaScript,
    TypeScript,
    Go,
    Ruby,
    Elixir,
    Zig,
    Shell,
    Lua,
    Java,
    CSharp,
    Css,
    Html,
    Yaml,
    Toml,
    Json,
    Markdown,
};

// Detect language from file extension
[[nodiscard]] Lang detect_lang(std::string_view path);

// Tokenize a line of code into colored spans.
// fg colors are chosen from the theme-aware palette.
struct HighlightColors {
    uint32_t plain;
    uint32_t keyword;
    uint32_t type_name;
    uint32_t string;
    uint32_t comment;
    uint32_t number;
    uint32_t op;
    uint32_t function;
};

[[nodiscard]] std::vector<Span> highlight_line(std::string_view line, Lang lang,
                                                const HighlightColors& colors);

// Build highlight colors from a theme
struct Theme;
[[nodiscard]] HighlightColors colors_for_theme(const Theme& theme);

} // namespace blimp::ui

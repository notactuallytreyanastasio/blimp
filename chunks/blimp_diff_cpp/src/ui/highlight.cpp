#include "ui/highlight.h"
#include "ui/theme.h"
#include <algorithm>
#include <cctype>
#include <cstring>
#include <unordered_set>

namespace blimp::ui {

Lang detect_lang(std::string_view path) {
    auto dot = path.rfind('.');
    if (dot == std::string_view::npos) {
        // Check for common extensionless files
        auto slash = path.rfind('/');
        auto name = (slash != std::string_view::npos) ? path.substr(slash + 1) : path;
        if (name == "Makefile" || name == "Dockerfile" || name == "Justfile")
            return Lang::Shell;
        return Lang::Unknown;
    }
    auto ext = path.substr(dot + 1);

    if (ext == "cpp" || ext == "cc" || ext == "cxx" || ext == "c" || ext == "h" || ext == "hpp" || ext == "hh")
        return Lang::Cpp;
    if (ext == "rs") return Lang::Rust;
    if (ext == "py" || ext == "pyi") return Lang::Python;
    if (ext == "js" || ext == "jsx" || ext == "mjs" || ext == "cjs") return Lang::JavaScript;
    if (ext == "ts" || ext == "tsx") return Lang::TypeScript;
    if (ext == "go") return Lang::Go;
    if (ext == "rb") return Lang::Ruby;
    if (ext == "ex" || ext == "exs" || ext == "heex") return Lang::Elixir;
    if (ext == "zig") return Lang::Zig;
    if (ext == "sh" || ext == "bash" || ext == "zsh") return Lang::Shell;
    if (ext == "lua") return Lang::Lua;
    if (ext == "java") return Lang::Java;
    if (ext == "cs") return Lang::CSharp;
    if (ext == "css" || ext == "scss") return Lang::Css;
    if (ext == "html" || ext == "htm") return Lang::Html;
    if (ext == "yml" || ext == "yaml") return Lang::Yaml;
    if (ext == "toml") return Lang::Toml;
    if (ext == "json") return Lang::Json;
    if (ext == "md" || ext == "markdown") return Lang::Markdown;

    return Lang::Unknown;
}

HighlightColors colors_for_theme(const Theme& theme) {
    // Derive highlight colors from theme palette
    return {
        .plain    = theme.fg.to_channel(),
        .keyword  = theme.accent.to_channel(),
        .type_name = theme.diff_hunk_header.to_channel(), // purple-ish
        .string   = theme.staged_badge.to_channel(),      // green-ish
        .comment  = theme.fg_dim.to_channel(),
        .number   = theme.hot_highlight_bg.to_channel(),   // warm
        .op       = theme.fg_bright.to_channel(),
        .function = theme.fg_bright.to_channel(),
    };
}

namespace {

// Keyword sets by language family
using KWSet = std::unordered_set<std::string_view>;

const KWSet& c_family_keywords() {
    static const KWSet kw = {
        "if", "else", "for", "while", "do", "switch", "case", "break", "continue",
        "return", "void", "int", "char", "float", "double", "long", "short",
        "unsigned", "signed", "const", "static", "extern", "volatile",
        "struct", "union", "enum", "typedef", "sizeof", "goto", "default",
        // C++
        "class", "public", "private", "protected", "virtual", "override",
        "template", "typename", "namespace", "using", "new", "delete",
        "try", "catch", "throw", "noexcept", "constexpr", "consteval",
        "auto", "decltype", "nullptr", "true", "false", "bool",
        "inline", "explicit", "final", "requires", "concept", "co_await",
        "#include", "#define", "#ifdef", "#ifndef", "#endif", "#pragma",
    };
    return kw;
}

const KWSet& rust_keywords() {
    static const KWSet kw = {
        "fn", "let", "mut", "const", "static", "if", "else", "match", "for",
        "while", "loop", "break", "continue", "return", "struct", "enum",
        "impl", "trait", "pub", "use", "mod", "crate", "self", "super",
        "as", "in", "ref", "move", "where", "type", "async", "await",
        "dyn", "unsafe", "extern", "true", "false",
    };
    return kw;
}

const KWSet& python_keywords() {
    static const KWSet kw = {
        "def", "class", "if", "elif", "else", "for", "while", "return",
        "import", "from", "as", "with", "try", "except", "finally",
        "raise", "yield", "lambda", "and", "or", "not", "in", "is",
        "True", "False", "None", "pass", "break", "continue", "del",
        "global", "nonlocal", "assert", "async", "await",
    };
    return kw;
}

const KWSet& js_keywords() {
    static const KWSet kw = {
        "function", "var", "let", "const", "if", "else", "for", "while",
        "do", "switch", "case", "break", "continue", "return", "class",
        "extends", "new", "this", "super", "import", "export", "default",
        "from", "try", "catch", "finally", "throw", "async", "await",
        "yield", "typeof", "instanceof", "in", "of", "true", "false",
        "null", "undefined", "void", "delete",
    };
    return kw;
}

const KWSet& go_keywords() {
    static const KWSet kw = {
        "func", "var", "const", "type", "struct", "interface", "map",
        "chan", "if", "else", "for", "range", "switch", "case", "default",
        "break", "continue", "return", "go", "defer", "select", "package",
        "import", "true", "false", "nil", "make", "new", "len", "cap",
        "append", "copy", "delete", "panic", "recover",
    };
    return kw;
}

const KWSet& elixir_keywords() {
    static const KWSet kw = {
        "def", "defp", "defmodule", "defstruct", "defimpl", "defprotocol",
        "defmacro", "defmacrop", "defguard", "do", "end", "if", "else",
        "unless", "cond", "case", "when", "fn", "with", "for", "in",
        "raise", "rescue", "try", "catch", "after", "receive", "send",
        "spawn", "import", "use", "alias", "require", "true", "false",
        "nil", "and", "or", "not",
    };
    return kw;
}

const KWSet& zig_keywords() {
    static const KWSet kw = {
        "fn", "pub", "const", "var", "if", "else", "for", "while",
        "switch", "break", "continue", "return", "struct", "enum",
        "union", "error", "try", "catch", "unreachable", "undefined",
        "null", "true", "false", "comptime", "inline", "extern",
        "orelse", "and", "or", "test", "defer", "errdefer",
    };
    return kw;
}

const KWSet& get_keywords(Lang lang) {
    switch (lang) {
        case Lang::Cpp:
        case Lang::Java:
        case Lang::CSharp:
            return c_family_keywords();
        case Lang::Rust:        return rust_keywords();
        case Lang::Python:      return python_keywords();
        case Lang::JavaScript:
        case Lang::TypeScript:  return js_keywords();
        case Lang::Go:          return go_keywords();
        case Lang::Elixir:
        case Lang::Ruby:        return elixir_keywords();
        case Lang::Zig:         return zig_keywords();
        default: {
            static const KWSet empty;
            return empty;
        }
    }
}

bool is_ident_char(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) || c == '_';
}

bool is_comment_start(std::string_view line, size_t pos, Lang lang) {
    if (pos + 1 < line.size() && line[pos] == '/' && line[pos + 1] == '/')
        return true;
    if (lang == Lang::Python || lang == Lang::Ruby || lang == Lang::Shell ||
        lang == Lang::Yaml || lang == Lang::Toml || lang == Lang::Elixir) {
        if (line[pos] == '#') return true;
    }
    if (lang == Lang::Lua && pos + 1 < line.size() && line[pos] == '-' && line[pos + 1] == '-')
        return true;
    return false;
}

} // namespace

std::vector<Span> highlight_line(std::string_view line, Lang lang,
                                  const HighlightColors& colors) {
    std::vector<Span> spans;
    if (line.empty() || lang == Lang::Unknown || lang == Lang::Markdown) {
        spans.push_back({std::string(line), colors.plain});
        return spans;
    }

    const auto& keywords = get_keywords(lang);
    size_t i = 0;

    while (i < line.size()) {
        // Comment to end of line
        if (is_comment_start(line, i, lang)) {
            spans.push_back({std::string(line.substr(i)), colors.comment});
            break;
        }

        // String literals
        if (line[i] == '"' || line[i] == '\'' || line[i] == '`') {
            char quote = line[i];
            size_t start = i;
            i++;
            while (i < line.size() && line[i] != quote) {
                if (line[i] == '\\') i++; // skip escaped char
                i++;
            }
            if (i < line.size()) i++; // closing quote
            spans.push_back({std::string(line.substr(start, i - start)), colors.string});
            continue;
        }

        // Numbers
        if (std::isdigit(static_cast<unsigned char>(line[i])) ||
            (line[i] == '.' && i + 1 < line.size() &&
             std::isdigit(static_cast<unsigned char>(line[i + 1])))) {
            size_t start = i;
            // Hex prefix
            if (line[i] == '0' && i + 1 < line.size() &&
                (line[i + 1] == 'x' || line[i + 1] == 'X' || line[i + 1] == 'b' || line[i + 1] == 'o')) {
                i += 2;
            }
            while (i < line.size() &&
                   (std::isxdigit(static_cast<unsigned char>(line[i])) ||
                    line[i] == '.' || line[i] == '_' ||
                    line[i] == 'e' || line[i] == 'E')) {
                i++;
            }
            // Type suffixes like u32, i64, f32, usize
            while (i < line.size() && std::isalpha(static_cast<unsigned char>(line[i]))) i++;
            spans.push_back({std::string(line.substr(start, i - start)), colors.number});
            continue;
        }

        // Identifiers and keywords
        if (is_ident_char(line[i]) && !std::isdigit(static_cast<unsigned char>(line[i]))) {
            size_t start = i;
            while (i < line.size() && is_ident_char(line[i])) i++;
            auto word = line.substr(start, i - start);

            if (keywords.count(word)) {
                spans.push_back({std::string(word), colors.keyword});
            } else if (!word.empty() && std::isupper(static_cast<unsigned char>(word[0]))) {
                // CamelCase = likely type
                spans.push_back({std::string(word), colors.type_name});
            } else if (i < line.size() && line[i] == '(') {
                // Followed by ( = likely function call
                spans.push_back({std::string(word), colors.function});
            } else {
                spans.push_back({std::string(word), colors.plain});
            }
            continue;
        }

        // Operators
        if (line[i] == '=' || line[i] == '+' || line[i] == '-' || line[i] == '*' ||
            line[i] == '/' || line[i] == '<' || line[i] == '>' || line[i] == '!' ||
            line[i] == '&' || line[i] == '|' || line[i] == '^' || line[i] == '~' ||
            line[i] == '%') {
            size_t start = i;
            i++;
            // Consume multi-char operators (==, !=, <=, >=, ->, =>, ::, etc.)
            if (i < line.size() && (line[i] == '=' || line[i] == '>' || line[i] == ':' ||
                                     line[i] == '&' || line[i] == '|')) {
                i++;
            }
            spans.push_back({std::string(line.substr(start, i - start)), colors.op});
            continue;
        }

        // Preprocessor / attributes: # starts a directive (C/C++/C#) or attribute (Rust)
        if (line[i] == '#') {
            if (lang == Lang::Cpp || lang == Lang::CSharp) {
                spans.push_back({std::string(line.substr(i)), colors.keyword});
                break; // rest of line is preprocessor
            }
            // Rust attributes (#[...], #![...]), Python/etc comments handled above
            size_t start = i;
            i++;
            // Consume #[...] or #![...]
            if (i < line.size() && (line[i] == '[' || line[i] == '!')) {
                while (i < line.size() && line[i] != ']') i++;
                if (i < line.size()) i++; // closing ]
            }
            spans.push_back({std::string(line.substr(start, i - start)), colors.keyword});
            continue;
        }

        // Everything else (punctuation, whitespace)
        // SAFETY: this MUST advance i by at least 1 to prevent infinite loops.
        {
            size_t start = i;
            i++; // always advance at least one character
            while (i < line.size() && !is_ident_char(line[i]) &&
                   line[i] != '"' && line[i] != '\'' && line[i] != '`' &&
                   line[i] != '/' && line[i] != '#' && line[i] != '-' &&
                   line[i] != '=' && line[i] != '+' && line[i] != '*' &&
                   line[i] != '<' && line[i] != '>' && line[i] != '!' &&
                   line[i] != '&' && line[i] != '|' && line[i] != '^' &&
                   line[i] != '~' && line[i] != '%' &&
                   !std::isdigit(static_cast<unsigned char>(line[i]))) {
                i++;
            }
            spans.push_back({std::string(line.substr(start, i - start)), colors.plain});
        }
    }

    return spans;
}

} // namespace blimp::ui
// perf: consider caching highlight spans for static lines

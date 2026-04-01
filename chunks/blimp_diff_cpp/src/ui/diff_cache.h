#pragma once
#include "types.h"
#include "ui/highlight.h"
#include <string>
#include <string_view>
#include <vector>

namespace blimp::ui {

struct Theme;

// A lightweight diff line -- stores raw text, NOT pre-highlighted.
// Highlighting happens lazily in the renderer for visible lines only.
struct CachedLine {
    enum Type { HunkHeader, DiffContent };
    Type type = DiffContent;
    LineKind kind = LineKind::Context;
    std::string text;       // raw content (or hunk header)
    int old_line = -1;
    int new_line = -1;
};

// Flattens a FileDiff into a linear array of CachedLines.
// No highlighting -- just metadata + raw text. O(n) with no tokenization.
class DiffCache {
public:
    void rebuild(const FileDiff& diff, std::string_view path);
    void clear();

    [[nodiscard]] const std::vector<CachedLine>& lines() const { return lines_; }
    [[nodiscard]] int line_count() const { return static_cast<int>(lines_.size()); }
    [[nodiscard]] const std::string& cached_path() const { return path_; }
    [[nodiscard]] Lang lang() const { return lang_; }

private:
    std::vector<CachedLine> lines_;
    std::string path_;
    Lang lang_ = Lang::Unknown;
};

} // namespace blimp::ui

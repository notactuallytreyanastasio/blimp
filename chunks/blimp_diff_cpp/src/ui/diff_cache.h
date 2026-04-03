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
    enum Type { SectionHeader, HunkHeader, DiffContent };
    Type type = DiffContent;
    LineKind kind = LineKind::Context;
    std::string text;       // raw content (or hunk/section header)
    int old_line = -1;
    int new_line = -1;
};

// Flattens a CombinedDiff into a linear array of CachedLines.
// If both staged and unstaged exist, inserts section headers.
class DiffCache {
public:
    void rebuild(const CombinedDiff& diff, std::string_view path);
    void clear();
    void invalidate() { lines_.clear(); }  // force rebuild, keep path for scroll preservation

    [[nodiscard]] const std::vector<CachedLine>& lines() const { return lines_; }
    [[nodiscard]] int line_count() const { return static_cast<int>(lines_.size()); }
    [[nodiscard]] const std::string& cached_path() const { return path_; }
    [[nodiscard]] Lang lang() const { return lang_; }

private:
    void append_diff(const FileDiff& diff);
    std::vector<CachedLine> lines_;
    std::string path_;
    Lang lang_ = Lang::Unknown;
};

} // namespace blimp::ui

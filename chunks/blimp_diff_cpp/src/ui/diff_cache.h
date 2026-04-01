#pragma once
#include "types.h"
#include "ui/highlight.h"
#include <string>
#include <unordered_map>
#include <vector>

namespace blimp::ui {

struct Theme;

// A pre-rendered diff line: gutter info + highlighted content spans
struct CachedLine {
    enum Type { HunkHeader, DiffContent };
    Type type = DiffContent;
    LineKind kind = LineKind::Context;
    std::string header_text;        // for hunk headers
    std::vector<Span> content;      // highlighted spans
    int old_line = -1;
    int new_line = -1;
};

// Pre-renders all diff lines for a file with syntax highlighting.
// Call once on file switch; reuse every frame.
class DiffCache {
public:
    void rebuild(const FileDiff& diff, std::string_view path, const Theme& theme);
    void clear();

    [[nodiscard]] const std::vector<CachedLine>& lines() const { return lines_; }
    [[nodiscard]] int line_count() const { return static_cast<int>(lines_.size()); }
    [[nodiscard]] const std::string& cached_path() const { return path_; }

private:
    std::vector<CachedLine> lines_;
    std::string path_;
};

} // namespace blimp::ui

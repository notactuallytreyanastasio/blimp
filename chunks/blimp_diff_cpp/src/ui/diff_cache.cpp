#include "ui/diff_cache.h"
#include "ui/theme.h"

namespace blimp::ui {

void DiffCache::rebuild(const FileDiff& diff, std::string_view path, const Theme& theme) {
    path_ = std::string(path);
    lines_.clear();

    Lang lang = detect_lang(path);
    auto colors = colors_for_theme(theme);

    // Pre-count total lines for reserve
    size_t total = 0;
    for (const auto& hunk : diff.hunks) {
        total += 1 + hunk.lines.size();
    }
    lines_.reserve(total);

    // Cap at 50k lines to prevent freeze on huge diffs.
    // Beyond this we skip highlighting and use plain color.
    constexpr size_t MAX_HIGHLIGHT_LINES = 50000;
    bool skip_highlight = (total > MAX_HIGHLIGHT_LINES);

    for (const auto& hunk : diff.hunks) {
        CachedLine header;
        header.type = CachedLine::HunkHeader;
        header.header_text = hunk.header;
        lines_.push_back(std::move(header));

        for (const auto& dl : hunk.lines) {
            CachedLine cl;
            cl.type = CachedLine::DiffContent;
            cl.kind = dl.kind;
            cl.old_line = dl.old_line.value_or(-1);
            cl.new_line = dl.new_line.value_or(-1);
            if (skip_highlight) {
                cl.content = {{std::string(dl.content), colors.plain}};
            } else {
                cl.content = highlight_line(dl.content, lang, colors);
            }
            lines_.push_back(std::move(cl));
        }
    }
}

void DiffCache::clear() {
    lines_.clear();
    path_.clear();
}

} // namespace blimp::ui

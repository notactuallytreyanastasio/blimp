#include "ui/diff_cache.h"

namespace blimp::ui {

void DiffCache::rebuild(const FileDiff& diff, std::string_view path) {
    path_ = std::string(path);
    lang_ = detect_lang(path);
    lines_.clear();

    // Count total lines for reserve
    size_t total = 0;
    for (const auto& hunk : diff.hunks) {
        total += 1 + hunk.lines.size();
    }
    lines_.reserve(total);

    // Flatten hunks into linear array -- no tokenization, just copies
    for (const auto& hunk : diff.hunks) {
        CachedLine header;
        header.type = CachedLine::HunkHeader;
        header.text = hunk.header;
        lines_.push_back(std::move(header));

        for (const auto& dl : hunk.lines) {
            CachedLine cl;
            cl.type = CachedLine::DiffContent;
            cl.kind = dl.kind;
            cl.text = dl.content;
            cl.old_line = dl.old_line.value_or(-1);
            cl.new_line = dl.new_line.value_or(-1);
            lines_.push_back(std::move(cl));
        }
    }
}

void DiffCache::clear() {
    lines_.clear();
    path_.clear();
    lang_ = Lang::Unknown;
}

} // namespace blimp::ui

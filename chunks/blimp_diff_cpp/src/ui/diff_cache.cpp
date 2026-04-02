#include "ui/diff_cache.h"

namespace blimp::ui {

void DiffCache::append_diff(const FileDiff& diff) {
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

void DiffCache::rebuild(const CombinedDiff& diff, std::string_view path) {
    path_ = std::string(path);
    lang_ = detect_lang(path);
    lines_.clear();

    // Count total for reserve
    size_t total = 0;
    if (diff.has_staged) {
        for (const auto& h : diff.staged.hunks)
            total += 1 + h.lines.size();
        total += 1; // section header
    }
    if (diff.has_unstaged) {
        for (const auto& h : diff.unstaged.hunks)
            total += 1 + h.lines.size();
        total += 1; // section header
    }
    lines_.reserve(total);

    // Staged section first (what will be committed)
    if (diff.has_staged && !diff.staged.hunks.empty()) {
        if (diff.has_unstaged && !diff.unstaged.hunks.empty()) {
            // Only show section headers when BOTH exist
            CachedLine sec;
            sec.type = CachedLine::SectionHeader;
            sec.text = "── Staged ──";
            lines_.push_back(std::move(sec));
        }
        append_diff(diff.staged);
    }

    // Unstaged section (working tree changes not yet staged)
    if (diff.has_unstaged && !diff.unstaged.hunks.empty()) {
        if (diff.has_staged && !diff.staged.hunks.empty()) {
            CachedLine sec;
            sec.type = CachedLine::SectionHeader;
            sec.text = "── Unstaged ──";
            lines_.push_back(std::move(sec));
        }
        append_diff(diff.unstaged);
    }
}

void DiffCache::clear() {
    lines_.clear();
    path_.clear();
    lang_ = Lang::Unknown;
}

} // namespace blimp::ui

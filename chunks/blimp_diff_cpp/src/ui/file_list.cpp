#include "ui/file_list.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "types.h"
#include "state/navigation.h"

#include <algorithm>
#include <cstdio>

namespace blimp::ui {

namespace {

char status_icon(Status s) {
    switch (s) {
        case Status::Added:     return 'A';
        case Status::Modified:  return 'M';
        case Status::Deleted:   return 'D';
        case Status::Renamed:   return 'R';
        case Status::Untracked: return '?';
        default:                return ' ';
    }
}

} // namespace

void render_file_list(struct ncplane* plane, const Theme& theme,
                      const RepoState& repo, const state::Navigation& nav,
                      int y, int x, int h, int w, bool focused) {
    if (w < 4 || h < 1) return;

    // Border color
    uint32_t border_fg = focused
        ? theme.border_active.to_channel()
        : theme.border_inactive.to_channel();
    uint32_t bg = theme.bg.to_channel();

    // Title
    put_str(plane, y, x + 1, " Files ", border_fg, bg);

    // Virtual scroll: show files around current index
    size_t file_count = repo.files.size();
    size_t selected = nav.file_index();
    int visible_h = h;

    // Calculate scroll window
    size_t scroll_offset = 0;
    if (selected >= static_cast<size_t>(visible_h)) {
        scroll_offset = selected - static_cast<size_t>(visible_h) / 2;
    }

    for (int row = 0; row < visible_h; row++) {
        size_t file_idx = scroll_offset + static_cast<size_t>(row);
        int draw_y = y + row;

        if (file_idx >= file_count) {
            // Empty row
            hline(plane, draw_y, x, w, 0, bg);
            continue;
        }

        const auto& file = repo.files[file_idx];
        bool is_selected = (file_idx == selected);

        uint32_t row_bg = is_selected ? theme.bg_selected.to_channel() : bg;
        uint32_t row_fg = is_selected ? theme.fg_bright.to_channel() : theme.fg.to_channel();

        // Clear row
        hline(plane, draw_y, x, w, 0, row_bg);

        // Status icon
        char icon = status_icon(file.unstaged != Status::None ? file.unstaged : file.staged);
        char icon_str[2] = {icon, '\0'};

        uint32_t icon_fg = theme.fg_dim.to_channel();
        if (icon == 'A' || icon == '?') icon_fg = theme.diff_add_fg.to_channel();
        else if (icon == 'D') icon_fg = theme.diff_del_fg.to_channel();
        else if (icon == 'M') icon_fg = theme.accent.to_channel();

        put_str(plane, draw_y, x + 1, icon_str, icon_fg, row_bg);

        // Staged badge
        if (file.staged != Status::None) {
            put_str(plane, draw_y, x + 2, "S", theme.staged_badge.to_channel(), row_bg);
        }

        // Filename (truncated)
        int name_x = x + 4;
        int name_w = w - 4;

        // Add +/- counts if we have diff data
        auto it = repo.diffs.find(file.path);
        std::string suffix;
        if (it != repo.diffs.end()) {
            char buf[32];
            snprintf(buf, sizeof(buf), " +%d -%d",
                     it->second.total_additions(), it->second.total_deletions());
            suffix = buf;
            name_w -= static_cast<int>(suffix.size());
        }

        put_str_trunc(plane, draw_y, name_x, file.path.c_str(), name_w, row_fg, row_bg);

        if (!suffix.empty()) {
            int suffix_x = name_x + std::min(static_cast<int>(file.path.size()), name_w);
            put_str(plane, draw_y, suffix_x, suffix.c_str(),
                    theme.fg_dim.to_channel(), row_bg);
        }
    }
}

} // namespace blimp::ui
// TODO: add mouse click support

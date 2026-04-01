#include "ui/log_view.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "state/navigation.h"

#include <algorithm>

namespace blimp::ui {

void render_log_view(struct ncplane* plane, const Theme& theme,
                     const std::vector<LogEntry>& entries,
                     const state::Navigation& nav,
                     int y, int x, int h, int w) {
    uint32_t bg = theme.bg.to_channel();

    // Title
    put_str(plane, y, x + 1, " Log ", theme.accent.to_channel(), bg);

    if (entries.empty()) {
        put_str(plane, y + 1, x + 1, "No commits", theme.fg_dim.to_channel(), bg);
        return;
    }

    int visible_h = h - 1; // -1 for title row
    size_t selected = nav.log_index();

    // Virtual scroll
    size_t scroll_offset = 0;
    if (selected >= static_cast<size_t>(visible_h)) {
        scroll_offset = selected - static_cast<size_t>(visible_h) / 2;
    }

    for (int row = 0; row < visible_h; row++) {
        size_t idx = scroll_offset + static_cast<size_t>(row);
        int draw_y = y + 1 + row;

        if (idx >= entries.size()) {
            hline(plane, draw_y, x, w, 0, bg);
            continue;
        }

        const auto& entry = entries[idx];
        bool is_selected = (idx == selected);

        uint32_t row_bg = is_selected ? theme.bg_selected.to_channel() : bg;
        uint32_t hash_fg = theme.accent.to_channel();
        uint32_t msg_fg = is_selected ? theme.fg_bright.to_channel() : theme.fg.to_channel();

        // Clear row
        hline(plane, draw_y, x, w, 0, row_bg);

        // Hash (7 chars)
        std::string short_hash = entry.hash.substr(0, 7);
        put_str(plane, draw_y, x + 1, short_hash.c_str(), hash_fg, row_bg);

        // Message
        int msg_x = x + 10;
        int msg_w = w - 11;
        if (msg_w > 0) {
            put_str_trunc(plane, draw_y, msg_x, entry.message.c_str(),
                          msg_w, msg_fg, row_bg);
        }
    }
}

} // namespace blimp::ui

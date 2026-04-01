#include "ui/overlays.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "state/commit.h"

#include <algorithm>
#include <sstream>
#include <string>
#include <vector>

namespace blimp::ui {

struct ncplane* create_overlay_plane(struct ncplane* std_plane,
                                     int total_h, int total_w) {
    int box_w = std::max(40, total_w * 60 / 100);
    int box_h = std::max(10, total_h * 40 / 100);
    int box_y = (total_h - box_h) / 2;
    int box_x = (total_w - box_w) / 2;

    struct ncplane_options nopts{};
    nopts.y = box_y;
    nopts.x = box_x;
    nopts.rows = static_cast<unsigned>(box_h);
    nopts.cols = static_cast<unsigned>(box_w);
    nopts.name = "commit-overlay";

    struct ncplane* overlay = ncplane_create(std_plane, &nopts);
    if (!overlay) return nullptr;

    // The overlay is opaque -- we WANT it to cover the background.
    // No transparency needed here since it's a modal dialog.
    return overlay;
}

void render_commit_overlay(struct ncplane* overlay, const Theme& theme,
                           const state::CommitState& commit_state,
                           state::CommitMode mode) {
    unsigned rows = 0, cols = 0;
    ncplane_dim_yx(overlay, &rows, &cols);

    int box_h = static_cast<int>(rows);
    int box_w = static_cast<int>(cols);

    uint32_t bg = theme.bg_selected.to_channel();
    uint32_t fg = theme.fg.to_channel();
    uint32_t border = theme.border_active.to_channel();

    // Clear overlay plane
    ncplane_set_bg_rgb(overlay, bg);
    ncplane_erase(overlay);

    // Top border (coordinates relative to overlay plane, not terminal)
    hline(overlay, 0, 0, box_w, border, bg);

    // Title
    const char* title = (mode == state::CommitMode::Amend)
        ? " Amend Commit " : " Commit ";
    put_str(overlay, 0, 2, title, border, bg);

    // Message area
    int msg_y = 2;
    int msg_x = 2;
    int msg_w = box_w - 4;
    int msg_max_lines = box_h - 5;

    const auto& msg = commit_state.message();

    // Split message into lines
    std::vector<std::string> lines;
    std::istringstream stream(msg);
    std::string line;
    while (std::getline(stream, line)) {
        lines.push_back(line);
    }
    if (msg.empty() || (!msg.empty() && msg.back() == '\n')) {
        lines.emplace_back();
    }

    int visible_lines = std::min(static_cast<int>(lines.size()), msg_max_lines);
    int scroll = 0;
    if (static_cast<int>(lines.size()) > msg_max_lines) {
        scroll = static_cast<int>(lines.size()) - msg_max_lines;
    }

    for (int i = 0; i < visible_lines; i++) {
        int line_idx = scroll + i;
        if (line_idx < static_cast<int>(lines.size())) {
            put_str_trunc(overlay, msg_y + i, msg_x,
                          lines[static_cast<size_t>(line_idx)].c_str(),
                          msg_w, fg, bg);
        }
    }

    // Cursor
    int cursor_line = static_cast<int>(lines.size()) - 1 - scroll;
    cursor_line = std::clamp(cursor_line, 0, visible_lines - 1);
    int cursor_col = static_cast<int>(lines[static_cast<size_t>(cursor_line + scroll)].size());
    cursor_col = std::min(cursor_col, msg_w - 1);

    put_str(overlay, msg_y + cursor_line, msg_x + cursor_col,
            "▋", theme.accent.to_channel(), bg);

    // Error
    if (!commit_state.error().empty()) {
        put_str_trunc(overlay, box_h - 2, msg_x,
                      commit_state.error().c_str(), msg_w,
                      theme.error.to_channel(), bg);
    }

    // Hint
    put_str(overlay, box_h - 1, msg_x,
            "Ctrl+Enter: submit  Esc: cancel  Enter: newline",
            theme.fg_dim.to_channel(), bg);
}

} // namespace blimp::ui

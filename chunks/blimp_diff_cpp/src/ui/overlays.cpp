#include "ui/overlays.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "state/commit.h"

#include <algorithm>
#include <sstream>
#include <string>
#include <vector>

namespace blimp::ui {

void render_commit_overlay(struct ncplane* plane, const Theme& theme,
                           const state::CommitState& commit_state,
                           state::CommitMode mode,
                           int total_h, int total_w) {
    int box_w = std::max(40, total_w * 60 / 100);
    int box_h = std::max(10, total_h * 40 / 100);
    int box_x = (total_w - box_w) / 2;
    int box_y = (total_h - box_h) / 2;

    uint32_t bg = theme.bg_selected.to_channel();
    uint32_t fg = theme.fg.to_channel();
    uint32_t border = theme.border_active.to_channel();

    // Fill background
    fill_rect(plane, box_y, box_x, box_h, box_w, bg);

    // Top border
    hline(plane, box_y, box_x, box_w, border, bg);

    // Title
    const char* title = (mode == state::CommitMode::Amend)
        ? " Amend Commit " : " Commit ";
    put_str(plane, box_y, box_x + 2, title, border, bg);

    // Message area
    int msg_y = box_y + 2;
    int msg_x = box_x + 2;
    int msg_w = box_w - 4;
    int msg_max_lines = box_h - 5; // room for title, error, hint

    const auto& msg = commit_state.message();

    // Split message into lines
    std::vector<std::string> lines;
    std::istringstream stream(msg);
    std::string line;
    while (std::getline(stream, line)) {
        lines.push_back(line);
    }
    // If message ends with newline or is empty, add empty line for cursor
    if (msg.empty() || (!msg.empty() && msg.back() == '\n')) {
        lines.emplace_back();
    }

    // Render each line
    int visible_lines = std::min(static_cast<int>(lines.size()), msg_max_lines);
    // Scroll to keep cursor visible
    int scroll = 0;
    if (static_cast<int>(lines.size()) > msg_max_lines) {
        scroll = static_cast<int>(lines.size()) - msg_max_lines;
    }

    for (int i = 0; i < visible_lines; i++) {
        int line_idx = scroll + i;
        if (line_idx < static_cast<int>(lines.size())) {
            put_str_trunc(plane, msg_y + i, msg_x,
                          lines[static_cast<size_t>(line_idx)].c_str(),
                          msg_w, fg, bg);
        }
    }

    // Cursor: at end of last visible line
    int cursor_line = static_cast<int>(lines.size()) - 1 - scroll;
    cursor_line = std::clamp(cursor_line, 0, visible_lines - 1);
    int cursor_col = static_cast<int>(lines[static_cast<size_t>(cursor_line + scroll)].size());
    cursor_col = std::min(cursor_col, msg_w - 1);

    put_str(plane, msg_y + cursor_line, msg_x + cursor_col,
            "▋", theme.accent.to_channel(), bg);

    // Error message
    if (!commit_state.error().empty()) {
        put_str_trunc(plane, box_y + box_h - 2, msg_x,
                      commit_state.error().c_str(), msg_w,
                      theme.error.to_channel(), bg);
    }

    // Bottom hint
    put_str(plane, box_y + box_h - 1, msg_x,
            "Ctrl+Enter: submit  Esc: cancel  Enter: newline",
            theme.fg_dim.to_channel(), bg);
}

} // namespace blimp::ui

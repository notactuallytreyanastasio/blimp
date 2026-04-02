#include "ui/overlays.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "state/commit.h"
#include "state/agent.h"

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

    // Set base cell to opaque background so the overlay fully covers
    // whatever is underneath on the standard plane.
    uint64_t channels = 0;
    ncchannels_set_bg_rgb(&channels, 0); // will be set properly on each render
    ncchannels_set_bg_alpha(&channels, NCALPHA_OPAQUE);
    ncchannels_set_fg_alpha(&channels, NCALPHA_OPAQUE);
    ncplane_set_base(overlay, " ", 0, channels);

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

    // Set base cell to theme bg so erase fills with the right color
    uint64_t base_ch = 0;
    ncchannels_set_bg_rgb(&base_ch, bg);
    ncchannels_set_fg_rgb(&base_ch, fg);
    ncplane_set_base(overlay, " ", 0, base_ch);
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

struct ncplane* create_agent_plane(struct ncplane* std_plane,
                                    int total_h, int total_w) {
    int box_w = std::max(50, total_w * 80 / 100);
    int box_h = std::max(15, total_h * 70 / 100);
    int box_y = (total_h - box_h) / 2;
    int box_x = (total_w - box_w) / 2;

    struct ncplane_options nopts{};
    nopts.y = box_y;
    nopts.x = box_x;
    nopts.rows = static_cast<unsigned>(box_h);
    nopts.cols = static_cast<unsigned>(box_w);
    nopts.name = "agent-overlay";

    struct ncplane* overlay = ncplane_create(std_plane, &nopts);
    if (!overlay) return nullptr;

    uint64_t channels = 0;
    ncchannels_set_bg_alpha(&channels, NCALPHA_OPAQUE);
    ncchannels_set_fg_alpha(&channels, NCALPHA_OPAQUE);
    ncplane_set_base(overlay, " ", 0, channels);

    return overlay;
}

void render_agent_overlay(struct ncplane* overlay, const Theme& theme,
                          const state::AgentState& agent_state) {
    unsigned rows = 0, cols = 0;
    ncplane_dim_yx(overlay, &rows, &cols);

    int box_h = static_cast<int>(rows);
    int box_w = static_cast<int>(cols);

    uint32_t bg = theme.bg_selected.to_channel();
    uint32_t fg = theme.fg.to_channel();
    uint32_t border = theme.border_active.to_channel();
    uint32_t dim = theme.fg_dim.to_channel();
    uint32_t accent = theme.accent.to_channel();

    // Set base cell so erase fills with correct bg
    uint64_t base_ch = 0;
    ncchannels_set_bg_rgb(&base_ch, bg);
    ncchannels_set_fg_rgb(&base_ch, fg);
    ncplane_set_base(overlay, " ", 0, base_ch);
    ncplane_erase(overlay);

    // Top border + title
    hline(overlay, 0, 0, box_w, border, bg);
    const char* title = " Claude ";
    if (agent_state.phase() == state::AgentPhase::Running) {
        title = " Claude (streaming...) ";
    } else if (agent_state.phase() == state::AgentPhase::Ready) {
        title = " Claude (ready) ";
    }
    put_str(overlay, 0, 2, title, accent, bg);

    int content_x = 2;
    int content_w = box_w - 4;
    auto phase = agent_state.phase();

    if (phase == state::AgentPhase::Prompting) {
        // Show selected lines (dimmed) then prompt input
        int y = 2;

        // Selected code preview (compact)
        const auto& lines = agent_state.selected_lines();
        int preview_max = std::min(static_cast<int>(lines.size()), box_h / 3);
        for (int i = 0; i < preview_max && y < box_h - 5; i++) {
            std::string prefix = (i == 0 ? "  " : "  ");
            std::string display = prefix + lines[static_cast<size_t>(i)];
            put_str_trunc(overlay, y, content_x, display.c_str(),
                          content_w, dim, bg);
            y++;
        }
        if (static_cast<int>(lines.size()) > preview_max) {
            char more[32];
            snprintf(more, sizeof(more), "  ... +%d more lines",
                     static_cast<int>(lines.size()) - preview_max);
            put_str(overlay, y, content_x, more, dim, bg);
            y++;
        }

        y++; // blank line

        // Prompt input area
        put_str(overlay, y, content_x, "Your question:", fg, bg);
        y++;

        // Render prompt text (multi-line)
        const auto& prompt = agent_state.prompt();
        std::vector<std::string> plines;
        std::istringstream ps(prompt);
        std::string pl;
        while (std::getline(ps, pl)) plines.push_back(pl);
        if (prompt.empty() || (!prompt.empty() && prompt.back() == '\n'))
            plines.emplace_back();

        for (size_t i = 0; i < plines.size() && y < box_h - 2; i++) {
            put_str_trunc(overlay, y, content_x, plines[i].c_str(),
                          content_w, fg, bg);
            y++;
        }

        // Cursor
        int cursor_line = static_cast<int>(plines.size()) - 1;
        int cursor_y = y - 1;
        int cursor_x = content_x + static_cast<int>(plines[static_cast<size_t>(cursor_line)].size());
        if (cursor_x < content_x + content_w) {
            put_str(overlay, cursor_y, cursor_x, "▋", accent, bg);
        }

        // Hint
        put_str(overlay, box_h - 1, content_x,
                "Ctrl+Enter: send  Esc: cancel  Enter: newline",
                dim, bg);

    } else if (phase == state::AgentPhase::Running ||
               phase == state::AgentPhase::Ready) {
        // Show streaming response
        std::string resp = agent_state.response();

        std::vector<std::string> rlines;
        std::istringstream rs(resp);
        std::string rl;
        while (std::getline(rs, rl)) rlines.push_back(rl);
        if (rlines.empty()) rlines.emplace_back("Waiting for response...");

        int visible_h = box_h - 3; // room for title + hint
        int scroll = agent_state.response_scroll();

        // Auto-scroll to bottom while streaming
        if (phase == state::AgentPhase::Running &&
            static_cast<int>(rlines.size()) > visible_h) {
            scroll = static_cast<int>(rlines.size()) - visible_h;
        }

        for (int i = 0; i < visible_h; i++) {
            int line_idx = scroll + i;
            if (line_idx < static_cast<int>(rlines.size())) {
                put_str_trunc(overlay, 2 + i, content_x,
                              rlines[static_cast<size_t>(line_idx)].c_str(),
                              content_w, fg, bg);
            }
        }

        // Hint
        if (phase == state::AgentPhase::Ready) {
            put_str(overlay, box_h - 1, content_x,
                    "j/k: scroll  Esc: dismiss  Enter: follow up",
                    dim, bg);
        } else {
            put_str(overlay, box_h - 1, content_x,
                    "Streaming... j/k: scroll  Esc: dismiss",
                    dim, bg);
        }

    } else if (phase == state::AgentPhase::Error) {
        put_str(overlay, 2, content_x, "Error:",
                theme.error.to_channel(), bg);
        put_str_trunc(overlay, 3, content_x,
                      agent_state.error().c_str(), content_w,
                      theme.error.to_channel(), bg);
        put_str(overlay, box_h - 1, content_x,
                "Esc: dismiss", dim, bg);
    }
}

} // namespace blimp::ui

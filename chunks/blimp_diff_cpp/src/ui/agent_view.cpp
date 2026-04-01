#include "ui/agent_view.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "state/agent.h"

#include <algorithm>
#include <sstream>
#include <string>
#include <vector>

namespace blimp::ui {

void render_agent_view(struct ncplane* plane, const Theme& theme,
                       const state::AgentState& agent_state,
                       int y, int x, int h, int w) {
    uint32_t bg = theme.bg.to_channel();
    uint32_t fg = theme.fg.to_channel();
    uint32_t dim = theme.fg_dim.to_channel();
    uint32_t accent = theme.accent.to_channel();

    // Title bar
    hline(plane, y, x, w, 0, theme.status_bg.to_channel());
    const char* title = " Claude ";
    auto phase = agent_state.phase();
    if (phase == state::AgentPhase::Running) {
        title = " Claude (streaming...) ";
    } else if (phase == state::AgentPhase::Ready) {
        title = " Claude (ready -- Enter: follow up) ";
    } else if (phase == state::AgentPhase::Error) {
        title = " Claude (error) ";
    }
    put_str(plane, y, x + 1, title, accent, theme.status_bg.to_channel());

    // Tab hint on right
    const char* tab_hint = "Tab: back to diff";
    int hint_x = x + w - static_cast<int>(strlen(tab_hint)) - 2;
    if (hint_x > x + 30) {
        put_str(plane, y, hint_x, tab_hint, dim, theme.status_bg.to_channel());
    }

    int content_y = y + 1;
    int content_h = h - 1;
    int content_x = x + 1;
    int content_w = w - 2;

    if (phase == state::AgentPhase::Error) {
        put_str(plane, content_y, content_x, "Error:", theme.error.to_channel(), bg);
        put_str_trunc(plane, content_y + 1, content_x,
                      agent_state.error().c_str(), content_w,
                      theme.error.to_channel(), bg);
        return;
    }

    // Get response and split into lines
    std::string resp = agent_state.response();
    std::vector<std::string> lines;
    std::istringstream rs(resp);
    std::string line;
    while (std::getline(rs, line)) {
        // Wrap long lines
        if (static_cast<int>(line.size()) > content_w) {
            size_t pos = 0;
            while (pos < line.size()) {
                size_t chunk = std::min(static_cast<size_t>(content_w), line.size() - pos);
                lines.push_back(line.substr(pos, chunk));
                pos += chunk;
            }
        } else {
            lines.push_back(line);
        }
    }
    if (lines.empty()) {
        lines.emplace_back("Waiting for response...");
    }

    int total_lines = static_cast<int>(lines.size());
    int scroll = agent_state.response_scroll();

    // Auto-scroll to bottom while streaming
    if (phase == state::AgentPhase::Running && total_lines > content_h) {
        scroll = total_lines - content_h;
    }

    // Render visible lines
    for (int i = 0; i < content_h; i++) {
        int line_idx = scroll + i;
        int draw_y = content_y + i;

        if (line_idx >= total_lines) break;

        const auto& l = lines[static_cast<size_t>(line_idx)];

        // Simple markdown-ish coloring
        uint32_t line_fg = fg;
        if (!l.empty() && l[0] == '#') {
            line_fg = accent; // headers
        } else if (l.size() >= 3 && l.substr(0, 3) == "```") {
            line_fg = dim; // code fences
        } else if (!l.empty() && l[0] == '-') {
            line_fg = theme.diff_add_fg.to_channel(); // list items
        }

        put_str_trunc(plane, draw_y, content_x, l.c_str(),
                      content_w, line_fg, bg);
    }
}

} // namespace blimp::ui

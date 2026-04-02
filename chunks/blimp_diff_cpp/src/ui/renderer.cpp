#include "ui/renderer.h"
#include "ui/theme.h"
#include "ui/diff_cache.h"
#include "ui/file_list.h"
#include "ui/diff_pane.h"
#include "ui/log_view.h"
#include "ui/agent_view.h"
#include "state/agent.h"
#include "ui/status_bar.h"
#include "ui/overlays.h"
#include "types.h"
#include "state/navigation.h"
#include "state/interaction.h"
#include "state/commit.h"
#include "state/selection.h"

#include <notcurses/notcurses.h>
#include <cstring>
#include <algorithm>

// temp debug
extern void dlog(const char* msg);

namespace blimp::ui {

void cell_set(struct ncplane* plane, int y, int x, const char* gcluster,
              uint32_t fg_ch, uint32_t bg_ch) {
    nccell c = NCCELL_TRIVIAL_INITIALIZER;
    nccell_set_fg_rgb(&c, fg_ch);
    nccell_set_bg_rgb(&c, bg_ch);
    nccell_load(plane, &c, gcluster);
    ncplane_putc_yx(plane, y, x, &c);
    nccell_release(plane, &c);
}

void hline(struct ncplane* plane, int y, int x, int len,
           uint32_t fg_ch, uint32_t bg_ch) {
    if (len <= 0) return;
    // Use notcurses hline: one cell init + single call vs per-cell loop
    nccell c = NCCELL_TRIVIAL_INITIALIZER;
    nccell_set_fg_rgb(&c, fg_ch);
    nccell_set_bg_rgb(&c, bg_ch);
    nccell_load(plane, &c, " ");
    ncplane_cursor_move_yx(plane, y, x);
    ncplane_hline(plane, &c, static_cast<unsigned>(len));
    nccell_release(plane, &c);
}

void vline(struct ncplane* plane, int x, int y_start, int y_end,
           uint32_t fg_ch, uint32_t bg_ch) {
    int len = y_end - y_start + 1;
    if (len <= 0) return;
    nccell c = NCCELL_TRIVIAL_INITIALIZER;
    nccell_set_fg_rgb(&c, fg_ch);
    nccell_set_bg_rgb(&c, bg_ch);
    nccell_load(plane, &c, "│");
    ncplane_cursor_move_yx(plane, y_start, x);
    ncplane_vline(plane, &c, static_cast<unsigned>(len));
    nccell_release(plane, &c);
}

void fill_rect(struct ncplane* plane, int y, int x, int h, int w,
               uint32_t bg_ch) {
    if (h <= 0 || w <= 0) return;
    // Use hline per row -- still O(rows) calls but each row is a single
    // notcurses hline instead of O(cols) cell_set calls
    nccell c = NCCELL_TRIVIAL_INITIALIZER;
    nccell_set_bg_rgb(&c, bg_ch);
    nccell_load(plane, &c, " ");
    for (int row = y; row < y + h; row++) {
        ncplane_cursor_move_yx(plane, row, x);
        ncplane_hline(plane, &c, static_cast<unsigned>(w));
    }
    nccell_release(plane, &c);
}

void put_str(struct ncplane* plane, int y, int x, const char* str,
             uint32_t fg_ch, uint32_t bg_ch) {
    ncplane_set_fg_rgb(plane, fg_ch);
    ncplane_set_bg_rgb(plane, bg_ch);
    ncplane_putstr_yx(plane, y, x, str);
}

void put_str_trunc(struct ncplane* plane, int y, int x, const char* str,
                   int max_width, uint32_t fg_ch, uint32_t bg_ch) {
    int len = static_cast<int>(strlen(str));
    if (len <= max_width) {
        put_str(plane, y, x, str, fg_ch, bg_ch);
    } else if (max_width > 3) {
        std::string truncated(str, str + max_width - 3);
        truncated += "...";
        put_str(plane, y, x, truncated.c_str(), fg_ch, bg_ch);
    }
}

void render(struct ncplane* std_plane,
            struct ncplane* overlay_plane,
            bool full_redraw,
            const Theme& theme,
            const RepoState& repo,
            state::Navigation& nav,
            const state::Interaction& interaction,
            const state::CommitState& commit_state,
            const state::LineSelection& selection,
            const DiffCache& diff_cache,
            const std::vector<LogEntry>& log_entries,
            const state::AgentState& agent_state,
            const std::string& flash_message) {
    unsigned rows = 0, cols = 0;
    ncplane_dim_yx(std_plane, &rows, &cols);

    if (rows < 3 || cols < 20) return;

    int total_h = static_cast<int>(rows);
    int total_w = static_cast<int>(cols);
    int status_h = 1;
    int main_h = total_h - status_h;

    // Only erase on mode transitions or resize -- not every frame.
    // Each pane overwrites its own rows, so normal frames need no erase.
    // This lets notcurses damage tracking skip unchanged cells.
    if (full_redraw) {
        ncplane_set_bg_rgb(std_plane, theme.bg.to_channel());
        ncplane_erase(std_plane);
    }

    auto mode = interaction.mode();

    int divider_x = static_cast<int>(static_cast<float>(total_w) * nav.divider_pos());
    divider_x = std::clamp(divider_x, 10, total_w - 10);

    int file_list_w = divider_x;
    int diff_w = total_w - divider_x - 1;

    dlog("render: mode dispatch");
    if (mode == state::Mode::AgentView) {
        render_agent_view(std_plane, theme, agent_state, 0, 0, main_h, total_w);
    } else if (mode == state::Mode::LogList || mode == state::Mode::LogDetail) {
        render_log_view(std_plane, theme, log_entries, nav, 0, 0, main_h, total_w);
    } else {
        bool file_focused = (nav.active_pane() == state::Pane::FileList);
        dlog("render: file_list start");
        render_file_list(std_plane, theme, repo, nav,
                         0, 0, main_h, file_list_w, file_focused);
        dlog("render: file_list done");

        uint32_t div_fg = file_focused
            ? theme.border_active.to_channel()
            : theme.border_inactive.to_channel();
        vline(std_plane, divider_x, 0, main_h - 1, div_fg, theme.bg.to_channel());

        bool diff_focused = (nav.active_pane() == state::Pane::Diff);
        dlog("render: diff_pane start");
        render_diff_pane(std_plane, theme, diff_cache, nav, selection,
                         0, divider_x + 1, main_h, diff_w, diff_focused);
        dlog("render: diff_pane done");
    }

    dlog("render: status_bar");
    render_status_bar(std_plane, theme, repo, nav, interaction,
                      main_h, 0, status_h, total_w, "");

    // Flash message at top of diff pane
    if (!flash_message.empty() && mode != state::Mode::AgentView &&
        mode != state::Mode::LogList && mode != state::Mode::LogDetail) {
        int flash_x = divider_x + 2;
        int flash_w = diff_w - 2;
        if (flash_w > 0) {
            hline(std_plane, 0, divider_x + 1, diff_w, 0, theme.accent.to_channel());
            put_str_trunc(std_plane, 0, flash_x, flash_message.c_str(),
                          flash_w, theme.bg.to_channel(), theme.accent.to_channel());
        }
    }

    if (mode == state::Mode::Committing && overlay_plane) {
        render_commit_overlay(overlay_plane, theme, commit_state,
                              interaction.commit_mode());
    }
    if (mode == state::Mode::AgentPrompt && overlay_plane) {
        render_agent_overlay(overlay_plane, theme, agent_state);
    }
}

} // namespace blimp::ui

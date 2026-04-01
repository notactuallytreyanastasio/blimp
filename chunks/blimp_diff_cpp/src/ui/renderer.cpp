#include "ui/renderer.h"
#include "ui/theme.h"
#include "ui/file_list.h"
#include "ui/diff_pane.h"
#include "ui/log_view.h"
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
    for (int i = 0; i < len; i++) {
        cell_set(plane, y, x + i, " ", fg_ch, bg_ch);
    }
}

void vline(struct ncplane* plane, int x, int y_start, int y_end,
           uint32_t fg_ch, uint32_t bg_ch) {
    for (int y = y_start; y <= y_end; y++) {
        cell_set(plane, y, x, "│", fg_ch, bg_ch);
    }
}

void fill_rect(struct ncplane* plane, int y, int x, int h, int w,
               uint32_t bg_ch) {
    for (int row = y; row < y + h; row++) {
        for (int col = x; col < x + w; col++) {
            cell_set(plane, row, col, " ", 0, bg_ch);
        }
    }
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
            const Theme& theme,
            const RepoState& repo,
            const state::Navigation& nav,
            const state::Interaction& interaction,
            const state::CommitState& commit_state,
            const state::LineSelection& selection,
            const std::string& status_message) {
    unsigned rows = 0, cols = 0;
    ncplane_dim_yx(std_plane, &rows, &cols);

    if (rows < 3 || cols < 20) return;

    int total_h = static_cast<int>(rows);
    int total_w = static_cast<int>(cols);
    int status_h = 1;
    int main_h = total_h - status_h;

    // Clear background
    fill_rect(std_plane, 0, 0, total_h, total_w, theme.bg.to_channel());

    auto mode = interaction.mode();

    // Layout: file list on left, diff on right, status bar at bottom
    int divider_x = static_cast<int>(static_cast<float>(total_w) * nav.divider_pos());
    divider_x = std::clamp(divider_x, 10, total_w - 10);

    int file_list_w = divider_x;
    int diff_w = total_w - divider_x - 1; // -1 for divider

    if (mode == state::Mode::LogList || mode == state::Mode::LogDetail) {
        render_log_view(std_plane, theme, repo, nav, 0, 0, main_h, total_w);
    } else {
        // File list pane
        bool file_focused = (nav.active_pane() == state::Pane::FileList);
        render_file_list(std_plane, theme, repo, nav,
                         0, 0, main_h, file_list_w, file_focused);

        // Divider
        uint32_t div_fg = file_focused
            ? theme.border_active.to_channel()
            : theme.border_inactive.to_channel();
        vline(std_plane, divider_x, 0, main_h - 1, div_fg, theme.bg.to_channel());

        // Diff pane
        bool diff_focused = (nav.active_pane() == state::Pane::Diff);
        render_diff_pane(std_plane, theme, repo, nav, selection,
                         0, divider_x + 1, main_h, diff_w, diff_focused);
    }

    // Status bar
    render_status_bar(std_plane, theme, repo, nav, interaction,
                      main_h, 0, status_h, total_w, status_message);

    // Overlays
    if (mode == state::Mode::Committing) {
        render_commit_overlay(std_plane, theme, commit_state,
                              interaction.commit_mode(),
                              total_h, total_w);
    }
}

} // namespace blimp::ui

#include "ui/status_bar.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "types.h"
#include "state/navigation.h"
#include "state/interaction.h"

#include <cstdio>

namespace blimp::ui {

void render_status_bar(struct ncplane* plane, const Theme& theme,
                       const RepoState& repo, const state::Navigation& nav,
                       const state::Interaction& interaction,
                       int y, int x, int /*h*/, int w,
                       const std::string& status_message) {
    uint32_t bg = theme.status_bg.to_channel();
    uint32_t fg = theme.status_fg.to_channel();

    // Clear status bar
    hline(plane, y, x, w, 0, bg);

    int col = x + 1;

    // Branch name (bold-ish via accent color)
    if (!repo.branch.empty()) {
        put_str(plane, y, col, repo.branch.c_str(), theme.accent.to_channel(), bg);
        col += static_cast<int>(repo.branch.size()) + 1;
    }

    // File count
    char buf[64];
    snprintf(buf, sizeof(buf), "%zu files", repo.files.size());
    put_str(plane, y, col, buf, fg, bg);
    col += static_cast<int>(strlen(buf)) + 1;

    // Follow mode
    if (nav.follow_mode()) {
        put_str(plane, y, col, "[FOLLOW]", theme.fg_bright.to_channel(), bg);
    } else {
        put_str(plane, y, col, "[follow]", theme.fg_dim.to_channel(), bg);
    }
    col += 9;

    // Theme name
    // (theme name is in the theme itself)

    // Key hints on the right
    const char* hints = nullptr;
    switch (interaction.mode()) {
        case state::Mode::FileList:
            hints = "j/k:nav s:stage u:unstage x:discard S:stash cc:commit g:agent q:quit";
            break;
        case state::Mode::DiffView:
            hints = "j/k:hunk h/l:scroll v:select g:agent Tab:pane q:back";
            break;
        case state::Mode::Selecting:
            hints = "j/k:extend Enter:ask Claude Esc:cancel";
            break;
        case state::Mode::LogList:
            hints = "j/k:nav Enter:detail q:back";
            break;
        case state::Mode::AgentView:
            hints = "j/k:scroll Tab:back to diff Esc:dismiss";
            break;
        default:
            hints = "Esc:cancel";
            break;
    }

    if (hints) {
        int hints_len = static_cast<int>(strlen(hints));
        int hints_x = x + w - hints_len - 1;
        if (hints_x > col + 2) {
            put_str(plane, y, hints_x, hints, theme.fg_dim.to_channel(), bg);
        }
    }

    // Status message (errors in red)
    if (!status_message.empty()) {
        int msg_x = col + 2;
        int max_w = w - msg_x - 40; // leave room for hints
        if (max_w > 0) {
            put_str_trunc(plane, y, msg_x, status_message.c_str(), max_w,
                          theme.error.to_channel(), bg);
        }
    }
}

} // namespace blimp::ui

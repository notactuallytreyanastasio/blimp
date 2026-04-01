#include "ui/log_view.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "types.h"
#include "state/navigation.h"

namespace blimp::ui {

void render_log_view(struct ncplane* plane, const Theme& theme,
                     const RepoState& /*repo*/, const state::Navigation& nav,
                     int y, int x, int h, int w) {
    uint32_t bg = theme.bg.to_channel();

    put_str(plane, y, x + 1, " Log ", theme.accent.to_channel(), bg);

    // Log entries would be stored in a separate log state;
    // for now render a placeholder.
    // The actual log data will be populated when log_oneline is called.
    for (int row = 1; row < h; row++) {
        hline(plane, y + row, x, w, 0, bg);
    }

    put_str(plane, y + 1, x + 1, "Press 'l' in file list to load log",
            theme.fg_dim.to_channel(), bg);
}

} // namespace blimp::ui

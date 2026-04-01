#pragma once
#include <notcurses/notcurses.h>
#include "types.h"
#include <vector>

namespace blimp::state {
class Navigation;
}

namespace blimp::ui {

struct Theme;

void render_log_view(struct ncplane* plane, const Theme& theme,
                     const std::vector<LogEntry>& entries,
                     const state::Navigation& nav,
                     int y, int x, int h, int w);

} // namespace blimp::ui

#pragma once
#include <notcurses/notcurses.h>

namespace blimp::state {
class Navigation;
class LineSelection;
}

namespace blimp::ui {

struct Theme;
class DiffCache;

void render_diff_pane(struct ncplane* plane, const Theme& theme,
                      const DiffCache& cache, const state::Navigation& nav,
                      const state::LineSelection& selection,
                      int y, int x, int h, int w, bool focused);

} // namespace blimp::ui

#pragma once
#include <notcurses/notcurses.h>

namespace blimp {
struct RepoState;
}
namespace blimp::state {
class Navigation;
class LineSelection;
}

namespace blimp::ui {

struct Theme;

void render_diff_pane(struct ncplane* plane, const Theme& theme,
                      const RepoState& repo, const state::Navigation& nav,
                      const state::LineSelection& selection,
                      int y, int x, int h, int w, bool focused);

} // namespace blimp::ui

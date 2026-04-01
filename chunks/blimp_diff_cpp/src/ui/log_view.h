#pragma once
#include <notcurses/notcurses.h>

namespace blimp {
struct RepoState;
}
namespace blimp::state {
class Navigation;
}

namespace blimp::ui {

struct Theme;

void render_log_view(struct ncplane* plane, const Theme& theme,
                     const RepoState& repo, const state::Navigation& nav,
                     int y, int x, int h, int w);

} // namespace blimp::ui

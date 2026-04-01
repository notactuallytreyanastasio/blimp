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

void render_file_list(struct ncplane* plane, const Theme& theme,
                      const RepoState& repo, const state::Navigation& nav,
                      int y, int x, int h, int w, bool focused);

} // namespace blimp::ui

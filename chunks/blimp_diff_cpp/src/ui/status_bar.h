#pragma once
#include <notcurses/notcurses.h>
#include <string>

namespace blimp {
struct RepoState;
}
namespace blimp::state {
class Navigation;
class Interaction;
}

namespace blimp::ui {

struct Theme;

void render_status_bar(struct ncplane* plane, const Theme& theme,
                       const RepoState& repo, const state::Navigation& nav,
                       const state::Interaction& interaction,
                       int y, int x, int h, int w,
                       const std::string& status_message);

} // namespace blimp::ui

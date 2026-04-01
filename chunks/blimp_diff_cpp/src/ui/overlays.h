#pragma once
#include <notcurses/notcurses.h>
#include "state/interaction.h"

namespace blimp::state {
class CommitState;
}

namespace blimp::ui {

struct Theme;

void render_commit_overlay(struct ncplane* plane, const Theme& theme,
                           const state::CommitState& commit_state,
                           state::CommitMode mode,
                           int total_h, int total_w);

} // namespace blimp::ui

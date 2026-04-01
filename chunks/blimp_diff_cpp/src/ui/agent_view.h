#pragma once
#include <notcurses/notcurses.h>

namespace blimp::state {
class AgentState;
}

namespace blimp::ui {

struct Theme;

// Render the agent conversation as a full-screen view (like log view)
void render_agent_view(struct ncplane* plane, const Theme& theme,
                       const state::AgentState& agent_state,
                       int y, int x, int h, int w);

} // namespace blimp::ui

#pragma once
#include <notcurses/notcurses.h>
#include "state/interaction.h"

namespace blimp::state {
class CommitState;
class AgentState;
}

namespace blimp::ui {

struct Theme;

// Create/resize the overlay plane as a child of std_plane.
// Returns the overlay plane (caller owns it).
struct ncplane* create_overlay_plane(struct ncplane* std_plane,
                                     int total_h, int total_w);

// Render the commit dialog into the overlay plane.
// The plane is erased and fully redrawn each call.
void render_commit_overlay(struct ncplane* overlay, const Theme& theme,
                           const state::CommitState& commit_state,
                           state::CommitMode mode);

// Create the agent overlay plane (wider than commit -- 80% x 70%)
struct ncplane* create_agent_plane(struct ncplane* std_plane,
                                    int total_h, int total_w);

// Render the agent prompt/response into its overlay plane
void render_agent_overlay(struct ncplane* overlay, const Theme& theme,
                          const state::AgentState& agent_state);

} // namespace blimp::ui

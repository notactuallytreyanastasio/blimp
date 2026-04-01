#pragma once

#include <notcurses/notcurses.h>
#include <string>

namespace blimp {
struct RepoState;
}

namespace blimp::state {
class Navigation;
class Interaction;
class CommitState;
class LineSelection;
}

namespace blimp::ui {

struct Theme;

// Fills a cell with fg/bg channels
void cell_set(struct ncplane* plane, int y, int x, const char* gcluster,
              uint32_t fg_channel, uint32_t bg_channel);

// Draw a horizontal line
void hline(struct ncplane* plane, int y, int x, int len,
           uint32_t fg_channel, uint32_t bg_channel);

// Draw a vertical line
void vline(struct ncplane* plane, int x, int y_start, int y_end,
           uint32_t fg_channel, uint32_t bg_channel);

// Fill a rect with bg color
void fill_rect(struct ncplane* plane, int y, int x, int h, int w,
               uint32_t bg_channel);

// Write a string at position with colors
void put_str(struct ncplane* plane, int y, int x, const char* str,
             uint32_t fg_channel, uint32_t bg_channel);

// Write a string, truncating to max_width
void put_str_trunc(struct ncplane* plane, int y, int x, const char* str,
                   int max_width, uint32_t fg_channel, uint32_t bg_channel);

// Render the full application frame
void render(struct ncplane* std_plane,
            const Theme& theme,
            const RepoState& repo,
            const state::Navigation& nav,
            const state::Interaction& interaction,
            const state::CommitState& commit_state,
            const state::LineSelection& selection,
            const std::string& status_message);

} // namespace blimp::ui

#pragma once
#include "types.h"
#include <array>
#include <cstdint>
#include <string_view>

namespace blimp::ui {

struct Theme {
    std::string_view name;

    RGB bg;
    RGB bg_selected;
    RGB bg_hover;
    RGB fg;
    RGB fg_dim;
    RGB fg_bright;
    RGB accent;

    // Diff colors
    RGB diff_add_bg;
    RGB diff_add_fg;
    RGB diff_del_bg;
    RGB diff_del_fg;
    RGB diff_hunk_header;
    RGB diff_context_fg;

    // Gutter
    RGB gutter_bg;
    RGB gutter_fg;

    // Status bar
    RGB status_bg;
    RGB status_fg;

    // Borders
    RGB border_active;
    RGB border_inactive;

    // Follow mode hot highlight
    RGB hot_highlight_bg;

    // Error
    RGB error;

    // Selection
    RGB selection_bg;

    // Staged badge
    RGB staged_badge;
};

// Built-in themes
inline constexpr Theme solarized_dark{
    .name = "Solarized Dark",
    .bg            = {0, 43, 54},
    .bg_selected   = {7, 54, 66},
    .bg_hover      = {7, 54, 66},
    .fg            = {131, 148, 150},
    .fg_dim        = {88, 110, 117},
    .fg_bright     = {238, 232, 213},
    .accent        = {38, 139, 210},
    .diff_add_bg   = {0, 54, 36},
    .diff_add_fg   = {133, 153, 0},
    .diff_del_bg   = {54, 18, 18},
    .diff_del_fg   = {220, 50, 47},
    .diff_hunk_header = {108, 113, 196},
    .diff_context_fg  = {101, 123, 131},
    .gutter_bg     = {0, 36, 46},
    .gutter_fg     = {88, 110, 117},
    .status_bg     = {7, 54, 66},
    .status_fg     = {147, 161, 161},
    .border_active = {38, 139, 210},
    .border_inactive = {88, 110, 117},
    .hot_highlight_bg = {42, 161, 152},
    .error         = {220, 50, 47},
    .selection_bg  = {7, 54, 66},
    .staged_badge  = {133, 153, 0},
};

inline constexpr Theme solarized_light{
    .name = "Solarized Light",
    .bg            = {253, 246, 227},
    .bg_selected   = {238, 232, 213},
    .bg_hover      = {238, 232, 213},
    .fg            = {101, 123, 131},
    .fg_dim        = {147, 161, 161},
    .fg_bright     = {7, 54, 66},
    .accent        = {38, 139, 210},
    .diff_add_bg   = {220, 240, 220},
    .diff_add_fg   = {0, 100, 0},
    .diff_del_bg   = {255, 220, 220},
    .diff_del_fg   = {180, 0, 0},
    .diff_hunk_header = {108, 113, 196},
    .diff_context_fg  = {88, 110, 117},
    .gutter_bg     = {238, 232, 213},
    .gutter_fg     = {147, 161, 161},
    .status_bg     = {238, 232, 213},
    .status_fg     = {88, 110, 117},
    .border_active = {38, 139, 210},
    .border_inactive = {147, 161, 161},
    .hot_highlight_bg = {42, 161, 152},
    .error         = {220, 50, 47},
    .selection_bg  = {238, 232, 213},
    .staged_badge  = {133, 153, 0},
};

inline constexpr Theme monokai_dark{
    .name = "Monokai Dark",
    .bg            = {39, 40, 34},
    .bg_selected   = {62, 61, 50},
    .bg_hover      = {62, 61, 50},
    .fg            = {248, 248, 242},
    .fg_dim        = {117, 113, 94},
    .fg_bright     = {255, 255, 255},
    .accent        = {102, 217, 239},
    .diff_add_bg   = {30, 60, 30},
    .diff_add_fg   = {166, 226, 46},
    .diff_del_bg   = {60, 20, 20},
    .diff_del_fg   = {249, 38, 114},
    .diff_hunk_header = {174, 129, 255},
    .diff_context_fg  = {117, 113, 94},
    .gutter_bg     = {30, 31, 26},
    .gutter_fg     = {90, 90, 80},
    .status_bg     = {62, 61, 50},
    .status_fg     = {248, 248, 242},
    .border_active = {102, 217, 239},
    .border_inactive = {117, 113, 94},
    .hot_highlight_bg = {253, 151, 31},
    .error         = {249, 38, 114},
    .selection_bg  = {73, 72, 62},
    .staged_badge  = {166, 226, 46},
};

inline constexpr Theme monokai_light{
    .name = "Monokai Light",
    .bg            = {251, 251, 249},
    .bg_selected   = {231, 231, 225},
    .bg_hover      = {231, 231, 225},
    .fg            = {55, 55, 55},
    .fg_dim        = {150, 150, 140},
    .fg_bright     = {0, 0, 0},
    .accent        = {0, 150, 200},
    .diff_add_bg   = {220, 255, 220},
    .diff_add_fg   = {0, 120, 0},
    .diff_del_bg   = {255, 220, 220},
    .diff_del_fg   = {200, 0, 50},
    .diff_hunk_header = {120, 80, 200},
    .diff_context_fg  = {120, 120, 110},
    .gutter_bg     = {241, 241, 236},
    .gutter_fg     = {180, 180, 170},
    .status_bg     = {231, 231, 225},
    .status_fg     = {55, 55, 55},
    .border_active = {0, 150, 200},
    .border_inactive = {180, 180, 170},
    .hot_highlight_bg = {255, 180, 50},
    .error         = {200, 0, 50},
    .selection_bg  = {210, 230, 255},
    .staged_badge  = {0, 120, 0},
};

inline constexpr std::array<const Theme*, 4> all_themes = {
    &solarized_dark, &solarized_light, &monokai_dark, &monokai_light
};

class ThemeCycler {
public:
    [[nodiscard]] const Theme& current() const { return *all_themes[index_]; }
    void next() { index_ = (index_ + 1) % all_themes.size(); }

private:
    size_t index_ = 0;
};

} // namespace blimp::ui

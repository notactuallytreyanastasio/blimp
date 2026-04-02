#include "ui/diff_pane.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "ui/diff_cache.h"
#include "ui/highlight.h"
#include "state/navigation.h"
#include "state/selection.h"

#include <algorithm>
#include <cstdio>
#include <string>

namespace blimp::ui {

void render_diff_pane(struct ncplane* plane, const Theme& theme,
                      const DiffCache& cache, const state::Navigation& nav,
                      const state::LineSelection& selection,
                      int y, int x, int h, int w, bool focused) {
    if (w < 10 || h < 1) return;

    uint32_t bg = theme.bg.to_channel();

    if (cache.line_count() == 0) {
        put_str(plane, y, x + 1, "No diff available", theme.fg_dim.to_channel(), bg);
        return;
    }

    const auto& lines = cache.lines();
    int total_lines = cache.line_count();
    Lang lang = cache.lang();
    auto colors = colors_for_theme(theme);

    const int gutter_w = 12;
    int content_w = w - gutter_w;
    if (content_w < 1) content_w = 1;

    int scroll = nav.diff_scroll();
    int h_scroll = nav.diff_h_scroll();

    for (int row = 0; row < h; row++) {
        int line_idx = scroll + row;
        int draw_y = y + row;

        if (line_idx >= total_lines) {
            hline(plane, draw_y, x, w, 0, bg);
            continue;
        }

        const auto& cl = lines[static_cast<size_t>(line_idx)];

        // Section header (Staged / Unstaged separator)
        if (cl.type == CachedLine::SectionHeader) {
            hline(plane, draw_y, x, w, 0, theme.status_bg.to_channel());
            put_str(plane, draw_y, x + 1, cl.text.c_str(),
                    theme.accent.to_channel(), theme.status_bg.to_channel());
            continue;
        }

        // Hunk header
        if (cl.type == CachedLine::HunkHeader) {
            hline(plane, draw_y, x, gutter_w, 0, theme.gutter_bg.to_channel());
            put_str(plane, draw_y, x, "@@",
                    theme.diff_hunk_header.to_channel(), theme.gutter_bg.to_channel());
            hline(plane, draw_y, x + gutter_w, content_w, 0, bg);
            put_str_trunc(plane, draw_y, x + gutter_w, cl.text.c_str(),
                          content_w, theme.diff_hunk_header.to_channel(), bg);
            continue;
        }

        // Line background
        uint32_t line_bg = bg;
        char prefix = ' ';

        switch (cl.kind) {
            case LineKind::Addition:
                line_bg = theme.diff_add_bg.to_channel();
                prefix = '+';
                break;
            case LineKind::Deletion:
                line_bg = theme.diff_del_bg.to_channel();
                prefix = '-';
                break;
            case LineKind::Context:
                break;
        }

        if (selection.contains(static_cast<size_t>(line_idx))) {
            line_bg = theme.selection_bg.to_channel();
        }

        // Fill entire row first (prevents black gaps from stale cells)
        hline(plane, draw_y, x, w, 0, line_bg);

        // Gutter
        char gutter_buf[14];
        char old_str[6] = "     ";
        char new_str[6] = "     ";
        if (cl.old_line >= 0) snprintf(old_str, sizeof(old_str), "%4d ", cl.old_line);
        if (cl.new_line >= 0) snprintf(new_str, sizeof(new_str), "%4d ", cl.new_line);
        snprintf(gutter_buf, sizeof(gutter_buf), "%s%s%c", old_str, new_str, prefix);
        put_str(plane, draw_y, x, gutter_buf,
                theme.gutter_fg.to_channel(), theme.gutter_bg.to_channel());

        // Highlight this single line on the fly (only visible lines get tokenized)
        auto spans = highlight_line(cl.text, lang, colors);

        // Render spans with horizontal scroll
        int col = x + gutter_w;
        int chars_skipped = 0;
        int chars_drawn = 0;

        for (const auto& span : spans) {
            if (chars_drawn >= content_w) break;

            size_t start = 0;
            if (chars_skipped < h_scroll) {
                size_t to_skip = std::min(span.text.size(),
                    static_cast<size_t>(h_scroll - chars_skipped));
                chars_skipped += static_cast<int>(to_skip);
                start = to_skip;
            }
            if (start >= span.text.size()) continue;

            int remaining = content_w - chars_drawn;
            size_t len = std::min(span.text.size() - start,
                                   static_cast<size_t>(remaining));

            ncplane_set_fg_rgb(plane, span.fg);
            ncplane_set_bg_rgb(plane, line_bg);
            ncplane_putstr_yx(plane, draw_y, col + chars_drawn,
                              span.text.substr(start, len).c_str());
            chars_drawn += static_cast<int>(len);
        }
    }
}

} // namespace blimp::ui

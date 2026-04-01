#include "ui/diff_pane.h"
#include "ui/renderer.h"
#include "ui/theme.h"
#include "types.h"
#include "state/navigation.h"
#include "state/selection.h"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

namespace blimp::ui {

namespace {

// Flatten all hunks into a list of renderable lines with metadata
struct RenderLine {
    enum Type { HunkHeader, DiffContent, Empty };
    Type type = Empty;
    LineKind kind = LineKind::Context;
    std::string text;
    int old_line = -1;
    int new_line = -1;
};

std::vector<RenderLine> flatten_diff(const FileDiff& diff) {
    std::vector<RenderLine> lines;
    for (const auto& hunk : diff.hunks) {
        RenderLine rl;
        rl.type = RenderLine::HunkHeader;
        rl.text = hunk.header;
        lines.push_back(rl);

        for (const auto& dl : hunk.lines) {
            RenderLine rl2;
            rl2.type = RenderLine::DiffContent;
            rl2.kind = dl.kind;
            rl2.text = dl.content;
            rl2.old_line = dl.old_line.value_or(-1);
            rl2.new_line = dl.new_line.value_or(-1);
            lines.push_back(rl2);
        }
    }
    return lines;
}

} // namespace

void render_diff_pane(struct ncplane* plane, const Theme& theme,
                      const RepoState& repo, const state::Navigation& nav,
                      const state::LineSelection& selection,
                      int y, int x, int h, int w, bool focused) {
    if (w < 10 || h < 1) return;

    uint32_t bg = theme.bg.to_channel();

    // Find diff for selected file
    if (repo.files.empty()) {
        put_str(plane, y, x + 1, "No files", theme.fg_dim.to_channel(), bg);
        return;
    }

    size_t fi = nav.file_index();
    if (fi >= repo.files.size()) return;

    const auto& file = repo.files[fi];
    auto it = repo.diffs.find(file.path);

    if (it == repo.diffs.end()) {
        put_str(plane, y, x + 1, "No diff available", theme.fg_dim.to_channel(), bg);
        return;
    }

    const auto& diff = it->second;

    if (diff.binary) {
        put_str(plane, y, x + 1, "Binary file", theme.fg_dim.to_channel(), bg);
        return;
    }

    auto lines = flatten_diff(diff);
    int total_lines = static_cast<int>(lines.size());

    // Gutter width: 4 + 4 + 1 (old_line, new_line, prefix)
    const int gutter_w = 13;
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

        const auto& rl = lines[static_cast<size_t>(line_idx)];

        uint32_t line_bg = bg;
        uint32_t line_fg = theme.fg.to_channel();
        char prefix = ' ';

        if (rl.type == RenderLine::HunkHeader) {
            line_fg = theme.diff_hunk_header.to_channel();
            // Fill gutter
            hline(plane, draw_y, x, gutter_w, 0, theme.gutter_bg.to_channel());
            put_str(plane, draw_y, x, "@@", theme.diff_hunk_header.to_channel(),
                    theme.gutter_bg.to_channel());
            // Content
            hline(plane, draw_y, x + gutter_w, content_w, 0, bg);
            put_str_trunc(plane, draw_y, x + gutter_w, rl.text.c_str(),
                          content_w, line_fg, bg);
            continue;
        }

        // Diff line
        switch (rl.kind) {
            case LineKind::Addition:
                line_bg = theme.diff_add_bg.to_channel();
                line_fg = theme.diff_add_fg.to_channel();
                prefix = '+';
                break;
            case LineKind::Deletion:
                line_bg = theme.diff_del_bg.to_channel();
                line_fg = theme.diff_del_fg.to_channel();
                prefix = '-';
                break;
            case LineKind::Context:
                line_fg = theme.diff_context_fg.to_channel();
                break;
        }

        // Selection highlight
        if (selection.contains(static_cast<size_t>(line_idx))) {
            line_bg = theme.selection_bg.to_channel();
        }

        // Gutter: old_line new_line prefix
        char gutter_buf[16];
        char old_str[6] = "     ";
        char new_str[6] = "     ";

        if (rl.old_line >= 0) snprintf(old_str, sizeof(old_str), "%4d ", rl.old_line);
        if (rl.new_line >= 0) snprintf(new_str, sizeof(new_str), "%4d ", rl.new_line);

        snprintf(gutter_buf, sizeof(gutter_buf), "%s%s%c ", old_str, new_str, prefix);

        put_str(plane, draw_y, x, gutter_buf,
                theme.gutter_fg.to_channel(), theme.gutter_bg.to_channel());

        // Content with horizontal scroll
        hline(plane, draw_y, x + gutter_w, content_w, 0, line_bg);

        if (h_scroll < static_cast<int>(rl.text.size())) {
            std::string visible = rl.text.substr(static_cast<size_t>(h_scroll));
            put_str_trunc(plane, draw_y, x + gutter_w, visible.c_str(),
                          content_w, line_fg, line_bg);
        }
    }
}

} // namespace blimp::ui

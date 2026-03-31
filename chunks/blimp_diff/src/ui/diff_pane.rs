use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState};

use crate::app::App;
use crate::state::navigation::Focus;
use crate::types::LineKind;
use crate::ui::highlight::Highlighter;

pub fn render(frame: &mut Frame, app: &App, area: Rect) {
    let t = &app.theme;
    let focused = app.nav.focus == Focus::DiffView;
    let border_color = if focused { t.border_focused } else { t.border };

    let diff = match &app.selected_diff {
        Some(d) => d,
        None => {
            let block = Block::default()
                .title(" diff ")
                .borders(Borders::ALL)
                .border_style(Style::default().fg(border_color))
                .style(Style::default().bg(t.bg));
            let msg = Paragraph::new("No file selected")
                .block(block)
                .style(Style::default().fg(t.fg_dim));
            frame.render_widget(msg, area);
            return;
        }
    };

    let title = format!(" {} ", diff.path);
    let block = Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_style(Style::default().fg(border_color))
        .style(Style::default().bg(t.bg));

    if diff.binary {
        let msg = Paragraph::new("Binary file")
            .block(block)
            .style(Style::default().fg(t.fg_dim));
        frame.render_widget(msg, area);
        return;
    }

    let mut lines: Vec<Line> = vec![];

    for (hunk_idx, hunk) in diff.hunks.iter().enumerate() {
        let is_selected = hunk_idx == app.nav.hunk_index && focused;
        let is_hot = hunk.highlighted_at.is_some();

        // Hunk header
        let header_bg = if is_selected {
            t.diff_hunk_selected_bg
        } else if is_hot {
            t.diff_hot_bg
        } else {
            t.diff_hunk_header_bg
        };

        lines.push(Line::styled(
            hunk.header.clone(),
            Style::default().fg(t.diff_hunk_header_fg).bg(header_bg),
        ));

        // Diff lines with syntax highlighting + tinted backgrounds
        let ext = Highlighter::extension_from_path(&diff.path);

        for diff_line in &hunk.lines {
            let (prefix, _fg, bg) = match diff_line.kind {
                LineKind::Addition => ("+", t.diff_add_fg, t.diff_add_bg),
                LineKind::Deletion => ("-", t.diff_del_fg, t.diff_del_bg),
                LineKind::Context => (" ", t.diff_context_fg, t.bg),
            };

            let old_num = diff_line
                .old_line
                .map(|n| format!("{:>4}", n))
                .unwrap_or_else(|| "    ".to_string());
            let new_num = diff_line
                .new_line
                .map(|n| format!("{:>4}", n))
                .unwrap_or_else(|| "    ".to_string());

            // Selection override
            let line_bg = if app.selection.active
                && app.selection.file.as_deref() == Some(&diff.path)
                && app.selection.contains(
                    diff_line.new_line.or(diff_line.old_line).unwrap_or(0),
                )
            {
                t.selection_bg
            } else {
                bg
            };

            // Build spans: gutter + prefix + syntax-highlighted content
            let mut spans = vec![
                Span::styled(
                    format!("{} {} ", old_num, new_num),
                    Style::default().fg(t.fg_dim).bg(t.bg_gutter),
                ),
                Span::styled(
                    prefix.to_string(),
                    Style::default().fg(t.fg_dim).bg(line_bg),
                ),
            ];

            // Syntax highlight the code content
            let syntax_spans =
                app.highlighter.highlight_line(&diff_line.content, ext, line_bg);
            spans.extend(syntax_spans);

            lines.push(Line::from(spans));
        }

        // Blank line between hunks
        if hunk_idx < diff.hunks.len() - 1 {
            lines.push(Line::styled("", Style::default().bg(t.bg)));
        }
    }

    let total_lines = lines.len();
    let paragraph = Paragraph::new(lines)
        .block(block)
        .scroll((app.diff_scroll as u16, 0));

    frame.render_widget(paragraph, area);

    // Scrollbar
    if total_lines > area.height as usize {
        let mut scrollbar_state =
            ScrollbarState::new(total_lines).position(app.diff_scroll);
        let scrollbar = Scrollbar::new(ScrollbarOrientation::VerticalRight);
        frame.render_stateful_widget(scrollbar, area, &mut scrollbar_state);
    }
}

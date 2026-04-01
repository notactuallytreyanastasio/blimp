use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState};

use crate::app::App;
use crate::state::interaction::Pane;
use crate::types::{FileDiff, LineKind};

/// A pre-rendered line. Built once when the file changes, reused every frame.
#[derive(Clone)]
pub struct RenderedLine {
    pub spans: Vec<(String, Style)>,
}

/// Cache of pre-rendered diff lines for the current file.
pub struct DiffCache {
    pub file_path: String,
    pub rows: Vec<RenderedLine>,
    pub total: usize,
}

impl DiffCache {
    pub fn empty() -> Self {
        Self {
            file_path: String::new(),
            rows: Vec::new(),
            total: 0,
        }
    }

    /// Rebuild cache for a new file. This is the expensive operation --
    /// runs syntax highlighting on every line. Only called on file switch.
    pub fn rebuild(diff: &FileDiff, app_theme: &crate::ui::theme::Theme, highlighter: &crate::ui::highlight::Highlighter) -> Self {
        let t = app_theme;
        let ext = crate::ui::highlight::Highlighter::extension_from_path(&diff.path);
        let mut session = highlighter.session(ext);
        let mut rows = Vec::new();

        for (hunk_i, hunk) in diff.hunks.iter().enumerate() {
            // Header row
            rows.push(RenderedLine {
                spans: vec![(hunk.header.clone(), Style::default().fg(t.diff_hunk_header_fg).bg(t.diff_hunk_header_bg))],
            });

            // Code rows
            for diff_line in &hunk.lines {
                let (prefix, bg) = match diff_line.kind {
                    LineKind::Addition => ("+", t.diff_add_bg),
                    LineKind::Deletion => ("-", t.diff_del_bg),
                    LineKind::Context => (" ", t.bg),
                };

                let mut gutter = String::with_capacity(10);
                match diff_line.old_line {
                    Some(n) => { use std::fmt::Write; let _ = write!(gutter, "{:>4}", n); }
                    None => gutter.push_str("    "),
                }
                gutter.push(' ');
                match diff_line.new_line {
                    Some(n) => { use std::fmt::Write; let _ = write!(gutter, "{:>4}", n); }
                    None => gutter.push_str("    "),
                }
                gutter.push(' ');

                let mut line_spans: Vec<(String, Style)> = Vec::with_capacity(6);
                line_spans.push((gutter, Style::default().fg(t.fg_dim).bg(t.bg_gutter)));
                line_spans.push((prefix.to_string(), Style::default().fg(t.fg_dim).bg(bg)));

                // Syntax highlight
                let syn = session.highlight_line(&diff_line.content, bg);
                for span in syn {
                    line_spans.push((span.content.to_string(), span.style));
                }

                rows.push(RenderedLine { spans: line_spans });
            }

            // Blank separator
            if hunk_i < diff.hunks.len() - 1 {
                rows.push(RenderedLine {
                    spans: vec![("".to_string(), Style::default().bg(t.bg))],
                });
            }
        }

        let total = rows.len();
        Self {
            file_path: diff.path.clone(),
            rows,
            total,
        }
    }
}

pub fn render(frame: &mut Frame, app: &App, area: Rect) {
    let t = &app.theme;
    let focused = app.ix.active_pane() == Pane::DiffView;
    let border_color = if focused { t.border_focused } else { t.border };

    let diff = match app.nav.selected_file.as_ref()
        .and_then(|f| app.repo_state.as_ref()?.diffs.get(f))
        .or(app.selected_diff.as_ref())
    {
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

    let cache = &app.diff_cache;

    // If cache is stale (different file), show a lightweight preview
    if cache.file_path != diff.path {
        let info = format!(
            "{}: +{} -{} ({} hunks)",
            diff.path, diff.additions, diff.deletions, diff.hunks.len()
        );
        let msg = Paragraph::new(info)
            .block(block)
            .style(Style::default().fg(t.fg_dim));
        frame.render_widget(msg, area);
        return;
    }

    let total = cache.total;

    // Viewport
    let viewport_height = area.height.saturating_sub(2) as usize;
    let scroll = app.diff_scroll.min(total.saturating_sub(viewport_height.max(1)));

    // Slice the pre-rendered cache -- zero highlighting work here
    let end = (scroll + viewport_height).min(total);
    let visible = &cache.rows[scroll..end];

    let lines: Vec<Line> = visible
        .iter()
        .map(|row| {
            Line::from(
                row.spans
                    .iter()
                    .map(|(text, style)| Span::styled(text.as_str(), *style))
                    .collect::<Vec<_>>(),
            )
        })
        .collect();

    let paragraph = Paragraph::new(lines)
        .block(block)
        .scroll((0, app.diff_hscroll as u16));

    frame.render_widget(paragraph, area);

    // Scrollbar
    if total > viewport_height {
        let mut scrollbar_state = ScrollbarState::new(total).position(scroll);
        let scrollbar = Scrollbar::new(ScrollbarOrientation::VerticalRight);
        frame.render_stateful_widget(scrollbar, area, &mut scrollbar_state);
    }
}

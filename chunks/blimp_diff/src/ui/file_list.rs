use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph};

use crate::app::App;
use crate::state::navigation::Focus;
use crate::types::Status;
use crate::ui::theme::Theme;

pub fn render(frame: &mut Frame, app: &App, area: Rect) {
    let t = &app.theme;
    let focused = app.nav.focus == Focus::FileList;
    let border_color = if focused { t.border_focused } else { t.border };

    let files = match &app.repo_state {
        Some(state) => &state.files,
        None => {
            let block = themed_block(" files ", border_color, t);
            let msg = Paragraph::new("Loading...")
                .block(block)
                .style(Style::default().fg(t.fg_dim).bg(t.bg));
            frame.render_widget(msg, area);
            return;
        }
    };

    if files.is_empty() {
        let block = themed_block(" files ", border_color, t);
        let msg = Paragraph::new("  Working tree clean")
            .block(block)
            .style(Style::default().fg(t.fg_dim).bg(t.bg));
        frame.render_widget(msg, area);
        return;
    }

    let items: Vec<ListItem> = files
        .iter()
        .enumerate()
        .map(|(i, entry)| {
            let icon = status_icon(entry.staged, entry.unstaged);
            let staged_badge = if entry.staged != Status::None { "S " } else { "  " };

            let counts = app
                .repo_state
                .as_ref()
                .and_then(|r| r.diffs.get(&entry.path))
                .map(|d| format!("+{} -{}", d.additions, d.deletions))
                .unwrap_or_default();

            let line = Line::from(vec![
                Span::styled(
                    format!("{} ", icon),
                    Style::default().fg(status_color(entry.staged, entry.unstaged, t)),
                ),
                Span::styled(staged_badge, Style::default().fg(t.status_staged)),
                Span::styled(entry.path.as_str(), Style::default().fg(t.fg)),
                Span::styled(format!(" {}", counts), Style::default().fg(t.fg_dim)),
            ]);

            let style = if i == app.nav.file_index {
                Style::default().bg(t.bg_selected).fg(t.fg_bright)
            } else {
                Style::default().bg(t.bg)
            };

            ListItem::new(line).style(style)
        })
        .collect();

    let list = List::new(items).block(themed_block(" files ", border_color, t));

    let mut list_state = ListState::default().with_selected(Some(app.nav.file_index));
    frame.render_stateful_widget(list, area, &mut list_state);
}

fn themed_block<'a>(title: &'a str, border_color: Color, t: &Theme) -> Block<'a> {
    Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_style(Style::default().fg(border_color))
        .style(Style::default().bg(t.bg))
}

fn status_icon(staged: Status, unstaged: Status) -> char {
    match (staged, unstaged) {
        (Status::Added, _) => 'A',
        (Status::Deleted, _) | (_, Status::Deleted) => 'D',
        (Status::Renamed, _) => 'R',
        (_, Status::Untracked) => '?',
        (Status::Modified, _) | (_, Status::Modified) => 'M',
        _ => ' ',
    }
}

fn status_color(staged: Status, unstaged: Status, t: &Theme) -> Color {
    match (staged, unstaged) {
        (Status::Added, _) => t.status_added,
        (Status::Deleted, _) | (_, Status::Deleted) => t.status_deleted,
        (Status::Renamed, _) => t.status_renamed,
        (_, Status::Untracked) => t.status_untracked,
        (Status::Modified, _) | (_, Status::Modified) => t.status_modified,
        _ => t.fg,
    }
}

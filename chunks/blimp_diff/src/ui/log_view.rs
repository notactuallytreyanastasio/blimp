use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, List, ListItem, ListState};

use crate::app::App;
use crate::state::navigation::Focus;

pub fn render(frame: &mut Frame, app: &App, area: Rect) {
    let t = &app.theme;
    let focused = app.nav.focus == Focus::LogView;
    let border_color = if focused { t.border_focused } else { t.border };

    let items: Vec<ListItem> = app
        .log_entries
        .iter()
        .enumerate()
        .map(|(i, entry)| {
            let style = if i == app.nav.log_index {
                Style::default().bg(t.bg_selected).fg(t.fg_bright)
            } else {
                Style::default().bg(t.bg)
            };

            ListItem::new(Line::from(vec![
                Span::styled(
                    format!("{} ", &entry.hash),
                    Style::default().fg(t.bar_accent),
                ),
                Span::styled(entry.message.as_str(), Style::default().fg(t.fg)),
            ]))
            .style(style)
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .title(" log ")
            .borders(Borders::ALL)
            .border_style(Style::default().fg(border_color))
            .style(Style::default().bg(t.bg)),
    );

    let mut list_state = ListState::default().with_selected(Some(app.nav.log_index));
    frame.render_stateful_widget(list, area, &mut list_state);
}

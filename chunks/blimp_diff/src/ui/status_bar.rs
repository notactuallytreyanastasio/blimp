use ratatui::prelude::*;
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::state::interaction::Mode;

pub fn render(frame: &mut Frame, app: &App, area: Rect) {
    let t = &app.theme;

    let branch = app
        .repo_state
        .as_ref()
        .map(|r| r.branch.as_str())
        .unwrap_or("???");

    let file_count = app.nav.file_count;
    let follow = if app.nav.following { "ON" } else { "off" };

    let focus_hint = match app.ix.mode {
        Mode::FileList => "j/k:move Enter:view s:stage u:unstage cc:commit t:theme",
        Mode::DiffView => "j/k:scroll Enter:next-hunk q:back v:select h/l:pan Tab:files",
        Mode::LogList => "j/k:move Enter:detail q:back",
        Mode::LogDetail => "q:back",
        Mode::Selecting => "j/k:extend Enter:confirm Esc:cancel",
        Mode::Committing { .. } => "Ctrl+Enter:submit Esc:cancel",
        Mode::AgentPrompt => "Ctrl+Enter:send Esc:cancel",
        Mode::Dragging => "release to stop",
    };

    let status = if let Some(ref msg) = app.status_message {
        Span::styled(msg.as_str(), Style::default().fg(t.error))
    } else {
        Span::raw("")
    };

    let follow_style = if app.nav.following {
        Style::default().fg(t.border_focused)
    } else {
        Style::default().fg(t.fg_dim)
    };

    let line = Line::from(vec![
        Span::styled(
            format!(" {} ", branch),
            Style::default().fg(t.bar_accent).bold(),
        ),
        Span::styled(" | ", Style::default().fg(t.fg_dim)),
        Span::styled(format!("files: {} ", file_count), Style::default().fg(t.bar_fg)),
        Span::styled(" | ", Style::default().fg(t.fg_dim)),
        Span::styled(format!("follow: {} ", follow), follow_style),
        Span::styled(" | ", Style::default().fg(t.fg_dim)),
        Span::styled(
            format!("{} ", app.theme_name.label()),
            Style::default().fg(t.bar_accent),
        ),
        Span::styled(" | ", Style::default().fg(t.fg_dim)),
        Span::styled(focus_hint, Style::default().fg(t.fg_dim)),
        Span::raw("  "),
        status,
    ]);

    let paragraph = Paragraph::new(line)
        .style(Style::default().bg(t.bar_bg).fg(t.bar_fg));
    frame.render_widget(paragraph, area);
}

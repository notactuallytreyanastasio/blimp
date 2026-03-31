use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Wrap};

use crate::app::{App, InputMode};

pub fn render_commit(frame: &mut Frame, app: &App, area: Rect) {
    let t = &app.theme;
    let popup_area = centered_rect(60, 30, area);
    frame.render_widget(Clear, popup_area);

    let title = match app.commit.mode {
        crate::state::commit::CommitMode::Commit => " commit message ",
        crate::state::commit::CommitMode::Amend => " amend message ",
    };

    let error_line = if let Some(ref err) = app.commit.error_message {
        format!("\n\nError: {}", err)
    } else {
        String::new()
    };

    let text = format!(
        "{}{}\n\n~ Enter to submit, Esc to cancel ~",
        app.input_buffer, error_line,
    );

    let block = Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_style(Style::default().fg(t.overlay_border))
        .style(Style::default().bg(t.overlay_bg));

    let paragraph = Paragraph::new(text)
        .block(block)
        .style(Style::default().fg(t.overlay_fg))
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, popup_area);

    frame.set_cursor_position(Position::new(
        popup_area.x + 1 + app.input_cursor as u16,
        popup_area.y + 1,
    ));
}

pub fn render_agent_prompt(frame: &mut Frame, app: &App, area: Rect) {
    let t = &app.theme;
    let popup_area = centered_rect(70, 40, area);
    frame.render_widget(Clear, popup_area);

    let selected_lines = if let (Some(ref diff), Some((start, end))) =
        (&app.selected_diff, app.selection.selected_range())
    {
        let mut lines = String::new();
        for hunk in &diff.hunks {
            for dl in &hunk.lines {
                let line_num = dl.new_line.or(dl.old_line).unwrap_or(0);
                if line_num >= start && line_num <= end {
                    let prefix = match dl.kind {
                        crate::types::LineKind::Addition => "+",
                        crate::types::LineKind::Deletion => "-",
                        crate::types::LineKind::Context => " ",
                    };
                    lines.push_str(&format!("{}{}\n", prefix, dl.content));
                }
            }
        }
        lines
    } else {
        String::new()
    };

    let text = format!(
        "{}\n---\nYour comment: {}\n\n~ Enter to send to Claude, Esc to cancel ~",
        selected_lines, app.input_buffer,
    );

    let block = Block::default()
        .title(" agent prompt ")
        .borders(Borders::ALL)
        .border_style(Style::default().fg(t.bar_accent))
        .style(Style::default().bg(t.overlay_bg));

    let paragraph = Paragraph::new(text)
        .block(block)
        .style(Style::default().fg(t.overlay_fg))
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, popup_area);
}

fn centered_rect(percent_x: u16, percent_y: u16, area: Rect) -> Rect {
    let popup_layout = Layout::vertical([
        Constraint::Percentage((100 - percent_y) / 2),
        Constraint::Percentage(percent_y),
        Constraint::Percentage((100 - percent_y) / 2),
    ])
    .split(area);

    Layout::horizontal([
        Constraint::Percentage((100 - percent_x) / 2),
        Constraint::Percentage(percent_x),
        Constraint::Percentage((100 - percent_x) / 2),
    ])
    .split(popup_layout[1])[1]
}

pub mod file_list;
pub mod diff_pane;
pub mod log_view;
pub mod overlays;
pub mod status_bar;
pub mod theme;
pub mod highlight;

use ratatui::prelude::*;

use crate::app::App;
use crate::state::interaction::Mode;

pub fn render(frame: &mut Frame, app: &App) {
    // When an overlay is active, skip the expensive background rendering.
    if app.ix.is_overlay() {
        let bg = ratatui::widgets::Block::default()
            .style(ratatui::prelude::Style::default().bg(app.theme.bg));
        frame.render_widget(bg, frame.area());
        match app.ix.mode {
            Mode::Committing { .. } => overlays::render_commit(frame, app, frame.area()),
            Mode::AgentPrompt => overlays::render_agent_prompt(frame, app, frame.area()),
            Mode::Selecting => {
                // Selection shows the diff view underneath with selection highlight
                render_main(frame, app);
            }
            _ => {}
        }
        return;
    }

    render_main(frame, app);
}

fn render_main(frame: &mut Frame, app: &App) {
    let chunks = Layout::vertical([
        Constraint::Min(1),
        Constraint::Length(1),
    ])
    .split(frame.area());

    let main_area = chunks[0];
    let bar_area = chunks[1];

    match app.ix.mode {
        Mode::LogList | Mode::LogDetail => render_log_layout(frame, app, main_area),
        _ => render_diff_layout(frame, app, main_area),
    }

    status_bar::render(frame, app, bar_area);
}

fn render_diff_layout(frame: &mut Frame, app: &App, area: Rect) {
    // Fill background with theme color
    let bg = ratatui::widgets::Block::default()
        .style(Style::default().bg(app.theme.bg));
    frame.render_widget(bg, area);

    let chunks = Layout::horizontal([
        Constraint::Length(app.pane_width),
        Constraint::Min(1),
    ])
    .split(area);

    file_list::render(frame, app, chunks[0]);
    diff_pane::render(frame, app, chunks[1]);
}

fn render_log_layout(frame: &mut Frame, app: &App, area: Rect) {
    // For now, just show log list full width
    // LogDetail will split later when we add commit detail pane
    log_view::render(frame, app, area);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::App;
    use ratatui::backend::TestBackend;
    use std::fs;
    use std::process::Command;

    fn temp_repo_app() -> (tempfile::TempDir, App) {
        let dir = tempfile::tempdir().unwrap();
        Command::new("git").args(["init"]).current_dir(dir.path()).output().unwrap();
        Command::new("git").args(["config", "user.email", "t@t.com"]).current_dir(dir.path()).output().unwrap();
        Command::new("git").args(["config", "user.name", "T"]).current_dir(dir.path()).output().unwrap();
        fs::write(dir.path().join("README.md"), "# test\n").unwrap();
        Command::new("git").args(["add", "README.md"]).current_dir(dir.path()).output().unwrap();
        Command::new("git").args(["commit", "-m", "init"]).current_dir(dir.path()).output().unwrap();
        let app = App::new(dir.path().to_path_buf());
        (dir, app)
    }

    #[test]
    fn renders_clean_repo_without_panic() {
        let (_dir, mut app) = temp_repo_app();
        app.refresh();

        let backend = TestBackend::new(80, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(frame, &app)).unwrap();

        let buf = terminal.backend().buffer().clone();
        let content = buf_to_string(&buf);
        assert!(content.contains("files"), "should show files pane");
        assert!(content.contains("clean") || content.contains("diff"), "should show empty state or diff");
    }

    #[test]
    fn renders_modified_file() {
        let (dir, mut app) = temp_repo_app();
        fs::write(dir.path().join("README.md"), "# changed\n").unwrap();
        app.refresh();

        let backend = TestBackend::new(100, 30);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(frame, &app)).unwrap();

        let buf = terminal.backend().buffer().clone();
        let content = buf_to_string(&buf);
        assert!(content.contains("README"), "should show the modified file");
    }

    #[test]
    fn renders_status_bar_with_branch() {
        let (_dir, mut app) = temp_repo_app();
        app.refresh();

        let backend = TestBackend::new(80, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(frame, &app)).unwrap();

        let buf = terminal.backend().buffer().clone();
        let content = buf_to_string(&buf);
        // Should contain branch name and "files:" count
        assert!(content.contains("files:"), "status bar should show file count");
        assert!(content.contains("follow:"), "status bar should show follow status");
    }

    #[test]
    fn renders_diff_view_with_hunks() {
        let (dir, mut app) = temp_repo_app();
        fs::write(dir.path().join("README.md"), "# changed\nnew line\n").unwrap();
        app.refresh();

        // Navigate into diff view
        app.dispatch(crate::state::interaction::Action::Select);
        assert_eq!(app.ix.mode, Mode::DiffView);

        let backend = TestBackend::new(100, 30);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| render(frame, &app)).unwrap();

        let buf = terminal.backend().buffer().clone();
        let content = buf_to_string(&buf);
        assert!(content.contains("@@"), "should show hunk header");
    }

    fn buf_to_string(buf: &ratatui::buffer::Buffer) -> String {
        let mut s = String::new();
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                s.push(buf.cell((x, y)).map(|c| c.symbol().chars().next().unwrap_or(' ')).unwrap_or(' '));
            }
            s.push('\n');
        }
        s
    }
}

mod types;
mod git;
mod state;
mod ui;
mod agent;
mod app;

use std::io;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use crossterm::event::{
    self, DisableFocusChange, DisableMouseCapture, EnableFocusChange, EnableMouseCapture,
    Event, KeyCode, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::prelude::*;

use app::App;
use git::watcher::{RepoWatcher, WatchEvent};
use state::interaction::{Interaction, Action};

fn main() -> io::Result<()> {
    let repo_path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap());

    // Canonicalize to resolve relative paths
    let repo_path = repo_path.canonicalize().unwrap_or(repo_path);

    // Verify git repo
    if !repo_path.join(".git").exists() {
        eprintln!("error: {} is not a git repository", repo_path.display());
        std::process::exit(1);
    }

    // Check for --follow flag
    let start_following = std::env::args().any(|a| a == "--follow");

    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture, EnableFocusChange)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Setup app
    let mut app = App::new(repo_path.clone());
    app.terminal_height = terminal.size()?.height;
    if start_following {
        app.nav.following = true;
    }
    app.refresh();

    // Setup file watcher
    let (watch_tx, watch_rx) = mpsc::channel();
    let _watcher = RepoWatcher::new(repo_path, watch_tx);

    // Main event loop
    let result = run_loop(&mut terminal, &mut app, &watch_rx);

    // Restore terminal
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen, DisableMouseCapture, DisableFocusChange)?;
    terminal.show_cursor()?;

    result
}

fn run_loop(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut App,
    watch_rx: &mpsc::Receiver<WatchEvent>,
) -> io::Result<()> {
    loop {
        // 1. Drain ALL pending input events before drawing
        while event::poll(Duration::ZERO)? {
            match event::read()? {
                Event::Key(key) if key.kind == KeyEventKind::Press => {
                    let action = key_to_action(key.code, key.modifiers, &app.ix);
                    app.dispatch(action);
                }
                Event::Mouse(mouse) => {
                    let action = mouse_to_action(mouse, app.pane_width, app.file_list_scroll);
                    app.dispatch(action);
                }
                Event::Resize(_, h) => {
                    app.terminal_height = h;
                    app.needs_redraw = true;
                }
                Event::FocusGained => {
                    // Re-sync state after returning to the window
                    app.refresh();
                }
                Event::FocusLost => {
                    // Nothing to do, but consuming the event prevents
                    // crossterm from getting confused
                }
                _ => {}
            }
            if app.should_quit {
                return Ok(());
            }
        }

        // 2. Check for file system changes (drain all pending, refresh once)
        // Skip refresh while overlay is active -- typing must stay fast
        let mut needs_refresh = false;
        while watch_rx.try_recv().is_ok() {
            needs_refresh = true;
        }
        if needs_refresh && !app.ix.is_text_input() {
            app.refresh();
        }

        // 3. Draw once if anything changed
        if app.needs_redraw {
            terminal.draw(|frame| ui::render(frame, app))?;
            app.needs_redraw = false;
        }

        // 4. Block until next event -- 16ms = 60fps responsiveness
        if !event::poll(Duration::from_millis(16))? {
            // Timeout -- check watcher and loop
            continue;
        }
    }

    Ok(())
}

/// Map a physical key event to a semantic Action based on current mode.
fn key_to_action(code: KeyCode, modifiers: KeyModifiers, ix: &Interaction) -> Action {
    // Ctrl+C always quits
    if code == KeyCode::Char('c') && modifiers.contains(KeyModifiers::CONTROL) {
        return Action::Quit;
    }

    // Text input modes have their own mapping
    if ix.is_text_input() {
        return match code {
            KeyCode::Enter
                if modifiers.contains(KeyModifiers::CONTROL)
                    || modifiers.contains(KeyModifiers::META) =>
            {
                Action::Submit
            }
            KeyCode::Enter => Action::InsertNewline,
            KeyCode::Esc => Action::Cancel,
            KeyCode::Backspace => Action::DeleteChar,
            KeyCode::Char(c) => Action::InsertChar(c),
            _ => Action::Noop,
        };
    }

    // Normal/browse modes
    match code {
        KeyCode::Char('j') | KeyCode::Down => Action::Down,
        KeyCode::Char('k') | KeyCode::Up => Action::Up,
        KeyCode::Enter => Action::Select,
        KeyCode::Char('q') | KeyCode::Esc => Action::Back,
        KeyCode::Tab => Action::TogglePane,
        KeyCode::Char('f') | KeyCode::Char('F') => Action::ToggleFollow,
        KeyCode::Char('l') => Action::ToggleLog,
        KeyCode::Char('o') => Action::OpenEditor,
        KeyCode::Char('s') => Action::StageFile,
        KeyCode::Char('u') => Action::UnstageFile,
        KeyCode::Char('c') => Action::CommitChord,
        KeyCode::Char('a') => Action::StartAmend,
        KeyCode::Char('v') => Action::StartVisual,
        KeyCode::Char(' ') => Action::PageDown,
        KeyCode::Char('b') => Action::PageUp,
        KeyCode::Char('h') | KeyCode::Left => Action::ScrollLeft,
        KeyCode::Char('H') => Action::ScrollHome,
        KeyCode::Right => Action::ScrollRight,
        KeyCode::Char('t') => Action::CycleTheme,
        KeyCode::Char('Q') => Action::Quit,
        _ => Action::Noop,
    }
}

/// Map a mouse event to a semantic Action.
fn mouse_to_action(mouse: MouseEvent, pane_width: u16, file_scroll: usize) -> Action {
    match mouse.kind {
        MouseEventKind::Down(MouseButton::Left) => {
            let x = mouse.column;
            let y = mouse.row;
            if x < pane_width {
                if y > 0 {
                    let idx = (y - 1) as usize + file_scroll;
                    Action::ClickFileList(idx)
                } else {
                    Action::Noop
                }
            } else {
                Action::ClickDiffPane
            }
        }
        MouseEventKind::Drag(MouseButton::Left) => {
            Action::DragDivider(mouse.column)
        }
        MouseEventKind::Down(MouseButton::Right) => {
            if mouse.column < pane_width {
                Action::Select
            } else {
                Action::Noop
            }
        }
        MouseEventKind::ScrollUp => {
            if mouse.column < pane_width {
                Action::ScrollUp
            } else {
                Action::ScrollDiffUp
            }
        }
        MouseEventKind::ScrollDown => {
            if mouse.column < pane_width {
                Action::ScrollDown
            } else {
                Action::ScrollDiffDown
            }
        }
        _ => Action::Noop,
    }
}

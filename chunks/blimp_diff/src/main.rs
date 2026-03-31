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
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind,
    KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::prelude::*;

use app::{App, InputMode};
use git::watcher::{RepoWatcher, WatchEvent};
use state::navigation::NavKey;

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
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Setup app
    let mut app = App::new(repo_path.clone());
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
    execute!(terminal.backend_mut(), LeaveAlternateScreen, DisableMouseCapture)?;
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
                    match app.input_mode {
                        InputMode::Normal => handle_normal_key(app, key.code, key.modifiers),
                        InputMode::CommitMessage => handle_input_key(app, key.code),
                        InputMode::AgentPrompt => handle_input_key(app, key.code),
                    }
                }
                Event::Mouse(mouse) => {
                    handle_mouse(app, mouse);
                }
                Event::Resize(_, _) => {
                    app.needs_redraw = true;
                }
                _ => {}
            }
            if app.should_quit {
                return Ok(());
            }
        }

        // 2. Check for file system changes (drain all pending, refresh once)
        let mut needs_refresh = false;
        while watch_rx.try_recv().is_ok() {
            needs_refresh = true;
        }
        if needs_refresh {
            app.refresh();
        }

        // 3. Draw once if anything changed
        if app.needs_redraw {
            terminal.draw(|frame| ui::render(frame, app))?;
            app.needs_redraw = false;
        }

        // 4. Block until next event (key, resize, etc) -- no busy spin
        if !event::poll(Duration::from_millis(100))? {
            // Timeout -- check watcher and loop
            continue;
        }
    }

    Ok(())
}

fn handle_normal_key(app: &mut App, code: KeyCode, modifiers: KeyModifiers) {
    // Ctrl+C always quits
    if code == KeyCode::Char('c') && modifiers.contains(KeyModifiers::CONTROL) {
        app.should_quit = true;
        return;
    }

    let nav_key = match code {
        KeyCode::Char('j') | KeyCode::Down => NavKey::J,
        KeyCode::Char('k') | KeyCode::Up => NavKey::K,
        KeyCode::Enter => NavKey::Enter,
        KeyCode::Char('q') => NavKey::Q,
        KeyCode::Tab => NavKey::Tab,
        KeyCode::Char('f') | KeyCode::Char('F') => NavKey::F,
        KeyCode::Char('l') => NavKey::L,
        KeyCode::Char('o') => NavKey::O,
        KeyCode::Char('s') => NavKey::S,
        KeyCode::Char('u') => NavKey::U,
        KeyCode::Char('c') => NavKey::C,
        KeyCode::Char('a') => NavKey::A,
        KeyCode::Char('v') => NavKey::V,
        KeyCode::Esc => NavKey::Escape,
        KeyCode::Char('t') => {
            app.cycle_theme();
            return;
        }
        KeyCode::Char('Q') => {
            app.should_quit = true;
            return;
        }
        _ => return,
    };

    // Q at file list top level quits
    if nav_key == NavKey::Q && app.nav.focus == state::navigation::Focus::FileList {
        app.should_quit = true;
        return;
    }

    app.handle_nav_key(nav_key);
}

fn handle_mouse(app: &mut App, mouse: MouseEvent) {
    match mouse.kind {
        MouseEventKind::Down(MouseButton::Left) => {
            let x = mouse.column;
            let y = mouse.row;

            // Click in file list pane (left of divider)
            if x < app.pane_width {
                // Subtract 1 for border, y=0 is border too
                if y > 0 {
                    let file_idx = (y - 1) as usize + app.file_list_scroll;
                    if file_idx < app.nav.file_count {
                        app.nav.file_index = file_idx;
                        app.nav.selected_file = app.nav.file_paths.get(file_idx).cloned();
                        app.nav.focus = state::navigation::Focus::FileList;
                        app.update_selected_diff();
                        app.needs_redraw = true;
                    }
                }
            }
            // Click on divider (for drag start)
            else if x == app.pane_width {
                // Handled by Drag below
            }
            // Click in diff pane
            else {
                app.nav.focus = state::navigation::Focus::DiffView;
                app.needs_redraw = true;
            }
        }
        MouseEventKind::Drag(MouseButton::Left) => {
            let x = mouse.column;
            // Dragging the pane divider
            if x >= 15 && x <= 80 {
                app.pane_width = x;
                app.needs_redraw = true;
            }
        }
        MouseEventKind::Down(MouseButton::Right) => {
            // Double-click or right-click on file list -> enter diff view
            if mouse.column < app.pane_width {
                app.handle_nav_key(NavKey::Enter);
            }
        }
        MouseEventKind::ScrollUp => {
            match app.nav.focus {
                state::navigation::Focus::FileList => {
                    app.handle_nav_key(NavKey::K);
                }
                state::navigation::Focus::DiffView => {
                    app.diff_scroll = app.diff_scroll.saturating_sub(3);
                    app.needs_redraw = true;
                }
                state::navigation::Focus::LogView => {
                    app.handle_nav_key(NavKey::K);
                }
                _ => {}
            }
        }
        MouseEventKind::ScrollDown => {
            match app.nav.focus {
                state::navigation::Focus::FileList => {
                    app.handle_nav_key(NavKey::J);
                }
                state::navigation::Focus::DiffView => {
                    app.diff_scroll += 3;
                    app.needs_redraw = true;
                }
                state::navigation::Focus::LogView => {
                    app.handle_nav_key(NavKey::J);
                }
                _ => {}
            }
        }
        _ => {}
    }
}

fn handle_input_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Enter => {
            match app.input_mode {
                InputMode::CommitMessage => app.submit_commit(),
                InputMode::AgentPrompt => {
                    // TODO: dispatch to agent (Spec 13)
                    app.cancel_input();
                }
                _ => {}
            }
        }
        KeyCode::Esc => app.cancel_input(),
        KeyCode::Backspace => app.delete_char(),
        KeyCode::Char(c) => app.insert_char(c),
        _ => {}
    }
}

use std::env;
use std::io::{self, BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use crossterm::terminal::{self, EnterAlternateScreen, LeaveAlternateScreen};
use crossterm::{cursor, execute};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};
use ratatui::Terminal;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------


/// A single entry in the REPL output history.
#[derive(Clone)]
enum HistoryEntry {
    Input(String),
    Result(String),
    Error(String),
    Info(String),
}

/// A state variable parsed from the blimp output.
#[derive(Clone)]
struct StateVar {
    name: String,
    value: String,
}

#[derive(Clone, Copy, PartialEq)]
enum RightPanel {
    State,
    IR,
}

/// All application state.
struct App {
    /// Current input buffer (what the user is typing).
    input: String,
    /// Cursor position within `input`.
    cursor: usize,
    /// Completed REPL history (inputs, results, errors).
    history: Vec<HistoryEntry>,
    /// Scroll offset for the history view (0 = bottom).
    scroll_offset: usize,
    /// Input history for up/down browsing.
    input_history: Vec<String>,
    /// Position in input_history (-1 = current input).
    history_pos: Option<usize>,
    /// Saved current input when browsing history.
    saved_input: String,
    /// State variables extracted from blimp output.
    state_vars: Vec<StateVar>,
    /// For multi-line input: accumulated lines.
    multiline_buf: Vec<String>,
    /// Current `do`/`end` nesting depth.
    block_depth: i32,
    /// Whether we are running.
    running: bool,
    /// Channel receiver for blimp stdout lines.
    rx: mpsc::Receiver<String>,
    /// Handle to blimp child stdin.
    child_stdin: Option<std::process::ChildStdin>,
    /// Handle to the child process itself.
    child: Option<Child>,
    /// Which panel is shown on the right.
    right_panel: RightPanel,
    /// LLVM IR text (updated after each input).
    llvm_ir: String,
    /// Accumulated source for IR compilation.
    source_buf: String,
    /// Path to blimp-compile binary.
    compile_bin: Option<PathBuf>,
}

// ---------------------------------------------------------------------------
// Binary discovery
// ---------------------------------------------------------------------------

fn find_blimp_binary() -> Option<PathBuf> {
    // 1. BLIMP_PATH env var
    if let Ok(p) = env::var("BLIMP_PATH") {
        let path = PathBuf::from(&p);
        if path.exists() {
            return Some(path);
        }
    }

    // 2. Relative to the tui binary: ../lang/zig-out/bin/blimp
    if let Ok(exe) = env::current_exe() {
        // exe is typically target/release/blimp-tui or target/debug/blimp-tui
        // Walk up to find the chunks/ directory
        let mut dir = exe.clone();
        // Go up until we find a directory that contains "lang"
        for _ in 0..10 {
            dir.pop();
            let candidate = dir.join("lang").join("zig-out").join("bin").join("blimp");
            if candidate.exists() {
                return Some(candidate);
            }
        }
        // Also try: exe_dir/../../lang/zig-out/bin/blimp (works from target/release)
        if let Some(exe_dir) = exe.parent() {
            let candidate = exe_dir
                .join("..")
                .join("..")
                .join("..")
                .join("lang")
                .join("zig-out")
                .join("bin")
                .join("blimp");
            if candidate.exists() {
                return Some(candidate.canonicalize().unwrap_or(candidate));
            }
        }
    }

    // 3. Also try relative to CWD
    let cwd_candidate = PathBuf::from("../lang/zig-out/bin/blimp");
    if cwd_candidate.exists() {
        return Some(cwd_candidate.canonicalize().unwrap_or(cwd_candidate));
    }

    // 4. blimp in PATH
    if let Ok(output) = Command::new("which").arg("blimp").output() {
        if output.status.success() {
            let path_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path_str.is_empty() {
                return Some(PathBuf::from(path_str));
            }
        }
    }

    None
}

fn find_compile_binary() -> Option<PathBuf> {
    if let Ok(p) = env::var("BLIMP_COMPILE_PATH") {
        let path = PathBuf::from(&p);
        if path.exists() {
            return Some(path);
        }
    }

    // Look relative to blimp binary
    if let Some(blimp) = find_blimp_binary() {
        if let Some(dir) = blimp.parent() {
            let candidate = dir.join("blimp-compile");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }

    // In PATH
    if let Ok(output) = Command::new("which").arg("blimp-compile").output() {
        if output.status.success() {
            let path_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path_str.is_empty() {
                return Some(PathBuf::from(path_str));
            }
        }
    }

    None
}

// ---------------------------------------------------------------------------
// Process spawning
// ---------------------------------------------------------------------------

fn spawn_blimp(rx_sender: mpsc::Sender<String>) -> io::Result<Child> {
    let bin = find_blimp_binary().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "Could not find blimp binary. Set BLIMP_PATH or ensure blimp is in PATH.",
        )
    })?;

    let mut child = Command::new(&bin)
        .arg("--repl")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| {
            io::Error::new(
                e.kind(),
                format!("Failed to spawn blimp at {}: {}", bin.display(), e),
            )
        })?;

    let stdout = child.stdout.take().expect("Failed to capture stdout");

    // Spawn reader thread
    std::thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            match line {
                Ok(l) => {
                    if rx_sender.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    Ok(child)
}

// ---------------------------------------------------------------------------
// Output parsing
// ---------------------------------------------------------------------------

fn parse_output_line(line: &str, state_vars: &mut Vec<StateVar>, history: &mut Vec<HistoryEntry>) {
    let trimmed = line.trim();

    // Ignore banner
    if trimmed.starts_with("Blimp REPL") {
        return;
    }

    // Prompt lines may contain results: "blimp> => 4"
    if trimmed.starts_with("blimp>") {
        let after_prompt = trimmed["blimp>".len()..].trim();
        if after_prompt.starts_with("=>") {
            let val = after_prompt[2..].trim().to_string();
            history.push(HistoryEntry::Result(val));
        }
        return;
    }

    // Continuation prompts may contain results: "  ... => 4"
    if trimmed.starts_with("...") {
        let after_dots = trimmed[3..].trim();
        if after_dots.starts_with("=>") {
            let val = after_dots[2..].trim().to_string();
            history.push(HistoryEntry::Result(val));
        }
        return;
    }

    // Ignore state box boundaries
    if trimmed.contains("┌─") || trimmed.contains("└─") {
        return;
    }

    // State variable: │ name = value
    if trimmed.starts_with('│') || trimmed.starts_with("│") {
        // Remove the │ prefix (might be multi-byte UTF-8)
        let after_bar = if trimmed.starts_with('│') {
            &trimmed[3..] // │ is 3 bytes in UTF-8
        } else {
            trimmed.trim_start_matches("│")
        };
        let after_bar = after_bar.trim();
        if let Some(eq_pos) = after_bar.find('=') {
            let name = after_bar[..eq_pos].trim().to_string();
            let value = after_bar[eq_pos + 1..].trim().to_string();
            if !name.is_empty() {
                // Update existing or add new
                if let Some(existing) = state_vars.iter_mut().find(|v| v.name == name) {
                    existing.value = value;
                } else {
                    state_vars.push(StateVar { name, value });
                }
            }
        }
        return;
    }

    // Result line
    if trimmed.starts_with("=>") {
        let val = trimmed[2..].trim().to_string();
        history.push(HistoryEntry::Result(val));
        return;
    }

    // Error line
    if trimmed.starts_with("--") && trimmed.ends_with("--") {
        let err = trimmed
            .trim_start_matches("--")
            .trim_end_matches("--")
            .trim()
            .to_string();
        history.push(HistoryEntry::Error(err));
        return;
    }

    // Error continuation or detail lines (after -- ERROR --)
    if trimmed.starts_with("--") {
        let err = trimmed.trim_start_matches("--").trim().to_string();
        history.push(HistoryEntry::Error(err));
        return;
    }

    // Anything else that is non-empty is info
    if !trimmed.is_empty() {
        history.push(HistoryEntry::Info(trimmed.to_string()));
    }
}

// ---------------------------------------------------------------------------
// IR compilation
// ---------------------------------------------------------------------------

fn compile_to_ir(compile_bin: &PathBuf, source: &str) -> String {
    use std::io::Write as IoWrite;

    // Write source to temp file
    let tmp_path = "/tmp/_blimp_ir_preview.blimp";
    if let Ok(mut f) = std::fs::File::create(tmp_path) {
        let _ = f.write_all(source.as_bytes());
    } else {
        return "Error: could not write temp file".to_string();
    }

    // Run blimp-compile --dump-ir (IR goes to stderr)
    match Command::new(compile_bin)
        .arg(tmp_path)
        .arg("--dump-ir")
        .arg("-o")
        .arg("/tmp/_blimp_ir_preview_out")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
    {
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            // IR is on stderr (LLVMDumpModule writes there)
            if !stderr.is_empty() {
                // Filter out the "Compiled:" line
                stderr
                    .lines()
                    .filter(|l| !l.starts_with("Compiled:"))
                    .collect::<Vec<_>>()
                    .join("\n")
            } else if !stdout.is_empty() {
                stdout
            } else {
                "(no IR generated)".to_string()
            }
        }
        Err(e) => format!("Compile error: {}", e),
    }
}

// ---------------------------------------------------------------------------
// Block depth tracking for multi-line
// ---------------------------------------------------------------------------

fn compute_depth_delta(line: &str) -> i32 {
    let mut delta: i32 = 0;
    // Simple keyword counting - not a full parser, but good enough for the REPL
    for word in line.split_whitespace() {
        match word {
            "do" => delta += 1,
            "end" => delta -= 1,
            _ => {}
        }
    }
    // Also check for `do` at end of line after stripping comments
    let stripped = line.split('#').next().unwrap_or(line);
    if stripped.trim_end().ends_with("do") && !line.split_whitespace().any(|w| w == "do") {
        delta += 1;
    }
    delta
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn render(terminal: &mut Terminal<CrosstermBackend<io::Stdout>>, app: &App) -> io::Result<()> {
    terminal.draw(|f| {
        let size = f.area();

        // Main layout: content area + status bar at bottom
        let outer = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(3), Constraint::Length(1)])
            .split(size);

        let content_area = outer[0];
        let status_area = outer[1];

        // Split content into left (REPL) and right (STATE/IR)
        let right_pct = if app.right_panel == RightPanel::IR { 50 } else { 25 };
        let panels = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(100 - right_pct), Constraint::Percentage(right_pct)])
            .split(content_area);

        let repl_area = panels[0];
        let right_area = panels[1];

        // ----- REPL Panel -----
        render_repl(f, app, repl_area);

        // ----- Right Panel -----
        match app.right_panel {
            RightPanel::State => render_state(f, app, right_area),
            RightPanel::IR => render_ir(f, app, right_area),
        }

        // ----- Status Bar -----
        render_status(f, app, status_area);
    })?;
    Ok(())
}

fn render_repl(f: &mut ratatui::Frame, app: &App, area: Rect) {
    let block = Block::default()
        .title(" BLIMP REPL ")
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::DarkGray));

    let inner = block.inner(area);
    f.render_widget(block, area);

    if inner.height < 2 || inner.width < 4 {
        return;
    }

    // Reserve last line for input
    let history_height = inner.height.saturating_sub(1) as usize;
    let input_y = inner.y + inner.height - 1;

    // Build history lines
    let mut lines: Vec<Line> = Vec::new();
    for entry in &app.history {
        match entry {
            HistoryEntry::Input(s) => {
                lines.push(Line::from(vec![
                    Span::styled("blimp> ", Style::default().fg(Color::Green)),
                    Span::styled(s.clone(), Style::default().fg(Color::White)),
                ]));
            }
            HistoryEntry::Result(s) => {
                lines.push(Line::from(vec![
                    Span::styled("=> ", Style::default().fg(Color::DarkGray)),
                    Span::styled(s.clone(), Style::default().fg(Color::White)),
                ]));
            }
            HistoryEntry::Error(s) => {
                lines.push(Line::from(vec![Span::styled(
                    format!("-- {} --", s),
                    Style::default().fg(Color::Red),
                )]));
            }
            HistoryEntry::Info(s) => {
                lines.push(Line::from(vec![Span::styled(
                    s.clone(),
                    Style::default().fg(Color::DarkGray),
                )]));
            }
        }
    }

    // Bottom-align: show the most recent lines, sticking to the bottom
    let total = lines.len();
    let visible_start = if total > history_height {
        total - history_height - app.scroll_offset.min(total.saturating_sub(history_height))
    } else {
        0
    };
    let visible_end = (visible_start + history_height).min(total);
    let mut visible_lines: Vec<Line> = if total > 0 {
        lines[visible_start..visible_end].to_vec()
    } else {
        Vec::new()
    };

    // Pad with empty lines at the top so content sticks to the bottom
    while visible_lines.len() < history_height {
        visible_lines.insert(0, Line::from(""));
    }

    let history_area = Rect::new(inner.x, inner.y, inner.width, history_height as u16);
    let para = Paragraph::new(visible_lines).wrap(Wrap { trim: false });
    f.render_widget(para, history_area);

    // Render input line
    let prompt = if app.block_depth > 0 { "  ...  " } else { "blimp> " };
    let prompt_len = prompt.len() as u16;
    let input_area = Rect::new(inner.x, input_y, inner.width, 1);

    let input_line = Line::from(vec![
        Span::styled(prompt, Style::default().fg(Color::Green)),
        Span::styled(app.input.clone(), Style::default().fg(Color::White)),
    ]);
    let input_para = Paragraph::new(input_line);
    f.render_widget(input_para, input_area);

    // Set cursor position
    let cursor_x = inner.x + prompt_len + app.cursor as u16;
    let cursor_x = cursor_x.min(inner.x + inner.width - 1);
    f.set_cursor_position((cursor_x, input_y));
}

fn render_state(f: &mut ratatui::Frame, app: &App, area: Rect) {
    let block = Block::default()
        .title(" STATE ")
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::DarkGray));

    let inner = block.inner(area);
    f.render_widget(block, area);

    if inner.height < 1 || inner.width < 4 {
        return;
    }

    let mut lines: Vec<Line> = Vec::new();
    for var in &app.state_vars {
        lines.push(Line::from(vec![
            Span::styled(
                var.name.clone(),
                Style::default()
                    .fg(Color::Blue)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" = ", Style::default().fg(Color::DarkGray)),
            Span::styled(var.value.clone(), Style::default().fg(Color::White)),
        ]));
    }

    if lines.is_empty() {
        lines.push(Line::from(vec![Span::styled(
            "(no variables)",
            Style::default().fg(Color::DarkGray),
        )]));
    }

    let para = Paragraph::new(lines).wrap(Wrap { trim: false });
    f.render_widget(para, inner);
}

fn render_ir(f: &mut ratatui::Frame, app: &App, area: Rect) {
    let block = Block::default()
        .title(" LLVM IR ")
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Magenta));

    let inner = block.inner(area);
    f.render_widget(block, area);

    if inner.height < 1 || inner.width < 4 {
        return;
    }

    let mut lines: Vec<Line> = Vec::new();
    for text_line in app.llvm_ir.lines() {
        // Syntax highlight: keywords in cyan, comments in gray, types in yellow
        let styled = if text_line.trim_start().starts_with(';') {
            Line::from(Span::styled(
                text_line.to_string(),
                Style::default().fg(Color::DarkGray),
            ))
        } else if text_line.contains("define ") || text_line.contains("declare ") {
            Line::from(Span::styled(
                text_line.to_string(),
                Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD),
            ))
        } else if text_line.starts_with('%') || text_line.starts_with('@') {
            Line::from(Span::styled(
                text_line.to_string(),
                Style::default().fg(Color::Yellow),
            ))
        } else if text_line.trim_start().starts_with("ret ") || text_line.trim_start().starts_with("br ") || text_line.trim_start().starts_with("call ") {
            Line::from(Span::styled(
                text_line.to_string(),
                Style::default().fg(Color::Green),
            ))
        } else {
            Line::from(Span::styled(
                text_line.to_string(),
                Style::default().fg(Color::White),
            ))
        };
        lines.push(styled);
    }

    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "(type code to see IR)",
            Style::default().fg(Color::DarkGray),
        )));
    }

    let para = Paragraph::new(lines).wrap(Wrap { trim: false });
    f.render_widget(para, inner);
}

fn render_status(f: &mut ratatui::Frame, app: &App, area: Rect) {
    let var_count = app.state_vars.len();
    let panel_name = match app.right_panel {
        RightPanel::State => "STATE",
        RightPanel::IR => "LLVM IR",
    };

    let status_line = Line::from(vec![
        Span::styled(
            " BLIMP ",
            Style::default()
                .fg(Color::Black)
                .bg(Color::Green)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("  {} vars | Tab: {} | Up/Down: history | Ctrl-C: quit ", var_count, panel_name),
            Style::default().fg(Color::DarkGray),
        ),
    ]);

    let para = Paragraph::new(status_line);
    f.render_widget(para, area);
}

// ---------------------------------------------------------------------------
// Input handling
// ---------------------------------------------------------------------------

fn handle_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            app.running = false;
        }
        KeyCode::Enter => {
            submit_input(app);
        }
        KeyCode::Backspace => {
            if app.cursor > 0 {
                app.input.remove(app.cursor - 1);
                app.cursor -= 1;
            }
        }
        KeyCode::Delete => {
            if app.cursor < app.input.len() {
                app.input.remove(app.cursor);
            }
        }
        KeyCode::Left => {
            if app.cursor > 0 {
                app.cursor -= 1;
            }
        }
        KeyCode::Right => {
            if app.cursor < app.input.len() {
                app.cursor += 1;
            }
        }
        KeyCode::Home => {
            app.cursor = 0;
        }
        KeyCode::End => {
            app.cursor = app.input.len();
        }
        KeyCode::Up => {
            browse_history_up(app);
        }
        KeyCode::Down => {
            browse_history_down(app);
        }
        KeyCode::Tab => {
            // Toggle right panel
            app.right_panel = match app.right_panel {
                RightPanel::State => RightPanel::IR,
                RightPanel::IR => RightPanel::State,
            };
        }
        KeyCode::Char(c) => {
            app.input.insert(app.cursor, c);
            app.cursor += 1;
        }
        _ => {}
    }
}

fn submit_input(app: &mut App) {
    let line = app.input.clone();
    app.input.clear();
    app.cursor = 0;
    app.history_pos = None;

    // Track block depth for multi-line
    let delta = compute_depth_delta(&line);
    app.block_depth += delta;

    if app.block_depth > 0 {
        // Accumulate multi-line, but show each line in history
        app.history.push(HistoryEntry::Input(line.clone()));
        app.multiline_buf.push(line);
        return;
    }

    if !app.multiline_buf.is_empty() {
        // We were in multi-line and depth just returned to 0
        // Show the closing line in history
        app.history.push(HistoryEntry::Input(line.clone()));
        app.multiline_buf.push(line);
        let full_input = app.multiline_buf.join("\n");
        app.multiline_buf.clear();
        app.block_depth = 0;

        // Add full input to command history for up/down browsing
        app.input_history.push(full_input.clone());

        // Send to blimp
        send_to_blimp(app, &full_input);
    } else {
        // Single line
        if app.block_depth < 0 {
            app.block_depth = 0; // Reset if somehow negative
        }

        if !line.is_empty() {
            app.history.push(HistoryEntry::Input(line.clone()));
            app.input_history.push(line.clone());
            send_to_blimp(app, &line);
        }
    }

    // Reset scroll to bottom
    app.scroll_offset = 0;
}

fn send_to_blimp(app: &mut App, input: &str) {
    if let Some(ref mut stdin) = app.child_stdin {
        let _ = writeln!(stdin, "{}", input);
        let _ = stdin.flush();
    }

    // Accumulate source and compile IR in background
    if !app.source_buf.is_empty() {
        app.source_buf.push('\n');
    }
    app.source_buf.push_str(input);

    if let Some(ref bin) = app.compile_bin {
        app.llvm_ir = compile_to_ir(bin, &app.source_buf);
    }
}

fn browse_history_up(app: &mut App) {
    if app.input_history.is_empty() {
        return;
    }
    match app.history_pos {
        None => {
            app.saved_input = app.input.clone();
            let pos = app.input_history.len() - 1;
            app.history_pos = Some(pos);
            app.input = app.input_history[pos].clone();
            app.cursor = app.input.len();
        }
        Some(pos) => {
            if pos > 0 {
                let new_pos = pos - 1;
                app.history_pos = Some(new_pos);
                app.input = app.input_history[new_pos].clone();
                app.cursor = app.input.len();
            }
        }
    }
}

fn browse_history_down(app: &mut App) {
    match app.history_pos {
        None => {}
        Some(pos) => {
            if pos + 1 < app.input_history.len() {
                let new_pos = pos + 1;
                app.history_pos = Some(new_pos);
                app.input = app.input_history[new_pos].clone();
                app.cursor = app.input.len();
            } else {
                app.history_pos = None;
                app.input = app.saved_input.clone();
                app.cursor = app.input.len();
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn main() -> io::Result<()> {
    // Set up channel for blimp output
    let (tx, rx) = mpsc::channel::<String>();

    // Spawn blimp process
    let mut child = match spawn_blimp(tx) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {}", e);
            eprintln!("Make sure the blimp binary is available.");
            std::process::exit(1);
        }
    };

    let child_stdin = child.stdin.take();

    // Set up terminal
    terminal::enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, cursor::Show)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let compile_bin = find_compile_binary();

    let mut app = App {
        input: String::new(),
        cursor: 0,
        history: Vec::new(),
        scroll_offset: 0,
        input_history: Vec::new(),
        history_pos: None,
        saved_input: String::new(),
        state_vars: Vec::new(),
        multiline_buf: Vec::new(),
        block_depth: 0,
        running: true,
        rx,
        child_stdin,
        child: Some(child),
        right_panel: RightPanel::State,
        llvm_ir: String::new(),
        source_buf: String::new(),
        compile_bin,
    };

    // Main event loop
    while app.running {
        // Drain any available blimp output
        loop {
            match app.rx.try_recv() {
                Ok(line) => {
                    parse_output_line(&line, &mut app.state_vars, &mut app.history);
                }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => {
                    // Process died
                    app.history
                        .push(HistoryEntry::Error("blimp process exited".to_string()));
                    break;
                }
            }
        }

        // Render
        render(&mut terminal, &app)?;

        // Poll for keyboard events with a timeout so we can also check process output
        if event::poll(Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                handle_key(&mut app, key);
            }
        }
    }

    // Cleanup
    // Kill child process if still running
    if let Some(ref mut child) = app.child {
        let _ = child.kill();
        let _ = child.wait();
    }

    // Restore terminal
    terminal::disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen, cursor::Show)?;

    Ok(())
}

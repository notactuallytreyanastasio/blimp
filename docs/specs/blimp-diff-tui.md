# blimp diff -- TUI Diff Viewer Specification

Port of term_diff (Phoenix LiveView) to a native Rust TUI using Ratatui,
shipped as `blimp-diff` binary. `blimp diff` dispatches to it (like git
dispatches to git-diff). Replaces `chunks/repl_tui/` entirely.

Language: Rust. Framework: Ratatui + Crossterm. Lives in `chunks/blimp_diff/`.

---

## Spec 1: Data Types (Pure)

Port the domain types from `TermDiff.Git.Types` to Rust structs.

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    Added, Modified, Deleted, Renamed, Untracked, None,
}

#[derive(Debug, Clone)]
pub struct FileEntry {
    pub path: String,
    pub orig_path: Option<String>,  // for renames
    pub staged: Status,
    pub unstaged: Status,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LineKind { Addition, Deletion, Context }

#[derive(Debug, Clone)]
pub struct DiffLine {
    pub kind: LineKind,
    pub content: String,
    pub old_line: Option<u32>,
    pub new_line: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct Hunk {
    pub header: String,
    pub old_start: u32,
    pub old_count: u32,
    pub new_start: u32,
    pub new_count: u32,
    pub lines: Vec<DiffLine>,
    pub collapsed: bool,
    pub highlighted_at: Option<Instant>,  // for hot-follow
}

#[derive(Debug, Clone)]
pub struct FileDiff {
    pub path: String,
    pub hunks: Vec<Hunk>,
    pub binary: bool,
    pub additions: u32,
    pub deletions: u32,
}

#[derive(Debug, Clone)]
pub struct RepoState {
    pub files: Vec<FileEntry>,
    pub diffs: HashMap<String, FileDiff>,  // path -> FileDiff
    pub branch: String,
    pub last_updated: Instant,
}

#[derive(Debug, Clone)]
pub struct LogEntry {
    pub hash: String,
    pub message: String,
}
```

**Test**: construction, equality, edge cases (empty paths, zero-line
hunks, binary files with no hunks).

**Source**: `chunks/term_diff/lib/term_diff/git/types.ex`

---

## Spec 2: Status Parser (Pure)

Parse `git status --porcelain=v1` output into `Vec<FileEntry>`.

**Input**: raw string from git, one line per file, format: `XY path` or
`XY orig -> path` for renames.

**Status code mapping** (two-char XY):
- X = staged status, Y = unstaged status
- `?` = untracked, `M` = modified, `A` = added, `D` = deleted, `R` = renamed
- Space = no change in that column

**Edge cases**:
- Renamed files: `R  old -> new` -- store both paths
- Untracked: `??` -- staged=None, unstaged=Untracked
- Empty output = clean repo, return empty Vec
- Paths with spaces
- Trailing newlines

```rust
pub fn parse_status(input: &str) -> Vec<FileEntry>
```

**Test**: parse real porcelain output strings, verify each status combo,
handle empty input, handle trailing newlines, handle paths with spaces.

**Source**: `chunks/term_diff/lib/term_diff/git/status.ex`

---

## Spec 3: Diff Parser (Pure)

Parse unified diff format (`git diff` output) into `Vec<FileDiff>`.

**Structure**:
```
diff --git a/path b/path
--- a/path
+++ b/path
@@ -old_start,old_count +new_start,new_count @@ optional context
 context line
+addition
-deletion
```

**Steps**:
1. Split on `diff --git` boundaries
2. Extract file path from `+++ b/path` (or `--- a/path` for deletions)
3. Split hunks on `@@` headers
4. Parse hunk header for line numbers
5. Classify each line by prefix: `+`, `-`, or space/empty
6. Track old_line/new_line counters per line type
7. Count additions/deletions per file

**Edge cases**:
- Binary files: `Binary files ... differ` -- set binary=true, no hunks
- New files: `--- /dev/null`
- Deleted files: `+++ /dev/null`
- No newline at end: `\ No newline at end of file`
- Empty diff sections

```rust
pub fn parse_diff(input: &str) -> Vec<FileDiff>
```

**Test**: parse real diffs with multiple files, binary files, new/deleted
files, hunks with mixed add/delete/context. Verify line numbers are correct.

**Source**: `chunks/term_diff/lib/term_diff/git/diff.ex`

---

## Spec 4: Log Parser (Pure)

Parse `git log --oneline -50` output into `Vec<LogEntry>`.

**Format**: `<hash> <message>\n` per line, hash is 7+ chars.

```rust
pub fn parse_log(input: &str) -> Vec<LogEntry>
```

**Test**: parse multi-line output, empty output, single entry.

**Source**: `chunks/term_diff/lib/term_diff/git/log.ex`

---

## Spec 5: File State Machine (Pure)

Models git staging lifecycle per file. Given a FileEntry, determines what
git command to run for stage/unstage.

**States** (derived from staged + unstaged status combo):
```rust
pub enum FileState {
    Untracked,
    StagedNew,
    UnstagedModified,
    StagedModified,
    PartialModified,    // staged AND unstaged modifications
    UnstagedDeleted,
    StagedDeleted,
    StagedRenamed,
}

pub enum GitCommand {
    Add(String),
    RmCached(String),
    RestoreStaged(String),
}
```

**Functions**:
```rust
pub fn classify(entry: &FileEntry) -> FileState
pub fn stage_command(state: &FileState, path: &str) -> Option<GitCommand>
pub fn unstage_command(state: &FileState, path: &str) -> Option<GitCommand>
```

**Test**: every state produces correct command, None for no-op states.

**Source**: `chunks/term_diff/lib/term_diff/diff/file_state.ex`

---

## Spec 6: Commit State Machine (Pure)

Models the commit flow: idle -> editing -> submitting -> idle/error.

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phase { Idle, Editing, Submitting, Error }

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommitMode { Commit, Amend }

#[derive(Debug, Clone)]
pub struct CommitState {
    pub phase: Phase,
    pub mode: CommitMode,
    pub message: String,
    pub error_message: Option<String>,
}
```

**Transitions**:
```rust
impl CommitState {
    pub fn enter(mode: CommitMode, staged_count: usize) -> Result<Self, &'static str>
    pub fn update_message(&mut self, msg: String)
    pub fn submit(&mut self) -> Result<(), &'static str>  // validates non-empty
    pub fn complete(&mut self)    // back to idle
    pub fn fail(&mut self, error: String)
    pub fn cancel(&mut self)     // back to idle
    pub fn is_active(&self) -> bool
}
```

**Test**: full flow for commit and amend, error recovery, cancel from
each state, edge case of empty message rejection.

**Source**: `chunks/term_diff/lib/term_diff/diff/commit_state.ex`

---

## Spec 7: Navigation State Machine (Pure)

The keyboard-driven navigation state machine. The brain of the TUI.

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Focus { FileList, DiffView, LogView, LogDetail }

#[derive(Debug, Clone)]
pub struct Navigation {
    pub focus: Focus,
    pub file_index: usize,
    pub file_count: usize,
    pub hunk_index: usize,
    pub hunk_count: usize,
    pub log_index: usize,
    pub log_count: usize,
    pub selected_file: Option<String>,
    pub selected_commit: Option<String>,
    pub expanded_hunks: HashSet<usize>,
    pub following: bool,

    // Signals -- consumed by the event loop after each key
    pub open_file: Option<String>,
    pub stage_file: Option<String>,
    pub unstage_file: Option<String>,
    pub enter_commit: Option<CommitMode>,

    // Chord state
    last_c_time: Option<Instant>,
}

pub enum NavKey {
    J, K, Enter, Q, Tab, F, L, O, S, U, C, A, Escape,
    V,       // visual mode (line selection)
    Other,
}
```

**Key mappings** (returns mutated self with signals set):
```
j/k       -- move down/up within current focus
Enter     -- select (expand hunk in diff_view, enter diff from file_list)
q         -- go back one level (diff->files, log_detail->log, etc.)
Tab       -- toggle file_list <-> diff_view
F         -- toggle follow mode
l         -- toggle log view
o         -- set open_file signal (caller opens editor)
s         -- set stage_file signal
u         -- set unstage_file signal
cc        -- enter commit mode (two-key chord, 400ms window)
a         -- enter amend mode
v         -- enter visual selection mode
```

**Sync functions**:
```rust
pub fn sync_to_files(&mut self, paths: &[String])
pub fn follow_to_latest(&mut self, latest_file: &str, hunk_count: usize)
pub fn handle_key(&mut self, key: NavKey)
pub fn clear_signals(&mut self)  // called after event loop consumes them
```

**Chord detection**: `cc` requires two `c` presses within 400ms. Track
`last_c_time: Option<Instant>`. If second `c` arrives within window,
set enter_commit signal. Otherwise treat as single `c` (no-op).

**Test**: every key in every focus mode, boundary conditions (first/last
item), chord timing, sync_to_files with added/removed files, follow mode
transitions.

**Source**: `chunks/term_diff/lib/term_diff/diff/navigation.ex`

---

## Spec 8: Line Selection (Pure)

State for selecting a range of diff lines (for agent prompts).

```rust
#[derive(Debug, Clone, Default)]
pub struct LineSelection {
    pub file: Option<String>,
    pub anchor: Option<u32>,    // where selection started
    pub cursor: Option<u32>,    // where selection currently extends to
    pub active: bool,           // in visual mode?
}
```

**Functions**:
```rust
impl LineSelection {
    pub fn start(&mut self, file: &str, line: u32)
    pub fn extend(&mut self, line: u32)
    pub fn clear(&mut self)
    pub fn selected_range(&self) -> Option<(u32, u32)>  // normalized
    pub fn contains(&self, line: u32) -> bool
}
```

In the TUI, selection is keyboard-driven:
- `v` in diff_view starts selection at current line
- `j/k` extends while in visual mode
- `Enter` confirms selection, prompts for comment
- `Escape` cancels

**Test**: start/extend/clear, range normalization, multi-file clears
previous selection.

**Source**: `chunks/term_diff/lib/term_diff/diff/line_selection.ex`

---

## Spec 9: Git Runner (Imperative)

Execute git commands as child processes. Port of `TermDiff.Git.Runner`.

```rust
pub struct GitRunner {
    repo_path: PathBuf,
}

impl GitRunner {
    pub fn new(repo_path: PathBuf) -> Self;
    pub fn status(&self) -> Result<String>;
    pub fn diff(&self) -> Result<String>;
    pub fn diff_staged(&self) -> Result<String>;
    pub fn diff_untracked(&self, file: &str) -> Result<String>;
    pub fn branch(&self) -> Result<String>;
    pub fn log_oneline(&self) -> Result<String>;
    pub fn log_show(&self, hash: &str) -> Result<String>;
    pub fn log_diff(&self, hash: &str) -> Result<String>;
    pub fn stage(&self, path: &str) -> Result<()>;
    pub fn unstage(&self, path: &str) -> Result<()>;
    pub fn commit(&self, message: &str) -> Result<()>;
    pub fn commit_amend(&self, message: &str) -> Result<()>;
    pub fn open_editor(&self, file: &str) -> Result<()>;
}
```

**Implementation**: `std::process::Command` with stdout/stderr piped.
15-second timeout per command. Use `wait_with_output()`.

**Test**: integration tests against a temp git repo (init, add files,
commit, verify parser output matches runner output).

**Source**: `chunks/term_diff/lib/term_diff/git/runner.ex`

---

## Spec 10: File Watcher (Imperative)

Watch the repository for changes. Port of `TermDiff.Git.Watcher`.

**Crate**: `notify` (mature, cross-platform file watching for Rust).

**Watch targets**:
- Working tree (recursive)
- `.git/index`
- `.git/refs/` (recursive)
- `.git/HEAD`

**Interface**:
```rust
pub struct RepoWatcher {
    // internal: notify::RecommendedWatcher
}

impl RepoWatcher {
    pub fn new(repo_path: PathBuf, sender: mpsc::Sender<WatchEvent>) -> Result<Self>;
    pub fn stop(self);
}

pub enum WatchEvent {
    RepoChanged,
}
```

**Behavior**:
- Debounce: coalesce events within 200ms window (notify has built-in debounce)
- On change: send `WatchEvent::RepoChanged` on the channel
- Main event loop polls the channel alongside Crossterm events

**Test**: create temp repo, modify a file, verify watcher fires within
reasonable time. Test debouncing (rapid writes produce single event).

**Source**: `chunks/term_diff/lib/term_diff/git/watcher.ex`

---

## Spec 11: TUI Layout (Ratatui)

The terminal rendering layer. Replaces Phoenix templates + JS hooks.

**Layout modes**:

### Default (Diff View)
```
+--[ file list ]--------+--[ diff view ]---------------------------+
| M src/main.zig     +3 |  @@ -10,6 +10,8 @@ fn main()            |
| A src/new.zig      +50|   context line                           |
|>M src/parser.zig   +1 |  +added line                            |
|   (selected, blue)     |  -removed line                          |
|                        |   context line                          |
| [green border=focus]   |  [green border=focus]                   |
+------------------------+------------------------------------------+
| status bar: branch | files: 3 | follow: ON | q:back Tab:switch   |
+-------------------------------------------------------------------+
```

Ratatui widgets:
- `Layout::horizontal` with `Constraint::Length(30)` + `Constraint::Min(0)`
- Left pane: `List` widget with styled `ListItem`s
- Right pane: custom widget or `Paragraph` with styled `Line`/`Span`s
- Status bar: `Layout::vertical` bottom row, `Paragraph`
- Borders: `Block::bordered()` with conditional `.border_style(Color::Green)`

### Log View
```
+--[ log ]--------------------+--[ commit detail ]------------------+
| > a1b2c3d fix: parser bug  | commit a1b2c3d                     |
|   e4f5g6h feat: add actors | Author: ...                        |
|   h7i8j9k refactor: types  | Date: ...                          |
+-----------------------------+-------------------------------------+
```

### Commit Mode (overlay -- Ratatui `Clear` + centered `Block`)
```
+--[ commit message ]------------------------------------------+
| feat: add new parser                                         |
|                                                              |
| ~ Enter to submit, Esc to cancel ~                           |
+--------------------------------------------------------------+
```

### Agent Prompt (overlay)
```
+--[ selected lines ]------------------------------------------+
|  +added line                                                 |
|  +another added line                                         |
+--------------------------------------------------------------+
| Your comment: _                                              |
| ~ Enter to send to Claude, Esc to cancel ~                   |
+--------------------------------------------------------------+
```

**Colors**:
- Additions: `Color::Green`
- Deletions: `Color::Red`
- Context: `Color::Reset`
- Hunk headers: `Color::Blue` bg
- Selected hunk: `Color::LightBlue` bg
- Hot-follow hunk: `Color::Yellow` bg
- Staged badge: `Color::Green` "S"
- Status icons: M=`Color::Yellow`, A=`Color::Green`, D=`Color::Red`, R=`Color::Cyan`
- Selected lines (visual mode): `Color::Blue` bg

**Scrolling**:
- Each pane tracks scroll offset independently
- `ListState` for file list (Ratatui built-in scroll)
- Manual scroll offset for diff pane (keep selected hunk visible)
- Follow mode: auto-scroll to hot hunk on refresh

---

## Spec 12: Main Event Loop

The TUI application lifecycle. Integrates Ratatui rendering with
file watching and user input.

**Startup**:
1. Parse args: `blimp-diff [path] [--follow] [--no-review]`
2. Verify path is a git repo (check for `.git/`)
3. Initialize Crossterm raw mode + alternate screen
4. Create Ratatui Terminal
5. Start file watcher on repo (spawns thread, sends on channel)
6. Initial refresh: run git commands, parse into RepoState
7. Initialize Navigation from RepoState
8. Enter event loop

**Event loop** (single-threaded with channel polling):
```rust
loop {
    // Draw
    terminal.draw(|frame| ui::render(frame, &app_state))?;

    // Poll for events (100ms timeout for responsiveness)
    if crossterm::event::poll(Duration::from_millis(100))? {
        match crossterm::event::read()? {
            Event::Key(key) => handle_key(&mut app, key),
            Event::Resize(..) => {},  // Ratatui handles this
            _ => {}
        }
    }

    // Check watcher channel (non-blocking)
    if let Ok(WatchEvent::RepoChanged) = watcher_rx.try_recv() {
        app.refresh()?;
    }

    // Check agent completion channel (non-blocking)
    while let Ok(agent_event) = agent_rx.try_recv() {
        app.handle_agent_event(agent_event);
    }

    // Process signals from navigation
    app.process_signals()?;

    if app.should_quit { break; }
}
```

**Refresh cycle**:
1. `GitRunner::status()` + parse
2. `GitRunner::diff()` + `diff_staged()` + parse
3. For untracked files: `diff_untracked()` + parse
4. `GitRunner::branch()`
5. Build new RepoState
6. `nav.sync_to_files(new_paths)`
7. If following: `nav.follow_to_latest()`
8. Update selected_diff
9. (Next loop iteration redraws)

**Shutdown**: `q` from top level or Ctrl+C. Restore terminal, stop watcher,
kill agent children.

---

## Spec 13: Claude Integration

Shell out to `claude` CLI for two features: line-level agent dispatch
and background code review.

### Agent Dispatch (user-initiated)
1. User selects lines via visual mode (Spec 8) and writes a comment
2. Build prompt:
   ```
   File: {path}
   Lines {start}-{end}:
   ```{lang}
   {selected lines}
   ```

   {user comment}
   ```
3. Spawn `claude -p "{prompt}" --allowedTools "Read,Grep,Glob,Bash(git:*)"
   --output-format json` as child process
4. Track in agent multiplexer (Spec 14)
5. Reader thread collects stdout, sends completion on channel
6. Display result in overlay panel

### Background Review (automatic, like Commentary)
- On each refresh, if diff changed (hash with sha2 crate), optionally
  request review
- Same claude CLI call with a review-focused system prompt
- Parse JSON annotations (file, line, comment, severity)
- Display inline in diff view as gutter markers

```rust
pub struct Claude {
    allowed_tools: String,
}

impl Claude {
    pub fn dispatch(&self, prompt: &str) -> Result<std::process::Child>;
    pub fn spawn_review(&self, diff: &str, repo_path: &Path) -> Result<std::process::Child>;
}
```

**Threading**: spawn child in a std::thread, read stdout to completion,
send result on `mpsc::Sender<AgentEvent>`. Main loop picks it up.

---

## Spec 14: Agent Multiplexer

Port of `TermDiff.Agent.Orchestrator`. Manages concurrent Claude sessions.

```rust
pub struct Multiplexer {
    active: Vec<AgentRun>,
    queue: VecDeque<AgentRun>,
    max_concurrent: usize,  // default 5
    next_id: u64,
    result_tx: mpsc::Sender<AgentEvent>,
}

pub struct AgentRun {
    pub id: u64,
    pub prompt: String,
    pub status: RunStatus,
    pub started_at: Option<Instant>,
    pub last_activity: Instant,
    pub child: Option<Child>,
    pub result: Option<String>,
    pub retries: u8,
}

pub enum RunStatus { Queued, Running, Completed, Failed, Stalled }

pub enum AgentEvent {
    Completed { id: u64, result: String },
    Failed { id: u64, error: String },
}
```

**Methods**:
```rust
impl Multiplexer {
    pub fn dispatch(&mut self, prompt: String) -> u64;
    pub fn handle_event(&mut self, event: AgentEvent);
    pub fn check_stalled(&mut self);  // called periodically from event loop
    pub fn cancel(&mut self, id: u64);
    pub fn active_count(&self) -> usize;
    pub fn queued_count(&self) -> usize;
}
```

**Stall detection**: runs idle > 300s get killed and retried (max 3 retries).
Check on every event loop iteration (cheap: just compare Instants).

---

## Spec 15: Subcommand Dispatch

`blimp diff` in the Zig CLI execs `blimp-diff`, passing remaining args.

**In main.zig**, add to subcommand dispatch:
```zig
"diff" => {
    const argv = // remaining args
    return std.process.execv("blimp-diff", argv);
}
```

Or simpler: just `std.process.Child` that execs `blimp-diff` and waits.

The Rust binary is built separately and placed on PATH (or next to blimp).

**Arguments for blimp-diff**:
```
blimp-diff [path]        -- open diff viewer on path (default: cwd)
blimp-diff --follow      -- start in follow mode
blimp-diff --no-review   -- disable background Claude review
```

Use `clap` for arg parsing.

---

## Spec 16: Project Setup and Build

### Cargo project: `chunks/blimp_diff/`

```toml
[package]
name = "blimp-diff"
version = "0.1.0"
edition = "2021"

[dependencies]
ratatui = "0.29"
crossterm = "0.28"
notify = "7"          # file watching
clap = { version = "4", features = ["derive"] }
sha2 = "0.10"         # diff hashing for review dedup
serde = { version = "1", features = ["derive"] }
serde_json = "1"       # parse Claude JSON output
```

### File organization:
```
chunks/blimp_diff/
  Cargo.toml
  src/
    main.rs              -- arg parsing, terminal setup, event loop (Spec 12+15)
    types.rs             -- Spec 1: data types
    git/
      mod.rs
      status.rs          -- Spec 2: status parser
      diff.rs            -- Spec 3: diff parser
      log.rs             -- Spec 4: log parser
      runner.rs          -- Spec 9: git runner
      watcher.rs         -- Spec 10: file watcher
    state/
      mod.rs
      file_state.rs      -- Spec 5: file state machine
      commit.rs          -- Spec 6: commit state machine
      navigation.rs      -- Spec 7: navigation state machine
      selection.rs       -- Spec 8: line selection
    ui/
      mod.rs             -- Spec 11: layout dispatch
      file_list.rs       -- file list pane widget
      diff_pane.rs       -- diff view pane widget
      log_view.rs        -- log view widget
      overlays.rs        -- commit + agent prompt overlays
      status_bar.rs      -- bottom status bar
    agent/
      mod.rs
      claude.rs          -- Spec 13: Claude CLI integration
      multiplexer.rs     -- Spec 14: agent multiplexer
```

### Update `/build-test` command to handle both:
- `chunks/blimp_diff/`: `cargo test`, `cargo clippy`
- `chunks/lang/`: `zig build test`
- `chunks/term_diff/`: `mix compile --warnings-as-errors && mix test && mix credo --strict`

### Update top-level Makefile:
```makefile
DIFF_DIR = chunks/blimp_diff

diff: ## Launch the TUI diff viewer
	cd $(DIFF_DIR) && cargo run -- .

diff-build: ## Build the diff viewer
	cd $(DIFF_DIR) && cargo build --release
```

---

## Implementation Order

1. **Project setup** (Spec 16) -- cargo init, dependencies, file structure
2. **Types** (Spec 1) -- foundation
3. **Parsers** (Specs 2-4) -- pure, testable, no dependencies
4. **State machines** (Specs 5-8) -- pure, testable, depend on types
5. **Git runner** (Spec 9) -- first imperative piece
6. **File watcher** (Spec 10) -- needs notify crate
7. **TUI layout** (Spec 11) -- Ratatui widgets, static rendering first
8. **Event loop** (Spec 12) -- ties everything together into a running app
9. **Claude integration** (Spec 13) -- needs event loop for async completion
10. **Multiplexer** (Spec 14) -- needs Claude integration
11. **Subcommand dispatch** (Spec 15) -- wire blimp -> blimp-diff

Each spec is independently testable. Specs 1-8 are pure Rust with zero
I/O -- #[cfg(test)] modules with unit tests. Spec 9 needs integration
tests with a temp git repo.

---

## What Gets Deleted

- `chunks/repl_tui/` -- entire old Rust TUI (was for REPL, not diff)
- Phoenix app stays for now (reference implementation during port)
- After port is validated, Phoenix app can be archived or removed

## What Stays

- `chunks/term_diff/` -- reference implementation, read-only during port
- `chunks/lang/` -- Zig compiler, untouched except Spec 15 (add "diff" dispatch)

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Instant;

use crate::git::runner::GitRunner;
use crate::git::status::parse_status;
use crate::git::diff::parse_diff;
use crate::git::log::parse_log;
use crate::state::commit::CommitState;
use crate::state::interaction::{Interaction, Mode, Action};
use crate::state::navigation::{Navigation, NavKey, Focus};
use crate::state::selection::LineSelection;
use crate::types::{FileDiff, LogEntry, RepoState};
use crate::ui::theme::{Theme, ThemeName};
use crate::ui::highlight::Highlighter;
use crate::ui::diff_pane::DiffCache;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputMode {
    Normal,
    CommitMessage,
    AgentPrompt,
}

pub struct App {
    pub repo_path: PathBuf,
    pub runner: GitRunner,
    pub ix: Interaction,
    pub nav: Navigation,
    pub commit: CommitState,
    pub selection: LineSelection,
    pub repo_state: Option<RepoState>,
    pub selected_diff: Option<FileDiff>,
    pub log_entries: Vec<LogEntry>,
    pub input_mode: InputMode,  // TODO: remove once ix is fully wired
    pub input_buffer: String,
    pub input_cursor: usize,
    pub should_quit: bool,
    pub needs_redraw: bool,
    pub status_message: Option<String>,
    pub diff_scroll: usize,
    pub diff_hscroll: usize,
    pub file_list_scroll: usize,
    pub theme_name: ThemeName,
    pub theme: Theme,
    pub pane_width: u16,
    pub terminal_height: u16,
    pub highlighter: Highlighter,
    pub diff_cache: DiffCache,
}

impl App {
    pub fn new(repo_path: PathBuf) -> Self {
        let runner = GitRunner::new(repo_path.clone());
        Self {
            repo_path,
            runner,
            ix: Interaction::new(),
            nav: Navigation::new(),
            commit: CommitState::idle(),
            selection: LineSelection::new(),
            repo_state: None,
            selected_diff: None,
            log_entries: vec![],
            input_mode: InputMode::Normal,
            input_buffer: String::new(),
            input_cursor: 0,
            should_quit: false,
            needs_redraw: true,
            status_message: None,
            diff_scroll: 0,
            diff_hscroll: 0,
            file_list_scroll: 0,
            theme_name: ThemeName::SolarizedDark,
            theme: ThemeName::SolarizedDark.theme(),
            pane_width: 30,
            terminal_height: 24,
            highlighter: Highlighter::new(),
            diff_cache: DiffCache::empty(),
        }
    }

    pub fn refresh(&mut self) {
        let status_output = match self.runner.status() {
            Ok(s) => s,
            Err(e) => {
                self.status_message = Some(format!("git status failed: {}", e));
                return;
            }
        };

        let diff_output = self.runner.diff().unwrap_or_default();
        let staged_output = self.runner.diff_staged().unwrap_or_default();
        let branch = self.runner.branch().unwrap_or_else(|_| "unknown".into());

        let files: Vec<_> = parse_status(&status_output)
            .into_iter()
            .filter(|f| !should_ignore(&f.path))
            .collect();
        let mut unstaged_diffs = parse_diff(&diff_output);
        let staged_diffs = parse_diff(&staged_output);

        // Merge staged and unstaged diffs into one map
        let mut diff_map: HashMap<String, FileDiff> = HashMap::new();
        for d in unstaged_diffs.drain(..) {
            diff_map.insert(d.path.clone(), d);
        }
        for d in staged_diffs {
            diff_map
                .entry(d.path.clone())
                .and_modify(|existing| {
                    // Merge: append staged hunks
                    existing.hunks.extend(d.hunks.clone());
                    existing.additions += d.additions;
                    existing.deletions += d.deletions;
                })
                .or_insert(d);
        }

        // Fetch diff for selected untracked file only (lazy -- avoids O(n) spawns)
        if let Some(ref selected) = self.nav.selected_file {
            if let Some(file) = files.iter().find(|f| &f.path == selected) {
                if file.unstaged == crate::types::Status::Untracked && !diff_map.contains_key(&file.path) {
                    let abs_path = self.repo_path.join(&file.path);
                    if let Ok(output) = self.runner.diff_untracked(abs_path.to_str().unwrap_or("")) {
                        let mut diffs = parse_diff(&output);
                        if let Some(mut d) = diffs.pop() {
                            d.path = file.path.clone();
                            diff_map.insert(file.path.clone(), d);
                        }
                    }
                }
            }
        }

        let paths: Vec<String> = files.iter().map(|f| f.path.clone()).collect();
        self.nav.sync_to_files(&paths);

        // Follow mode
        if self.nav.following {
            if let Some(latest) = find_latest_modified(&files, &diff_map, &self.repo_path) {
                let hunk_count = diff_map
                    .get(&latest)
                    .map(|d| d.hunks.len())
                    .unwrap_or(0);
                self.nav.follow_to_latest(&latest, hunk_count);
                self.ix.enter(crate::state::interaction::Mode::DiffView);
                self.nav.focus = Focus::DiffView;
            }
        }

        // Update selected diff
        self.selected_diff = self
            .nav
            .selected_file
            .as_ref()
            .and_then(|f| diff_map.get(f))
            .cloned();

        // Update hunk count from selected diff
        if let Some(ref diff) = self.selected_diff {
            self.nav.hunk_count = diff.hunks.len();
        } else {
            self.nav.hunk_count = 0;
        }

        self.repo_state = Some(RepoState {
            files,
            diffs: diff_map,
            branch,
            last_updated: Instant::now(),
        });

        // Rebuild diff cache for current file (heavy -- runs syntax highlighting)
        self.rebuild_diff_cache();

        // Follow mode: scroll to end of diff
        if self.nav.following && self.diff_cache.total > 0 {
            let vp = self.viewport_height();
            self.diff_scroll = self.diff_cache.total.saturating_sub(vp);
        }

        self.status_message = None;
        self.needs_redraw = true;
    }

    pub fn refresh_log(&mut self) {
        if let Ok(output) = self.runner.log_oneline() {
            self.log_entries = parse_log(&output);
            self.nav.log_count = self.log_entries.len();
        }
    }

    pub fn handle_nav_key(&mut self, key: NavKey) {
        let old_focus = self.nav.focus;
        let old_file = self.nav.selected_file.clone();

        self.nav.handle_key(key);

        // Process signals
        self.process_signals();

        // If focus changed to/from log, refresh log
        if self.nav.focus == Focus::LogView && old_focus != Focus::LogView {
            self.refresh_log();
        }

        // Only update selected diff when the file actually changed
        if self.nav.selected_file != old_file {
            self.update_selected_diff();
        }

        // Reset scroll when entering diff view or switching files
        if self.nav.focus == Focus::DiffView && old_focus == Focus::FileList {
            self.diff_scroll = 0;
            self.diff_hscroll = 0;
        }
        if self.nav.selected_file != old_file {
            self.diff_hscroll = 0;
        }

        self.needs_redraw = true;
    }

    /// Visible lines in the diff pane (terminal height minus borders and status bar).
    pub fn viewport_height(&self) -> usize {
        self.terminal_height.saturating_sub(3) as usize
    }

    /// Lightweight update: just sync hunk count. No cloning, no highlighting.
    /// Called on every file list navigation (j/k).
    pub fn update_selected_diff(&mut self) {
        if let Some(ref repo) = self.repo_state {
            let hunk_count = self
                .nav
                .selected_file
                .as_ref()
                .and_then(|f| repo.diffs.get(f))
                .map(|d| d.hunks.len())
                .unwrap_or(0);
            self.nav.hunk_count = hunk_count;
        }
    }

    /// Heavy update: rebuild the diff cache with syntax highlighting.
    /// Called only when entering diff view or on refresh.
    pub fn rebuild_diff_cache(&mut self) {
        if let Some(ref repo) = self.repo_state {
            let diff = self
                .nav
                .selected_file
                .as_ref()
                .and_then(|f| repo.diffs.get(f));

            if let Some(diff) = diff {
                self.nav.hunk_count = diff.hunks.len();
                if self.diff_cache.file_path != diff.path {
                    self.diff_cache = DiffCache::rebuild(diff, &self.theme, &self.highlighter);
                }
                self.selected_diff = Some(diff.clone());
            } else {
                self.nav.hunk_count = 0;
                self.diff_cache = DiffCache::empty();
                self.selected_diff = None;
            }
        }
    }

    fn process_signals(&mut self) {
        // Stage
        if let Some(ref path) = self.nav.stage_file.clone() {
            if let Err(e) = self.runner.stage(path) {
                self.status_message = Some(format!("stage failed: {}", e));
            } else {
                self.refresh();
            }
        }

        // Unstage
        if let Some(ref path) = self.nav.unstage_file.clone() {
            use crate::state::file_state::{classify, unstage_command};
            if let Some(ref repo) = self.repo_state {
                if let Some(entry) = repo.files.iter().find(|f| &f.path == path) {
                    let state = classify(entry);
                    if let Some(cmd) = unstage_command(state, path) {
                        if let Err(e) = self.runner.exec_git_command(&cmd) {
                            self.status_message = Some(format!("unstage failed: {}", e));
                        } else {
                            self.refresh();
                        }
                    }
                }
            }
        }

        // Open editor
        if let Some(ref path) = self.nav.open_file.clone() {
            let _ = self.runner.open_editor(path);
        }

        // Enter commit mode
        if let Some(mode) = self.nav.enter_commit {
            let staged_count = self
                .repo_state
                .as_ref()
                .map(|r| {
                    r.files
                        .iter()
                        .filter(|f| f.staged != crate::types::Status::None)
                        .count()
                })
                .unwrap_or(0);

            match CommitState::enter(mode, staged_count) {
                Ok(state) => {
                    self.commit = state;
                    self.input_mode = InputMode::CommitMessage;
                    self.input_buffer.clear();
                    self.input_cursor = 0;
                }
                Err(e) => {
                    self.status_message = Some(e.to_string());
                }
            }
        }

        // Visual mode
        if self.nav.enter_visual {
            if let Some(ref file) = self.nav.selected_file {
                // Start selection at current hunk's first line
                self.selection.start(file, self.nav.hunk_index as u32);
                self.input_mode = InputMode::Normal; // stays normal, visual overlay
            }
        }

        self.nav.clear_signals();
    }

    pub fn submit_commit(&mut self) {
        self.commit.update_message(self.input_buffer.clone());
        match self.commit.submit() {
            Ok(()) => {
                let msg = self.commit.message.clone();
                let result = match self.commit.mode {
                    crate::state::commit::CommitMode::Commit => self.runner.commit(&msg),
                    crate::state::commit::CommitMode::Amend => self.runner.commit_amend(&msg),
                };
                match result {
                    Ok(()) => {
                        self.commit.complete();
                        self.input_mode = InputMode::Normal;
                        self.input_buffer.clear();
                        self.refresh();
                    }
                    Err(e) => {
                        self.commit.fail(format!("{}", e));
                        self.status_message = Some(format!("commit failed: {}", e));
                    }
                }
            }
            Err(e) => {
                self.status_message = Some(e.to_string());
            }
        }
    }

    pub fn cancel_input(&mut self) {
        self.input_mode = InputMode::Normal;
        self.input_buffer.clear();
        self.input_cursor = 0;
        if self.commit.is_active() {
            self.commit.cancel();
        }
        self.selection.clear();
    }

    pub fn insert_char(&mut self, c: char) {
        self.input_buffer.insert(self.input_cursor, c);
        self.input_cursor += 1;
    }

    /// Central input dispatch. Maps an Action to effects based on current mode.
    pub fn dispatch(&mut self, action: Action) {
        match self.ix.mode {
            Mode::FileList => self.dispatch_file_list(action),
            Mode::DiffView => self.dispatch_diff_view(action),
            Mode::LogList => self.dispatch_log_list(action),
            Mode::LogDetail => self.dispatch_log_detail(action),
            Mode::Selecting => self.dispatch_selecting(action),
            Mode::Committing { .. } => self.dispatch_text_input(action),
            Mode::AgentPrompt => self.dispatch_text_input(action),
            Mode::Dragging => self.dispatch_dragging(action),
        }
    }

    fn dispatch_file_list(&mut self, action: Action) {
        self.ix.clear_chord();
        match action {
            Action::Down => {
                if self.nav.file_count > 0 && self.nav.file_index < self.nav.file_count - 1 {
                    self.nav.file_index += 1;
                    self.nav.update_selected_file();
                    self.update_selected_diff();
                }
            }
            Action::Up => {
                self.nav.file_index = self.nav.file_index.saturating_sub(1);
                self.nav.update_selected_file();
                self.update_selected_diff();
            }
            Action::Select => {
                if self.nav.file_count > 0 {
                    self.rebuild_diff_cache(); // heavy -- only on Enter
                    self.ix.enter(Mode::DiffView);
                    self.nav.focus = Focus::DiffView;
                    self.nav.hunk_index = 0;
                    self.diff_scroll = 0;
                    self.diff_hscroll = 0;
                }
            }
            Action::Back | Action::Quit => {
                self.should_quit = true;
                return;
            }
            Action::TogglePane => {
                self.rebuild_diff_cache();
                self.ix.enter(Mode::DiffView);
                self.nav.focus = Focus::DiffView;
            }
            Action::ToggleFollow => self.nav.following = !self.nav.following,
            Action::ToggleLog => {
                self.ix.enter(Mode::LogList);
                self.nav.focus = Focus::LogView;
                self.refresh_log();
            }
            Action::OpenEditor => {
                if let Some(ref f) = self.nav.selected_file {
                    let _ = self.runner.open_editor(f);
                }
            }
            Action::StageFile => {
                if let Some(path) = self.nav.selected_file.clone() {
                    if let Err(e) = self.runner.stage(&path) {
                        self.status_message = Some(format!("stage failed: {}", e));
                    } else {
                        self.refresh();
                    }
                }
            }
            Action::UnstageFile => self.do_unstage(),
            Action::CommitChord => {
                if let Some(mode) = self.ix.press_c() {
                    self.start_commit(mode);
                }
                return; // don't clear chord
            }
            Action::StartAmend => self.start_commit(crate::state::commit::CommitMode::Amend),
            Action::CycleTheme => self.cycle_theme_internal(),
            Action::ClickFileList(idx) => {
                if idx < self.nav.file_count {
                    self.nav.file_index = idx;
                    self.nav.selected_file = self.nav.file_paths.get(idx).cloned();
                    self.update_selected_diff();
                }
            }
            Action::ClickDiffPane => {
                self.rebuild_diff_cache();
                self.ix.enter(Mode::DiffView);
                self.nav.focus = Focus::DiffView;
            }
            Action::DragDivider(x) => {
                if x >= 15 && x <= 80 {
                    self.pane_width = x;
                }
            }
            Action::ScrollUp => {
                let old = self.nav.file_index;
                self.nav.file_index = self.nav.file_index.saturating_sub(1);
                if self.nav.file_index != old {
                    self.nav.update_selected_file();
                    self.update_selected_diff();
                }
            }
            Action::ScrollDown => {
                let old = self.nav.file_index;
                if self.nav.file_count > 0 && self.nav.file_index < self.nav.file_count - 1 {
                    self.nav.file_index += 1;
                }
                if self.nav.file_index != old {
                    self.nav.update_selected_file();
                    self.update_selected_diff();
                }
            }
            Action::ScrollDiffUp => {
                self.diff_scroll = self.diff_scroll.saturating_sub(3);
            }
            Action::ScrollDiffDown => {
                self.diff_scroll += 3;
            }
            _ => return,
        }
        self.needs_redraw = true;
    }

    fn dispatch_diff_view(&mut self, action: Action) {
        self.ix.clear_chord();
        match action {
            Action::Down => {
                self.diff_scroll += 1;
            }
            Action::Up => {
                self.diff_scroll = self.diff_scroll.saturating_sub(1);
            }
            Action::Select => {
                // Next hunk
                if self.nav.hunk_count > 0 && self.nav.hunk_index < self.nav.hunk_count - 1 {
                    self.nav.hunk_index += 1;
                    // TODO: scroll to hunk position
                }
            }
            Action::Back => {
                self.ix.back();
                self.nav.focus = Focus::FileList;
            }
            Action::TogglePane => {
                self.ix.enter(Mode::FileList);
                self.nav.focus = Focus::FileList;
            }
            Action::ScrollLeft => {
                self.diff_hscroll = self.diff_hscroll.saturating_sub(4);
            }
            Action::ScrollRight => {
                self.diff_hscroll += 4;
            }
            Action::ScrollHome => {
                self.diff_hscroll = 0;
            }
            Action::PageDown => {
                let page = self.viewport_height();
                self.diff_scroll += page;
            }
            Action::PageUp => {
                let page = self.viewport_height();
                self.diff_scroll = self.diff_scroll.saturating_sub(page);
            }
            Action::ScrollUp | Action::ScrollDiffUp => {
                self.diff_scroll = self.diff_scroll.saturating_sub(3);
            }
            Action::ScrollDown | Action::ScrollDiffDown => {
                self.diff_scroll += 3;
            }
            Action::ToggleFollow => self.nav.following = !self.nav.following,
            Action::StartVisual => {
                if let Some(ref file) = self.nav.selected_file {
                    self.selection.start(file, self.nav.hunk_index as u32);
                    self.ix.enter(Mode::Selecting);
                }
            }
            Action::OpenEditor => {
                if let Some(ref f) = self.nav.selected_file {
                    let _ = self.runner.open_editor(f);
                }
            }
            Action::StageFile => {
                if let Some(path) = self.nav.selected_file.clone() {
                    if let Err(e) = self.runner.stage(&path) {
                        self.status_message = Some(format!("stage failed: {}", e));
                    } else {
                        self.refresh();
                    }
                }
            }
            Action::UnstageFile => self.do_unstage(),
            Action::CommitChord => {
                if let Some(mode) = self.ix.press_c() {
                    self.start_commit(mode);
                }
                return;
            }
            Action::StartAmend => self.start_commit(crate::state::commit::CommitMode::Amend),
            Action::CycleTheme => self.cycle_theme_internal(),
            Action::ClickFileList(idx) => {
                if idx < self.nav.file_count {
                    self.nav.file_index = idx;
                    self.nav.selected_file = self.nav.file_paths.get(idx).cloned();
                    self.ix.enter(Mode::FileList);
                    self.nav.focus = Focus::FileList;
                    self.update_selected_diff();
                }
            }
            Action::DragDivider(x) => {
                if x >= 15 && x <= 80 {
                    self.pane_width = x;
                }
            }
            Action::Quit => {
                self.should_quit = true;
                return;
            }
            _ => return,
        }
        self.needs_redraw = true;
    }

    fn dispatch_log_list(&mut self, action: Action) {
        match action {
            Action::Down => {
                if self.nav.log_count > 0 && self.nav.log_index < self.nav.log_count - 1 {
                    self.nav.log_index += 1;
                }
            }
            Action::Up => {
                self.nav.log_index = self.nav.log_index.saturating_sub(1);
            }
            Action::Select => {
                if self.nav.log_count > 0 {
                    self.ix.enter(Mode::LogDetail);
                    self.nav.focus = Focus::LogDetail;
                }
            }
            Action::Back | Action::ToggleLog => {
                self.ix.back();
                self.nav.focus = Focus::FileList;
            }
            Action::ScrollUp => {
                self.nav.log_index = self.nav.log_index.saturating_sub(1);
            }
            Action::ScrollDown => {
                if self.nav.log_count > 0 && self.nav.log_index < self.nav.log_count - 1 {
                    self.nav.log_index += 1;
                }
            }
            Action::Quit => {
                self.should_quit = true;
                return;
            }
            _ => return,
        }
        self.needs_redraw = true;
    }

    fn dispatch_log_detail(&mut self, action: Action) {
        match action {
            Action::Back => {
                self.ix.back();
                self.nav.focus = Focus::LogView;
            }
            Action::Quit => {
                self.should_quit = true;
                return;
            }
            _ => return,
        }
        self.needs_redraw = true;
    }

    fn dispatch_selecting(&mut self, action: Action) {
        match action {
            Action::Down => {
                self.selection.extend(self.selection.cursor.unwrap_or(0) + 1);
            }
            Action::Up => {
                let cur = self.selection.cursor.unwrap_or(0);
                self.selection.extend(cur.saturating_sub(1));
            }
            Action::Select => {
                // Confirm selection -> enter agent prompt
                self.ix.enter(Mode::AgentPrompt);
                self.input_mode = InputMode::AgentPrompt;
                self.input_buffer.clear();
                self.input_cursor = 0;
            }
            Action::Cancel | Action::Back => {
                self.selection.clear();
                self.ix.back();
            }
            Action::Quit => {
                self.should_quit = true;
                return;
            }
            _ => return,
        }
        self.needs_redraw = true;
    }

    fn dispatch_text_input(&mut self, action: Action) {
        match action {
            Action::InsertChar(c) => self.insert_char(c),
            Action::InsertNewline => self.insert_char('\n'),
            Action::DeleteChar => self.delete_char(),
            Action::Submit => {
                match self.ix.mode {
                    Mode::Committing { .. } => self.submit_commit(),
                    Mode::AgentPrompt => {
                        // TODO: dispatch to agent
                        self.cancel_input();
                        self.ix.back();
                    }
                    _ => {}
                }
            }
            Action::Cancel => {
                self.cancel_input();
                self.ix.back();
            }
            Action::Quit => {
                self.should_quit = true;
                return;
            }
            _ => return,
        }
        self.needs_redraw = true;
    }

    fn dispatch_dragging(&mut self, action: Action) {
        match action {
            Action::DragDivider(x) => {
                if x >= 15 && x <= 80 {
                    self.pane_width = x;
                }
            }
            _ => {
                // Any non-drag action ends drag mode
                self.ix.back();
            }
        }
        self.needs_redraw = true;
    }

    fn start_commit(&mut self, mode: crate::state::commit::CommitMode) {
        let staged_count = self
            .repo_state
            .as_ref()
            .map(|r| r.files.iter().filter(|f| f.staged != crate::types::Status::None).count())
            .unwrap_or(0);

        match CommitState::enter(mode, staged_count) {
            Ok(state) => {
                self.commit = state;
                self.ix.enter(Mode::Committing { mode });
                self.input_mode = InputMode::CommitMessage;
                self.input_buffer.clear();
                self.input_cursor = 0;
                self.needs_redraw = true;
            }
            Err(e) => {
                self.status_message = Some(e.to_string());
                self.needs_redraw = true;
            }
        }
    }

    fn do_unstage(&mut self) {
        if let Some(path) = self.nav.selected_file.clone() {
            use crate::state::file_state::{classify, unstage_command};
            if let Some(ref repo) = self.repo_state {
                if let Some(entry) = repo.files.iter().find(|f| f.path == path) {
                    let state = classify(entry);
                    if let Some(cmd) = unstage_command(state, &path) {
                        if let Err(e) = self.runner.exec_git_command(&cmd) {
                            self.status_message = Some(format!("unstage failed: {}", e));
                        } else {
                            self.refresh();
                        }
                    }
                }
            }
        }
    }

    fn cycle_theme_internal(&mut self) {
        self.theme_name = self.theme_name.next();
        self.theme = self.theme_name.theme();
        // Invalidate and rebuild cache -- colors changed
        self.diff_cache = DiffCache::empty();
        self.rebuild_diff_cache();
    }

    pub fn cycle_theme(&mut self) {
        self.theme_name = self.theme_name.next();
        self.theme = self.theme_name.theme();
        self.needs_redraw = true;
    }

    pub fn delete_char(&mut self) {
        if self.input_cursor > 0 {
            self.input_cursor -= 1;
            self.input_buffer.remove(self.input_cursor);
        }
    }
}

/// Paths to filter out of the file list -- noise that clutters the viewer.
fn should_ignore(path: &str) -> bool {
    const IGNORE_PREFIXES: &[&str] = &[
        ".claude/worktrees/",
        ".claude/projects/",
        "target/",
        "zig-out/",
        ".zig-cache/",
        "deps/",
        "_build/",
        "node_modules/",
    ];

    const IGNORE_FILES: &[&str] = &[
        "Cargo.lock",
    ];

    for prefix in IGNORE_PREFIXES {
        if path.starts_with(prefix) {
            return true;
        }
    }

    for name in IGNORE_FILES {
        if path.ends_with(name) {
            return true;
        }
    }

    false
}

fn find_latest_modified(
    files: &[crate::types::FileEntry],
    diffs: &HashMap<String, FileDiff>,
    repo_path: &std::path::Path,
) -> Option<String> {
    files
        .iter()
        .filter(|f| diffs.contains_key(&f.path))
        .filter_map(|f| {
            let full = repo_path.join(&f.path);
            let mtime = std::fs::metadata(&full).ok()?.modified().ok()?;
            Some((f.path.clone(), mtime))
        })
        .max_by_key(|(_, mtime)| *mtime)
        .map(|(path, _)| path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::process::Command;

    fn temp_repo_app() -> (tempfile::TempDir, App) {
        let dir = tempfile::tempdir().unwrap();
        Command::new("git")
            .args(["init"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        Command::new("git")
            .args(["config", "user.email", "test@test.com"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        Command::new("git")
            .args(["config", "user.name", "Test"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        fs::write(dir.path().join("README.md"), "# test\n").unwrap();
        Command::new("git")
            .args(["add", "README.md"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        Command::new("git")
            .args(["commit", "-m", "initial"])
            .current_dir(dir.path())
            .output()
            .unwrap();

        let app = App::new(dir.path().to_path_buf());
        (dir, app)
    }

    #[test]
    fn refresh_clean_repo() {
        let (_dir, mut app) = temp_repo_app();
        app.refresh();
        let state = app.repo_state.as_ref().unwrap();
        assert!(state.files.is_empty());
        assert!(!state.branch.is_empty());
    }

    #[test]
    fn refresh_sees_modified_file() {
        let (dir, mut app) = temp_repo_app();
        fs::write(dir.path().join("README.md"), "# changed\n").unwrap();
        app.refresh();

        let state = app.repo_state.as_ref().unwrap();
        assert_eq!(state.files.len(), 1);
        assert!(state.diffs.contains_key("README.md"));
        assert!(app.selected_diff.is_some());
    }

    #[test]
    fn refresh_sees_untracked_file() {
        let (dir, mut app) = temp_repo_app();
        fs::write(dir.path().join("new.rs"), "fn main() {}\n").unwrap();
        app.refresh();

        let state = app.repo_state.as_ref().unwrap();
        assert_eq!(state.files.len(), 1);
        assert_eq!(state.files[0].path, "new.rs");
    }

    #[test]
    fn nav_key_j_selects_next_file() {
        let (dir, mut app) = temp_repo_app();
        fs::write(dir.path().join("a.rs"), "a\n").unwrap();
        fs::write(dir.path().join("b.rs"), "b\n").unwrap();
        app.refresh();

        assert_eq!(app.nav.file_index, 0);
        app.handle_nav_key(NavKey::J);
        assert_eq!(app.nav.file_index, 1);
    }

    #[test]
    fn enter_and_quit_diff_view() {
        let (dir, mut app) = temp_repo_app();
        fs::write(dir.path().join("a.rs"), "a\n").unwrap();
        app.refresh();

        app.handle_nav_key(NavKey::Enter);
        assert_eq!(app.nav.focus, Focus::DiffView);
        app.handle_nav_key(NavKey::Q);
        assert_eq!(app.nav.focus, Focus::FileList);
    }

    #[test]
    fn stage_via_signal() {
        let (dir, mut app) = temp_repo_app();
        fs::write(dir.path().join("new.rs"), "fn main() {}\n").unwrap();
        app.refresh();

        app.handle_nav_key(NavKey::S);
        // After staging, refresh happens automatically
        let state = app.repo_state.as_ref().unwrap();
        let file = state.files.iter().find(|f| f.path == "new.rs");
        assert!(
            file.is_some(),
            "file should still be in status after staging"
        );
        assert_eq!(
            file.unwrap().staged,
            crate::types::Status::Added,
        );
    }

    #[test]
    fn commit_flow() {
        let (dir, mut app) = temp_repo_app();
        fs::write(dir.path().join("new.rs"), "fn main() {}\n").unwrap();
        app.refresh();

        // Stage
        app.handle_nav_key(NavKey::S);

        // Enter commit mode -- simulate cc chord
        app.commit = CommitState::enter(
            crate::state::commit::CommitMode::Commit,
            1,
        ).unwrap();
        app.input_mode = InputMode::CommitMessage;

        // Type message
        for c in "add new.rs".chars() {
            app.insert_char(c);
        }
        assert_eq!(app.input_buffer, "add new.rs");

        // Submit
        app.submit_commit();
        assert_eq!(app.input_mode, InputMode::Normal);
        assert!(!app.commit.is_active());

        // Verify commit happened
        app.refresh_log();
        assert!(app.log_entries.iter().any(|e| e.message == "add new.rs"));
    }

    #[test]
    fn cancel_commit() {
        let (_dir, mut app) = temp_repo_app();
        app.commit = CommitState::enter(
            crate::state::commit::CommitMode::Commit,
            1,
        ).unwrap();
        app.input_mode = InputMode::CommitMessage;
        app.insert_char('w');

        app.cancel_input();
        assert_eq!(app.input_mode, InputMode::Normal);
        assert!(!app.commit.is_active());
        assert!(app.input_buffer.is_empty());
    }

    #[test]
    fn follow_mode_selects_changed_file() {
        let (dir, mut app) = temp_repo_app();
        fs::write(dir.path().join("a.rs"), "a\n").unwrap();
        fs::write(dir.path().join("b.rs"), "b\n").unwrap();
        app.refresh();

        app.nav.following = true;
        // Modify b.rs so it has diffs
        fs::write(dir.path().join("README.md"), "# modified\n").unwrap();
        app.refresh();

        // Follow should have jumped to a file with diffs
        assert_eq!(app.nav.focus, Focus::DiffView);
    }

    #[test]
    fn log_view_loads_entries() {
        let (_dir, mut app) = temp_repo_app();
        app.refresh();
        app.handle_nav_key(NavKey::L);
        assert_eq!(app.nav.focus, Focus::LogView);
        assert!(!app.log_entries.is_empty());
    }

    #[test]
    fn delete_char_in_input() {
        let (_dir, mut app) = temp_repo_app();
        app.input_mode = InputMode::CommitMessage;
        app.insert_char('a');
        app.insert_char('b');
        app.insert_char('c');
        assert_eq!(app.input_buffer, "abc");
        app.delete_char();
        assert_eq!(app.input_buffer, "ab");
        assert_eq!(app.input_cursor, 2);
    }
}

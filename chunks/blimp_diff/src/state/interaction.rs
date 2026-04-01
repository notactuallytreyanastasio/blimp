use std::time::Instant;

use super::commit::CommitMode;

/// Every possible mode the TUI can be in. Each mode defines what keys
/// and mouse events do. There is exactly ONE active mode at a time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Browsing the file list. j/k moves files, Enter views diff.
    FileList,
    /// Viewing a diff. j/k moves hunks, q returns to FileList.
    DiffView,
    /// Viewing the git log. j/k moves entries, Enter views detail.
    LogList,
    /// Viewing a single commit's detail/diff.
    LogDetail,
    /// Visual line selection in diff view. j/k extends, Enter confirms.
    Selecting,
    /// Typing a commit message. Ctrl+Enter submits, Esc cancels.
    Committing { mode: CommitMode },
    /// Typing an agent prompt. Ctrl+Enter sends, Esc cancels.
    AgentPrompt,
    /// Dragging the pane divider with the mouse.
    Dragging,
}

/// What happened as a result of processing an input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    None,
    Redraw,
    StageFile(String),
    UnstageFile(String),
    OpenEditor(String),
    StartCommit(CommitMode),
    SubmitCommit,
    CancelOverlay,
    SubmitAgentPrompt,
    Refresh,
    Quit,
}

/// The interaction state machine. Owns the mode and all mode-specific
/// transient state. The rest of App reads from this.
#[derive(Debug, Clone)]
pub struct Interaction {
    pub mode: Mode,
    /// Previous mode to return to (for overlays/selections).
    prev_mode: Option<Mode>,
    /// Chord detection for 'cc'.
    last_c_time: Option<Instant>,
}

impl Interaction {
    pub fn new() -> Self {
        Self {
            mode: Mode::FileList,
            prev_mode: None,
            last_c_time: None,
        }
    }

    /// Transition to a new mode, saving current as prev for return.
    pub fn enter(&mut self, mode: Mode) {
        self.prev_mode = Some(self.mode);
        self.mode = mode;
    }

    /// Return to the previous mode (or FileList if none).
    pub fn back(&mut self) {
        if let Some(prev) = self.prev_mode.take() {
            self.mode = prev;
        } else {
            self.mode = match self.mode {
                Mode::DiffView => Mode::FileList,
                Mode::LogDetail => Mode::LogList,
                Mode::LogList => Mode::FileList,
                Mode::Selecting => Mode::DiffView,
                Mode::Committing { .. } => Mode::FileList,
                Mode::AgentPrompt => Mode::DiffView,
                Mode::Dragging => Mode::FileList,
                Mode::FileList => Mode::FileList,
            };
        }
    }

    /// Is the current mode an overlay that captures text input?
    pub fn is_text_input(&self) -> bool {
        matches!(self.mode, Mode::Committing { .. } | Mode::AgentPrompt)
    }

    /// Is the current mode an overlay (rendered on top, skips background)?
    pub fn is_overlay(&self) -> bool {
        matches!(
            self.mode,
            Mode::Committing { .. } | Mode::AgentPrompt | Mode::Selecting
        )
    }

    /// Which pane should be focused (for border highlighting)?
    pub fn active_pane(&self) -> Pane {
        match self.mode {
            Mode::FileList => Pane::FileList,
            Mode::DiffView | Mode::Selecting => Pane::DiffView,
            Mode::LogList | Mode::LogDetail => Pane::Log,
            Mode::Committing { .. } | Mode::AgentPrompt | Mode::Dragging => Pane::None,
        }
    }

    /// Process a 'c' keypress for chord detection. Returns Some(CommitMode)
    /// if 'cc' was detected within the window.
    pub fn press_c(&mut self) -> Option<CommitMode> {
        let now = Instant::now();
        if let Some(last) = self.last_c_time {
            if now.duration_since(last).as_millis() < 400 {
                self.last_c_time = None;
                return Some(CommitMode::Commit);
            }
        }
        self.last_c_time = Some(now);
        None
    }

    /// Clear chord state (called when a different key is pressed).
    pub fn clear_chord(&mut self) {
        self.last_c_time = None;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pane {
    FileList,
    DiffView,
    Log,
    None,
}

// ── Key mapping per mode ────────────────────────────────────

/// Semantic key actions. The event loop maps physical keys to these,
/// then the state machine processes them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    // Navigation
    Down,
    Up,
    Select,          // Enter in most modes
    Back,            // q or Esc depending on mode
    TogglePane,      // Tab

    // Scroll
    PageDown,
    PageUp,
    ScrollLeft,
    ScrollRight,
    ScrollHome,

    // Commands
    ToggleFollow,
    ToggleLog,
    OpenEditor,
    StageFile,
    UnstageFile,
    CommitChord,     // 'c' -- may become StartCommit via chord
    StartAmend,
    StartVisual,
    CycleTheme,

    // Text input (only in overlay modes)
    InsertChar(char),
    InsertNewline,
    DeleteChar,
    Submit,          // Ctrl+Enter
    Cancel,          // Esc

    // Mouse
    ClickFileList(usize),   // file index
    ClickDiffPane,
    DragDivider(u16),       // new x position
    ScrollUp,               // scroll in file list / current pane
    ScrollDown,
    ScrollDiffUp,           // always scrolls diff pane
    ScrollDiffDown,

    Quit,
    Noop,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_mode_is_file_list() {
        let ix = Interaction::new();
        assert_eq!(ix.mode, Mode::FileList);
    }

    #[test]
    fn enter_and_back() {
        let mut ix = Interaction::new();
        ix.enter(Mode::DiffView);
        assert_eq!(ix.mode, Mode::DiffView);
        ix.back();
        assert_eq!(ix.mode, Mode::FileList);
    }

    #[test]
    fn back_from_nested() {
        let mut ix = Interaction::new();
        ix.enter(Mode::DiffView);
        ix.enter(Mode::Selecting);
        assert_eq!(ix.mode, Mode::Selecting);
        ix.back();
        assert_eq!(ix.mode, Mode::DiffView);
    }

    #[test]
    fn back_from_file_list_stays() {
        let mut ix = Interaction::new();
        ix.back();
        assert_eq!(ix.mode, Mode::FileList);
    }

    #[test]
    fn is_text_input() {
        let mut ix = Interaction::new();
        assert!(!ix.is_text_input());
        ix.enter(Mode::Committing { mode: CommitMode::Commit });
        assert!(ix.is_text_input());
    }

    #[test]
    fn is_overlay() {
        let mut ix = Interaction::new();
        assert!(!ix.is_overlay());
        ix.enter(Mode::Committing { mode: CommitMode::Commit });
        assert!(ix.is_overlay());
        ix.back();
        ix.enter(Mode::AgentPrompt);
        assert!(ix.is_overlay());
    }

    #[test]
    fn active_pane_by_mode() {
        let mut ix = Interaction::new();
        assert_eq!(ix.active_pane(), Pane::FileList);
        ix.enter(Mode::DiffView);
        assert_eq!(ix.active_pane(), Pane::DiffView);
        ix.enter(Mode::Selecting);
        assert_eq!(ix.active_pane(), Pane::DiffView);
        ix.back();
        ix.enter(Mode::LogList);
        assert_eq!(ix.active_pane(), Pane::Log);
        ix.back();
        ix.enter(Mode::Committing { mode: CommitMode::Commit });
        assert_eq!(ix.active_pane(), Pane::None);
    }

    #[test]
    fn chord_detection_cc() {
        let mut ix = Interaction::new();
        assert!(ix.press_c().is_none()); // first c
        assert_eq!(ix.press_c(), Some(CommitMode::Commit)); // second c within window
    }

    #[test]
    fn chord_detection_timeout() {
        let mut ix = Interaction::new();
        assert!(ix.press_c().is_none());
        // Simulate timeout by clearing
        ix.last_c_time = Some(Instant::now() - std::time::Duration::from_millis(500));
        assert!(ix.press_c().is_none()); // too late, resets
    }

    #[test]
    fn chord_cleared_by_other_key() {
        let mut ix = Interaction::new();
        ix.press_c();
        assert!(ix.last_c_time.is_some());
        ix.clear_chord();
        assert!(ix.last_c_time.is_none());
    }

    #[test]
    fn log_transitions() {
        let mut ix = Interaction::new();
        ix.enter(Mode::LogList);
        assert_eq!(ix.mode, Mode::LogList);
        ix.enter(Mode::LogDetail);
        assert_eq!(ix.mode, Mode::LogDetail);
        ix.back();
        assert_eq!(ix.mode, Mode::LogList);
        ix.back();
        assert_eq!(ix.mode, Mode::FileList);
    }

    #[test]
    fn committing_back_returns_to_prev() {
        let mut ix = Interaction::new();
        ix.enter(Mode::DiffView);
        ix.enter(Mode::Committing { mode: CommitMode::Commit });
        ix.back();
        assert_eq!(ix.mode, Mode::DiffView);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Idle,
    Editing,
    Submitting,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommitMode {
    Commit,
    Amend,
}

#[derive(Debug, Clone)]
pub struct CommitState {
    pub phase: Phase,
    pub mode: CommitMode,
    pub message: String,
    pub error_message: Option<String>,
}

impl CommitState {
    pub fn idle() -> Self {
        Self {
            phase: Phase::Idle,
            mode: CommitMode::Commit,
            message: String::new(),
            error_message: None,
        }
    }

    pub fn enter(mode: CommitMode, staged_count: usize) -> Result<Self, &'static str> {
        if mode == CommitMode::Commit && staged_count == 0 {
            return Err("nothing staged to commit");
        }
        Ok(Self {
            phase: Phase::Editing,
            mode,
            message: String::new(),
            error_message: None,
        })
    }

    pub fn update_message(&mut self, msg: String) {
        self.message = msg;
    }

    pub fn submit(&mut self) -> Result<(), &'static str> {
        if self.message.trim().is_empty() {
            return Err("commit message cannot be empty");
        }
        self.phase = Phase::Submitting;
        Ok(())
    }

    pub fn complete(&mut self) {
        self.phase = Phase::Idle;
        self.message.clear();
        self.error_message = None;
    }

    pub fn fail(&mut self, error: String) {
        self.phase = Phase::Error;
        self.error_message = Some(error);
    }

    pub fn cancel(&mut self) {
        self.phase = Phase::Idle;
        self.message.clear();
        self.error_message = None;
    }

    pub fn is_active(&self) -> bool {
        self.phase != Phase::Idle
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_is_not_active() {
        let state = CommitState::idle();
        assert!(!state.is_active());
        assert_eq!(state.phase, Phase::Idle);
    }

    #[test]
    fn enter_commit_with_staged_files() {
        let state = CommitState::enter(CommitMode::Commit, 3).unwrap();
        assert_eq!(state.phase, Phase::Editing);
        assert_eq!(state.mode, CommitMode::Commit);
        assert!(state.is_active());
    }

    #[test]
    fn enter_commit_with_zero_staged_fails() {
        let result = CommitState::enter(CommitMode::Commit, 0);
        assert!(result.is_err());
    }

    #[test]
    fn enter_amend_with_zero_staged_ok() {
        let state = CommitState::enter(CommitMode::Amend, 0).unwrap();
        assert_eq!(state.phase, Phase::Editing);
        assert_eq!(state.mode, CommitMode::Amend);
    }

    #[test]
    fn update_message() {
        let mut state = CommitState::enter(CommitMode::Commit, 1).unwrap();
        state.update_message("feat: new thing".into());
        assert_eq!(state.message, "feat: new thing");
    }

    #[test]
    fn submit_with_message_transitions_to_submitting() {
        let mut state = CommitState::enter(CommitMode::Commit, 1).unwrap();
        state.update_message("feat: new thing".into());
        assert!(state.submit().is_ok());
        assert_eq!(state.phase, Phase::Submitting);
    }

    #[test]
    fn submit_with_empty_message_fails() {
        let mut state = CommitState::enter(CommitMode::Commit, 1).unwrap();
        assert!(state.submit().is_err());
        assert_eq!(state.phase, Phase::Editing); // stays in editing
    }

    #[test]
    fn complete_resets_to_idle() {
        let mut state = CommitState::enter(CommitMode::Commit, 1).unwrap();
        state.update_message("msg".into());
        state.submit().unwrap();
        state.complete();
        assert_eq!(state.phase, Phase::Idle);
        assert!(state.message.is_empty());
        assert!(!state.is_active());
    }

    #[test]
    fn fail_sets_error() {
        let mut state = CommitState::enter(CommitMode::Commit, 1).unwrap();
        state.update_message("msg".into());
        state.submit().unwrap();
        state.fail("git error".into());
        assert_eq!(state.phase, Phase::Error);
        assert_eq!(state.error_message.as_deref(), Some("git error"));
        assert!(state.is_active()); // error is still active, user must cancel
    }

    #[test]
    fn cancel_from_editing() {
        let mut state = CommitState::enter(CommitMode::Commit, 1).unwrap();
        state.update_message("wip".into());
        state.cancel();
        assert_eq!(state.phase, Phase::Idle);
        assert!(!state.is_active());
    }

    #[test]
    fn cancel_from_error() {
        let mut state = CommitState::enter(CommitMode::Commit, 1).unwrap();
        state.update_message("msg".into());
        state.submit().unwrap();
        state.fail("oops".into());
        state.cancel();
        assert_eq!(state.phase, Phase::Idle);
        assert!(!state.is_active());
    }
}

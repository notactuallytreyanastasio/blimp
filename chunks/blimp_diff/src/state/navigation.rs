use std::collections::HashSet;
use std::time::Instant;

use crate::state::commit::CommitMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    FileList,
    DiffView,
    LogView,
    LogDetail,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavKey {
    J,
    K,
    Enter,
    Q,
    Tab,
    F,
    L,
    O,
    S,
    U,
    C,
    A,
    Escape,
    V,
    Other,
}

#[derive(Debug, Clone)]
pub struct Navigation {
    pub focus: Focus,
    pub file_index: usize,
    pub file_count: usize,
    pub hunk_index: usize,
    pub hunk_count: usize,
    pub log_index: usize,
    pub log_count: usize,
    pub file_paths: Vec<String>,
    pub selected_file: Option<String>,
    pub selected_commit: Option<String>,
    pub expanded_hunks: HashSet<usize>,
    pub following: bool,

    // Signals -- consumed by event loop after each key
    pub open_file: Option<String>,
    pub stage_file: Option<String>,
    pub unstage_file: Option<String>,
    pub enter_commit: Option<CommitMode>,
    pub enter_visual: bool,

    // Chord state
    last_c_time: Option<Instant>,
}

impl Navigation {
    pub fn new() -> Self {
        Self {
            focus: Focus::FileList,
            file_index: 0,
            file_count: 0,
            file_paths: vec![],
            hunk_index: 0,
            hunk_count: 0,
            log_index: 0,
            log_count: 0,
            selected_file: None,
            selected_commit: None,
            expanded_hunks: HashSet::new(),
            following: false,
            open_file: None,
            stage_file: None,
            unstage_file: None,
            enter_commit: None,
            enter_visual: false,
            last_c_time: None,
        }
    }

    pub fn handle_key(&mut self, key: NavKey) {
        match key {
            NavKey::J => self.move_down(),
            NavKey::K => self.move_up(),
            NavKey::Enter => self.handle_enter(),
            NavKey::Q => self.handle_quit(),
            NavKey::Tab => self.handle_tab(),
            NavKey::F => self.following = !self.following,
            NavKey::L => self.handle_log(),
            NavKey::O => self.handle_open(),
            NavKey::S => self.handle_stage(),
            NavKey::U => self.handle_unstage(),
            NavKey::C => self.handle_c(),
            NavKey::A => self.enter_commit = Some(CommitMode::Amend),
            NavKey::V => self.handle_visual(),
            NavKey::Escape | NavKey::Other => {}
        }
    }

    pub fn sync_to_files(&mut self, paths: &[String]) {
        self.file_paths = paths.to_vec();
        self.file_count = paths.len();

        // Try to preserve selection by name
        if let Some(ref selected) = self.selected_file {
            if let Some(new_idx) = paths.iter().position(|p| p == selected) {
                self.file_index = new_idx;
                return;
            }
        }

        // Clamp index
        if self.file_count == 0 {
            self.file_index = 0;
            self.selected_file = None;
        } else {
            self.file_index = self.file_index.min(self.file_count - 1);
            self.selected_file = Some(paths[self.file_index].clone());
        }
    }

    pub fn follow_to_latest(&mut self, latest_file: &str, hunk_count: usize) {
        self.selected_file = Some(latest_file.to_string());
        if let Some(idx) = self.file_paths.iter().position(|p| p == latest_file) {
            self.file_index = idx;
        }
        self.focus = Focus::DiffView;
        self.hunk_count = hunk_count;
        self.hunk_index = if hunk_count > 0 { hunk_count - 1 } else { 0 };
    }

    pub fn clear_signals(&mut self) {
        self.open_file = None;
        self.stage_file = None;
        self.unstage_file = None;
        self.enter_commit = None;
        self.enter_visual = false;
    }

    fn update_selected_file(&mut self) {
        self.selected_file = self.file_paths.get(self.file_index).cloned();
    }

    fn move_down(&mut self) {
        match self.focus {
            Focus::FileList => {
                if self.file_count > 0 && self.file_index < self.file_count - 1 {
                    self.file_index += 1;
                    self.update_selected_file();
                }
            }
            Focus::DiffView => {
                if self.hunk_count > 0 && self.hunk_index < self.hunk_count - 1 {
                    self.hunk_index += 1;
                }
            }
            Focus::LogView => {
                if self.log_count > 0 && self.log_index < self.log_count - 1 {
                    self.log_index += 1;
                }
            }
            Focus::LogDetail => {}
        }
    }

    fn move_up(&mut self) {
        match self.focus {
            Focus::FileList => {
                self.file_index = self.file_index.saturating_sub(1);
                self.update_selected_file();
            }
            Focus::DiffView => {
                self.hunk_index = self.hunk_index.saturating_sub(1);
            }
            Focus::LogView => {
                self.log_index = self.log_index.saturating_sub(1);
            }
            Focus::LogDetail => {}
        }
    }

    fn handle_enter(&mut self) {
        match self.focus {
            Focus::FileList => {
                if self.file_count > 0 {
                    self.focus = Focus::DiffView;
                    self.hunk_index = 0;
                }
            }
            Focus::DiffView => {
                // Toggle hunk expansion
                if self.expanded_hunks.contains(&self.hunk_index) {
                    self.expanded_hunks.remove(&self.hunk_index);
                } else {
                    self.expanded_hunks.insert(self.hunk_index);
                }
            }
            Focus::LogView => {
                if self.log_count > 0 {
                    self.focus = Focus::LogDetail;
                }
            }
            Focus::LogDetail => {}
        }
    }

    fn handle_quit(&mut self) {
        match self.focus {
            Focus::DiffView => self.focus = Focus::FileList,
            Focus::LogView => self.focus = Focus::FileList,
            Focus::LogDetail => self.focus = Focus::LogView,
            Focus::FileList => {} // top level, event loop handles app quit
        }
    }

    fn handle_tab(&mut self) {
        self.focus = match self.focus {
            Focus::FileList => Focus::DiffView,
            Focus::DiffView => Focus::FileList,
            other => other,
        };
    }

    fn handle_log(&mut self) {
        match self.focus {
            Focus::LogView | Focus::LogDetail => self.focus = Focus::FileList,
            _ => self.focus = Focus::LogView,
        }
    }

    fn handle_open(&mut self) {
        if let Some(ref file) = self.selected_file {
            self.open_file = Some(file.clone());
        }
    }

    fn handle_stage(&mut self) {
        if let Some(ref file) = self.selected_file {
            self.stage_file = Some(file.clone());
        }
    }

    fn handle_unstage(&mut self) {
        if let Some(ref file) = self.selected_file {
            self.unstage_file = Some(file.clone());
        }
    }

    fn handle_c(&mut self) {
        let now = Instant::now();
        if let Some(last) = self.last_c_time {
            if now.duration_since(last).as_millis() < 400 {
                self.enter_commit = Some(CommitMode::Commit);
                self.last_c_time = None;
                return;
            }
        }
        self.last_c_time = Some(now);
    }

    fn handle_visual(&mut self) {
        if self.focus == Focus::DiffView {
            self.enter_visual = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nav_with_files(count: usize) -> Navigation {
        let mut nav = Navigation::new();
        let paths: Vec<String> = (0..count).map(|i| format!("file_{i}.rs")).collect();
        nav.sync_to_files(&paths);
        nav
    }

    // -- initialization --

    #[test]
    fn new_starts_at_file_list() {
        let nav = Navigation::new();
        assert_eq!(nav.focus, Focus::FileList);
        assert_eq!(nav.file_index, 0);
        assert!(!nav.following);
    }

    // -- j/k movement in file list --

    #[test]
    fn j_moves_down_in_file_list() {
        let mut nav = nav_with_files(5);
        assert_eq!(nav.file_index, 0);
        nav.handle_key(NavKey::J);
        assert_eq!(nav.file_index, 1);
        nav.handle_key(NavKey::J);
        assert_eq!(nav.file_index, 2);
    }

    #[test]
    fn j_clamps_at_bottom() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::J);
        nav.handle_key(NavKey::J);
        nav.handle_key(NavKey::J); // past end
        assert_eq!(nav.file_index, 2); // stays at last
    }

    #[test]
    fn k_moves_up_in_file_list() {
        let mut nav = nav_with_files(5);
        nav.handle_key(NavKey::J);
        nav.handle_key(NavKey::J);
        nav.handle_key(NavKey::K);
        assert_eq!(nav.file_index, 1);
    }

    #[test]
    fn k_clamps_at_top() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::K); // already at 0
        assert_eq!(nav.file_index, 0);
    }

    // -- enter diff view --

    #[test]
    fn enter_from_file_list_goes_to_diff_view() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::Enter);
        assert_eq!(nav.focus, Focus::DiffView);
    }

    #[test]
    fn q_from_diff_view_returns_to_file_list() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::Enter); // into diff view
        nav.handle_key(NavKey::Q);
        assert_eq!(nav.focus, Focus::FileList);
    }

    // -- j/k in diff view (hunk navigation) --

    #[test]
    fn j_k_in_diff_view_moves_hunks() {
        let mut nav = nav_with_files(3);
        nav.hunk_count = 5;
        nav.handle_key(NavKey::Enter); // into diff view
        assert_eq!(nav.hunk_index, 0);
        nav.handle_key(NavKey::J);
        assert_eq!(nav.hunk_index, 1);
        nav.handle_key(NavKey::K);
        assert_eq!(nav.hunk_index, 0);
    }

    #[test]
    fn hunk_index_clamps() {
        let mut nav = nav_with_files(1);
        nav.hunk_count = 2;
        nav.handle_key(NavKey::Enter);
        nav.handle_key(NavKey::J); // 1
        nav.handle_key(NavKey::J); // still 1
        assert_eq!(nav.hunk_index, 1);
        nav.handle_key(NavKey::K); // 0
        nav.handle_key(NavKey::K); // still 0
        assert_eq!(nav.hunk_index, 0);
    }

    // -- tab toggle --

    #[test]
    fn tab_toggles_focus() {
        let mut nav = nav_with_files(3);
        assert_eq!(nav.focus, Focus::FileList);
        nav.handle_key(NavKey::Tab);
        assert_eq!(nav.focus, Focus::DiffView);
        nav.handle_key(NavKey::Tab);
        assert_eq!(nav.focus, Focus::FileList);
    }

    // -- follow mode --

    #[test]
    fn f_toggles_follow() {
        let mut nav = Navigation::new();
        assert!(!nav.following);
        nav.handle_key(NavKey::F);
        assert!(nav.following);
        nav.handle_key(NavKey::F);
        assert!(!nav.following);
    }

    // -- log view --

    #[test]
    fn l_enters_log_view() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::L);
        assert_eq!(nav.focus, Focus::LogView);
    }

    #[test]
    fn q_from_log_view_returns_to_file_list() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::L);
        nav.handle_key(NavKey::Q);
        assert_eq!(nav.focus, Focus::FileList);
    }

    #[test]
    fn enter_in_log_view_goes_to_detail() {
        let mut nav = nav_with_files(3);
        nav.log_count = 5;
        nav.handle_key(NavKey::L);
        nav.handle_key(NavKey::Enter);
        assert_eq!(nav.focus, Focus::LogDetail);
    }

    #[test]
    fn q_from_log_detail_returns_to_log_view() {
        let mut nav = nav_with_files(3);
        nav.log_count = 5;
        nav.handle_key(NavKey::L);
        nav.handle_key(NavKey::Enter);
        nav.handle_key(NavKey::Q);
        assert_eq!(nav.focus, Focus::LogView);
    }

    // -- signals --

    #[test]
    fn o_sets_open_file_signal() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::O);
        assert!(nav.open_file.is_some());
    }

    #[test]
    fn s_sets_stage_signal() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::S);
        assert!(nav.stage_file.is_some());
    }

    #[test]
    fn u_sets_unstage_signal() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::U);
        assert!(nav.unstage_file.is_some());
    }

    #[test]
    fn a_sets_amend_signal() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::A);
        assert_eq!(nav.enter_commit, Some(CommitMode::Amend));
    }

    #[test]
    fn v_sets_visual_signal_in_diff_view() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::Enter); // into diff view
        nav.handle_key(NavKey::V);
        assert!(nav.enter_visual);
    }

    #[test]
    fn clear_signals_resets_all() {
        let mut nav = nav_with_files(3);
        nav.handle_key(NavKey::O);
        nav.handle_key(NavKey::S);
        assert!(nav.open_file.is_some());
        nav.clear_signals();
        assert!(nav.open_file.is_none());
        assert!(nav.stage_file.is_none());
        assert!(nav.unstage_file.is_none());
        assert!(nav.enter_commit.is_none());
        assert!(!nav.enter_visual);
    }

    // -- sync_to_files --

    #[test]
    fn sync_updates_count() {
        let mut nav = Navigation::new();
        let paths = vec!["a.rs".into(), "b.rs".into()];
        nav.sync_to_files(&paths);
        assert_eq!(nav.file_count, 2);
    }

    #[test]
    fn sync_clamps_index_when_files_removed() {
        let mut nav = nav_with_files(5);
        nav.handle_key(NavKey::J);
        nav.handle_key(NavKey::J);
        nav.handle_key(NavKey::J); // index=3
        let paths = vec!["a.rs".into(), "b.rs".into()]; // only 2 now
        nav.sync_to_files(&paths);
        assert_eq!(nav.file_index, 1); // clamped to last
    }

    #[test]
    fn sync_preserves_selection_by_name() {
        let mut nav = Navigation::new();
        let paths = vec!["a.rs".into(), "b.rs".into(), "c.rs".into()];
        nav.sync_to_files(&paths);
        nav.handle_key(NavKey::J); // select b.rs (index 1)
        nav.handle_key(NavKey::J); // select c.rs (index 2)
        // Files reorder: c.rs is now at index 0
        let new_paths = vec!["c.rs".into(), "a.rs".into(), "b.rs".into()];
        nav.sync_to_files(&new_paths);
        assert_eq!(nav.selected_file.as_deref(), Some("c.rs"));
        assert_eq!(nav.file_index, 0); // c.rs is now at 0
    }

    #[test]
    fn sync_empty_files() {
        let mut nav = nav_with_files(3);
        nav.sync_to_files(&[]);
        assert_eq!(nav.file_count, 0);
        assert_eq!(nav.file_index, 0);
    }

    // -- follow_to_latest --

    #[test]
    fn follow_to_latest_jumps_to_file() {
        let mut nav = nav_with_files(5);
        nav.following = true;
        nav.follow_to_latest("file_3.rs", 4);
        assert_eq!(nav.focus, Focus::DiffView);
        assert_eq!(nav.selected_file.as_deref(), Some("file_3.rs"));
        assert_eq!(nav.file_index, 3);
        assert_eq!(nav.hunk_count, 4);
        assert_eq!(nav.hunk_index, 3); // last hunk
    }

    // -- empty state edge cases --

    #[test]
    fn j_with_no_files_is_noop() {
        let mut nav = Navigation::new();
        nav.handle_key(NavKey::J);
        assert_eq!(nav.file_index, 0);
    }

    #[test]
    fn enter_with_no_files_is_noop() {
        let mut nav = Navigation::new();
        nav.handle_key(NavKey::Enter);
        assert_eq!(nav.focus, Focus::FileList); // doesn't enter diff view
    }
}

#[derive(Debug, Clone, Default)]
pub struct LineSelection {
    pub file: Option<String>,
    pub anchor: Option<u32>,
    pub cursor: Option<u32>,
    pub active: bool,
}

impl LineSelection {
    pub fn new() -> Self {
        Self {
            file: None,
            anchor: None,
            cursor: None,
            active: false,
        }
    }

    pub fn start(&mut self, file: &str, line: u32) {
        self.file = Some(file.to_string());
        self.anchor = Some(line);
        self.cursor = Some(line);
        self.active = true;
    }

    pub fn extend(&mut self, line: u32) {
        if self.active {
            self.cursor = Some(line);
        }
    }

    pub fn clear(&mut self) {
        self.file = None;
        self.anchor = None;
        self.cursor = None;
        self.active = false;
    }

    pub fn selected_range(&self) -> Option<(u32, u32)> {
        let anchor = self.anchor?;
        let cursor = self.cursor?;
        if !self.active {
            return None;
        }
        Some((anchor.min(cursor), anchor.max(cursor)))
    }

    pub fn contains(&self, line: u32) -> bool {
        match self.selected_range() {
            Some((start, end)) => line >= start && line <= end,
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_selection_is_inactive() {
        let sel = LineSelection::new();
        assert!(!sel.active);
        assert!(sel.selected_range().is_none());
    }

    #[test]
    fn start_sets_anchor_and_cursor() {
        let mut sel = LineSelection::new();
        sel.start("file.rs", 10);
        assert!(sel.active);
        assert_eq!(sel.file.as_deref(), Some("file.rs"));
        assert_eq!(sel.selected_range(), Some((10, 10)));
    }

    #[test]
    fn extend_moves_cursor() {
        let mut sel = LineSelection::new();
        sel.start("file.rs", 5);
        sel.extend(10);
        assert_eq!(sel.selected_range(), Some((5, 10)));
    }

    #[test]
    fn extend_backwards_normalizes_range() {
        let mut sel = LineSelection::new();
        sel.start("file.rs", 10);
        sel.extend(3);
        assert_eq!(sel.selected_range(), Some((3, 10)));
    }

    #[test]
    fn contains_within_range() {
        let mut sel = LineSelection::new();
        sel.start("file.rs", 5);
        sel.extend(10);
        assert!(sel.contains(5));
        assert!(sel.contains(7));
        assert!(sel.contains(10));
        assert!(!sel.contains(4));
        assert!(!sel.contains(11));
    }

    #[test]
    fn contains_when_inactive() {
        let sel = LineSelection::new();
        assert!(!sel.contains(5));
    }

    #[test]
    fn clear_resets_everything() {
        let mut sel = LineSelection::new();
        sel.start("file.rs", 5);
        sel.extend(10);
        sel.clear();
        assert!(!sel.active);
        assert!(sel.file.is_none());
        assert!(sel.selected_range().is_none());
    }

    #[test]
    fn start_new_file_clears_previous() {
        let mut sel = LineSelection::new();
        sel.start("a.rs", 5);
        sel.extend(10);
        sel.start("b.rs", 1);
        assert_eq!(sel.file.as_deref(), Some("b.rs"));
        assert_eq!(sel.selected_range(), Some((1, 1)));
    }
}

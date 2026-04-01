use ratatui::prelude::*;
use ratatui::style::Color as RColor;
use syntect::easy::HighlightLines;
use syntect::highlighting::ThemeSet;
use syntect::parsing::SyntaxSet;

/// Shared syntax highlighting state. Created once at app startup.
pub struct Highlighter {
    syntax_set: SyntaxSet,
    theme_set: ThemeSet,
}

impl Highlighter {
    pub fn new() -> Self {
        Self {
            syntax_set: SyntaxSet::load_defaults_newlines(),
            theme_set: ThemeSet::load_defaults(),
        }
    }

    /// Create a reusable highlight session for a file extension.
    /// Call this once per file, then use `session.highlight_line()` per line.
    pub fn session(&self, ext: &str) -> HighlightSession<'_> {
        let syntax = self
            .syntax_set
            .find_syntax_by_extension(ext)
            .unwrap_or_else(|| self.syntax_set.find_syntax_plain_text());
        let theme = &self.theme_set.themes["base16-ocean.dark"];

        HighlightSession {
            inner: HighlightLines::new(syntax, theme),
            syntax_set: &self.syntax_set,
        }
    }

    /// One-shot highlight (for cases where session isn't practical).
    pub fn highlight_line(
        &self,
        line: &str,
        ext: &str,
        diff_bg: RColor,
    ) -> Vec<Span<'static>> {
        let mut session = self.session(ext);
        session.highlight_line(line, diff_bg)
    }

    pub fn extension_from_path(path: &str) -> &str {
        path.rsplit('.')
            .next()
            .unwrap_or("txt")
    }
}

/// A highlight session reuses the HighlightLines state machine across
/// multiple lines. Created once per file per render, not per line.
pub struct HighlightSession<'a> {
    inner: HighlightLines<'a>,
    syntax_set: &'a SyntaxSet,
}

impl<'a> HighlightSession<'a> {
    pub fn highlight_line(&mut self, line: &str, diff_bg: RColor) -> Vec<Span<'static>> {
        match self.inner.highlight_line(line, self.syntax_set) {
            Ok(ranges) => ranges
                .into_iter()
                .map(|(style, text)| {
                    let fg = syntect_to_ratatui_color(style.foreground);
                    Span::styled(
                        text.to_string(),
                        Style::default().fg(fg).bg(diff_bg),
                    )
                })
                .collect(),
            Err(_) => {
                vec![Span::styled(
                    line.to_string(),
                    Style::default().bg(diff_bg),
                )]
            }
        }
    }
}

fn syntect_to_ratatui_color(c: syntect::highlighting::Color) -> RColor {
    RColor::Rgb(c.r, c.g, c.b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_detection() {
        assert_eq!(Highlighter::extension_from_path("src/main.rs"), "rs");
        assert_eq!(Highlighter::extension_from_path("foo.py"), "py");
        assert_eq!(Highlighter::extension_from_path("Makefile"), "Makefile");
        assert_eq!(Highlighter::extension_from_path("no_ext"), "no_ext");
    }

    #[test]
    fn syntect_color_conversion() {
        let c = syntect::highlighting::Color { r: 255, g: 128, b: 0, a: 255 };
        assert_eq!(syntect_to_ratatui_color(c), RColor::Rgb(255, 128, 0));
    }

    #[test]
    fn highlighter_creates() {
        let h = Highlighter::new();
        assert!(h.syntax_set.find_syntax_by_extension("rs").is_some());
        assert!(h.syntax_set.find_syntax_by_extension("py").is_some());
        assert!(h.syntax_set.find_syntax_by_extension("js").is_some());
    }

    #[test]
    fn session_highlights_rust() {
        let h = Highlighter::new();
        let mut session = h.session("rs");
        let spans = session.highlight_line("fn main() {}", RColor::Rgb(10, 40, 10));
        assert!(!spans.is_empty());
        for span in &spans {
            assert_eq!(span.style.bg, Some(RColor::Rgb(10, 40, 10)));
        }
    }

    #[test]
    fn session_reuses_state() {
        let h = Highlighter::new();
        let mut session = h.session("rs");
        // Highlight multiple lines -- should not panic and should reuse parse state
        let _ = session.highlight_line("fn main() {", RColor::Rgb(0, 0, 0));
        let _ = session.highlight_line("    let x = 1;", RColor::Rgb(0, 0, 0));
        let _ = session.highlight_line("}", RColor::Rgb(0, 0, 0));
    }

    #[test]
    fn one_shot_highlight() {
        let h = Highlighter::new();
        let spans = h.highlight_line("hello world", "txt", RColor::Rgb(0, 0, 0));
        assert!(!spans.is_empty());
    }

    #[test]
    fn highlight_unknown_extension_falls_back() {
        let h = Highlighter::new();
        let spans = h.highlight_line("hello world", "zzzzz", RColor::Rgb(0, 0, 0));
        assert!(!spans.is_empty());
    }

    #[test]
    fn highlight_empty_line() {
        let h = Highlighter::new();
        let spans = h.highlight_line("", "rs", RColor::Rgb(0, 0, 0));
        let _ = spans;
    }
}

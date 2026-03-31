use ratatui::style::Color;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThemeName {
    SolarizedDark,
    SolarizedLight,
    MonokaiDark,
    MonokaiLight,
}

/// All semantic colors the UI needs. Widgets reference this, never raw colors.
#[derive(Debug, Clone, Copy)]
pub struct Theme {
    // Backgrounds
    pub bg: Color,
    pub bg_alt: Color,          // alternate pane bg
    pub bg_selected: Color,     // selected item
    pub bg_gutter: Color,       // line number gutter

    // Foregrounds
    pub fg: Color,
    pub fg_dim: Color,
    pub fg_bright: Color,

    // Borders
    pub border: Color,
    pub border_focused: Color,

    // Diff
    pub diff_add_fg: Color,
    pub diff_add_bg: Color,     // faint green overlay
    pub diff_del_fg: Color,
    pub diff_del_bg: Color,     // faint red overlay
    pub diff_context_fg: Color,
    pub diff_hunk_header_fg: Color,
    pub diff_hunk_header_bg: Color,
    pub diff_hunk_selected_bg: Color,
    pub diff_hot_bg: Color,     // follow mode highlight

    // Status icons
    pub status_added: Color,
    pub status_modified: Color,
    pub status_deleted: Color,
    pub status_renamed: Color,
    pub status_untracked: Color,
    pub status_staged: Color,

    // Selection (visual mode / line selection)
    pub selection_bg: Color,

    // Status bar
    pub bar_bg: Color,
    pub bar_fg: Color,
    pub bar_accent: Color,

    // Overlays (commit, agent prompt)
    pub overlay_bg: Color,
    pub overlay_border: Color,
    pub overlay_fg: Color,

    // Errors
    pub error: Color,
}

impl ThemeName {
    pub fn theme(self) -> Theme {
        match self {
            ThemeName::SolarizedDark => solarized_dark(),
            ThemeName::SolarizedLight => solarized_light(),
            ThemeName::MonokaiDark => monokai_dark(),
            ThemeName::MonokaiLight => monokai_light(),
        }
    }

    pub fn next(self) -> Self {
        match self {
            ThemeName::SolarizedDark => ThemeName::SolarizedLight,
            ThemeName::SolarizedLight => ThemeName::MonokaiDark,
            ThemeName::MonokaiDark => ThemeName::MonokaiLight,
            ThemeName::MonokaiLight => ThemeName::SolarizedDark,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            ThemeName::SolarizedDark => "solarized dark",
            ThemeName::SolarizedLight => "solarized light",
            ThemeName::MonokaiDark => "monokai dark",
            ThemeName::MonokaiLight => "monokai light",
        }
    }
}

// ── Solarized Dark ──────────────────────────────────────────

fn solarized_dark() -> Theme {
    // base03  #002b36   base02 #073642   base01 #586e75
    // base00  #657b83   base0  #839496   base1  #93a1a1
    // base2   #eee8d5   base3  #fdf6e3
    // yellow  #b58900   orange #cb4b16   red    #dc322f
    // magenta #d33682   violet #6c71c4   blue   #268bd2
    // cyan    #2aa198   green  #859900
    let base03 = Color::Rgb(0, 43, 54);
    let base02 = Color::Rgb(7, 54, 66);
    let base01 = Color::Rgb(88, 110, 117);
    let base0 = Color::Rgb(131, 148, 150);
    let base1 = Color::Rgb(147, 161, 161);
    let yellow = Color::Rgb(181, 137, 0);
    let red = Color::Rgb(220, 50, 47);
    let green = Color::Rgb(133, 153, 0);
    let blue = Color::Rgb(38, 139, 210);
    let cyan = Color::Rgb(42, 161, 152);

    Theme {
        bg: base03,
        bg_alt: base02,
        bg_selected: Color::Rgb(0, 80, 100),
        bg_gutter: base02,

        fg: base0,
        fg_dim: base01,
        fg_bright: base1,

        border: base01,
        border_focused: green,

        diff_add_fg: green,
        diff_add_bg: Color::Rgb(20, 60, 20),
        diff_del_fg: red,
        diff_del_bg: Color::Rgb(60, 15, 15),
        diff_context_fg: base0,
        diff_hunk_header_fg: blue,
        diff_hunk_header_bg: base02,
        diff_hunk_selected_bg: Color::Rgb(0, 90, 120),
        diff_hot_bg: Color::Rgb(60, 50, 0),

        status_added: green,
        status_modified: yellow,
        status_deleted: red,
        status_renamed: cyan,
        status_untracked: base01,
        status_staged: green,

        selection_bg: Color::Rgb(30, 60, 90),

        bar_bg: base02,
        bar_fg: base0,
        bar_accent: cyan,

        overlay_bg: base02,
        overlay_border: yellow,
        overlay_fg: base0,

        error: red,
    }
}

// ── Solarized Light ─────────────────────────────────────────

fn solarized_light() -> Theme {
    let base3 = Color::Rgb(253, 246, 227);
    let base2 = Color::Rgb(238, 232, 213);
    let base00 = Color::Rgb(101, 123, 131);
    let base01 = Color::Rgb(88, 110, 117);
    let base1 = Color::Rgb(147, 161, 161);
    let yellow = Color::Rgb(181, 137, 0);
    let red = Color::Rgb(220, 50, 47);
    let green = Color::Rgb(133, 153, 0);
    let blue = Color::Rgb(38, 139, 210);
    let cyan = Color::Rgb(42, 161, 152);

    Theme {
        bg: base3,
        bg_alt: base2,
        bg_selected: Color::Rgb(220, 215, 195),
        bg_gutter: base2,

        fg: base00,
        fg_dim: base1,
        fg_bright: base01,

        border: base1,
        border_focused: green,

        diff_add_fg: Color::Rgb(40, 100, 0),
        diff_add_bg: Color::Rgb(230, 245, 220),
        diff_del_fg: Color::Rgb(160, 30, 30),
        diff_del_bg: Color::Rgb(255, 230, 230),
        diff_context_fg: base00,
        diff_hunk_header_fg: blue,
        diff_hunk_header_bg: base2,
        diff_hunk_selected_bg: Color::Rgb(200, 220, 240),
        diff_hot_bg: Color::Rgb(255, 245, 200),

        status_added: green,
        status_modified: yellow,
        status_deleted: red,
        status_renamed: cyan,
        status_untracked: base1,
        status_staged: green,

        selection_bg: Color::Rgb(180, 210, 240),

        bar_bg: base2,
        bar_fg: base00,
        bar_accent: cyan,

        overlay_bg: base2,
        overlay_border: yellow,
        overlay_fg: base00,

        error: red,
    }
}

// ── Monokai Dark ────────────────────────────────────────────

fn monokai_dark() -> Theme {
    let bg = Color::Rgb(39, 40, 34);
    let bg_lighter = Color::Rgb(53, 54, 48);
    let fg = Color::Rgb(248, 248, 242);
    let fg_dim = Color::Rgb(117, 113, 94);
    let yellow = Color::Rgb(230, 219, 116);
    let red = Color::Rgb(249, 38, 114);
    let green = Color::Rgb(166, 226, 46);
    let blue = Color::Rgb(102, 217, 239);
    let orange = Color::Rgb(253, 151, 31);
    let purple = Color::Rgb(174, 129, 255);

    Theme {
        bg,
        bg_alt: bg_lighter,
        bg_selected: Color::Rgb(73, 72, 62),
        bg_gutter: bg_lighter,

        fg,
        fg_dim,
        fg_bright: Color::Rgb(255, 255, 255),

        border: fg_dim,
        border_focused: green,

        diff_add_fg: green,
        diff_add_bg: Color::Rgb(35, 65, 20),
        diff_del_fg: red,
        diff_del_bg: Color::Rgb(65, 20, 25),
        diff_context_fg: fg,
        diff_hunk_header_fg: blue,
        diff_hunk_header_bg: bg_lighter,
        diff_hunk_selected_bg: Color::Rgb(55, 70, 80),
        diff_hot_bg: Color::Rgb(70, 55, 10),

        status_added: green,
        status_modified: orange,
        status_deleted: red,
        status_renamed: blue,
        status_untracked: fg_dim,
        status_staged: green,

        selection_bg: Color::Rgb(50, 55, 80),

        bar_bg: Color::Rgb(30, 31, 28),
        bar_fg: fg,
        bar_accent: purple,

        overlay_bg: bg_lighter,
        overlay_border: orange,
        overlay_fg: fg,

        error: red,
    }
}

// ── Monokai Light ───────────────────────────────────────────

fn monokai_light() -> Theme {
    let bg = Color::Rgb(253, 252, 248);
    let bg_alt = Color::Rgb(240, 239, 234);
    let fg = Color::Rgb(55, 53, 47);
    let fg_dim = Color::Rgb(150, 147, 140);
    let yellow = Color::Rgb(176, 150, 0);
    let red = Color::Rgb(200, 30, 80);
    let green = Color::Rgb(80, 145, 15);
    let blue = Color::Rgb(30, 145, 180);
    let orange = Color::Rgb(200, 110, 0);
    let purple = Color::Rgb(120, 80, 200);

    Theme {
        bg,
        bg_alt,
        bg_selected: Color::Rgb(225, 224, 218),
        bg_gutter: bg_alt,

        fg,
        fg_dim,
        fg_bright: Color::Rgb(30, 30, 30),

        border: fg_dim,
        border_focused: green,

        diff_add_fg: green,
        diff_add_bg: Color::Rgb(230, 248, 220),
        diff_del_fg: red,
        diff_del_bg: Color::Rgb(255, 225, 232),
        diff_context_fg: fg,
        diff_hunk_header_fg: blue,
        diff_hunk_header_bg: bg_alt,
        diff_hunk_selected_bg: Color::Rgb(210, 230, 248),
        diff_hot_bg: Color::Rgb(255, 245, 200),

        status_added: green,
        status_modified: yellow,
        status_deleted: red,
        status_renamed: blue,
        status_untracked: fg_dim,
        status_staged: green,

        selection_bg: Color::Rgb(190, 215, 245),

        bar_bg: bg_alt,
        bar_fg: fg,
        bar_accent: purple,

        overlay_bg: bg_alt,
        overlay_border: orange,
        overlay_fg: fg,

        error: red,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_themes_construct() {
        for name in [
            ThemeName::SolarizedDark,
            ThemeName::SolarizedLight,
            ThemeName::MonokaiDark,
            ThemeName::MonokaiLight,
        ] {
            let t = name.theme();
            // Ensure no fields are accidentally the same as bg
            // (catch copy-paste errors in theme definitions)
            assert_ne!(t.fg, t.bg, "{:?} fg == bg", name);
            assert_ne!(t.diff_add_fg, t.diff_del_fg, "{:?} add == del", name);
        }
    }

    #[test]
    fn theme_cycle() {
        let start = ThemeName::SolarizedDark;
        let mut current = start;
        for _ in 0..4 {
            current = current.next();
        }
        assert_eq!(current, start); // cycles back
    }

    #[test]
    fn theme_labels() {
        assert_eq!(ThemeName::SolarizedDark.label(), "solarized dark");
        assert_eq!(ThemeName::MonokaiDark.label(), "monokai dark");
    }

    #[test]
    fn diff_backgrounds_are_tinted() {
        for name in [
            ThemeName::SolarizedDark,
            ThemeName::SolarizedLight,
            ThemeName::MonokaiDark,
            ThemeName::MonokaiLight,
        ] {
            let t = name.theme();
            // Add bg should be greenish, del bg should be reddish
            if let (Color::Rgb(r, g, b)) = t.diff_add_bg {
                assert!(g > r, "{:?} add_bg should be green-tinted", name);
            }
            if let (Color::Rgb(r, g, b)) = t.diff_del_bg {
                assert!(r > g, "{:?} del_bg should be red-tinted", name);
            }
        }
    }
}

const std = @import("std");

pub const Token = struct {
    kind: Kind,
    lexeme: []const u8,
    line: u32,
    col: u32,

    pub const Kind = enum {
        // Literals
        integer,
        float,
        string,
        atom,
        true_lit,
        false_lit,
        nil_lit,

        // Identifiers
        identifier,
        upper_identifier, // PascalCase for actor names

        // Keywords
        kw_actor,
        kw_do,
        kw_end,
        kw_state,
        kw_on,
        kw_become,
        kw_reply,
        kw_when,
        kw_def,

        // Operators
        plus,
        minus,
        star,
        slash,
        eq,
        eq_eq,
        bang,
        bang_eq,
        lt,
        gt,
        lt_eq,
        gt_eq,
        pipe_arrow, // |>
        send_arrow, // <-
        pipe_pipe, // ||
        amp_amp, // &&
        pipe, // | (for cons in lists)
        dot, // .

        // Delimiters
        lparen,
        rparen,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        comma,
        colon,
        percent, // % (for map literals %{})

        // Special
        newline,
        eof,
        invalid,
    };

    /// Check if a lexeme is a keyword, return the keyword kind or null.
    pub fn keyword(lexeme: []const u8) ?Kind {
        const keywords = std.StaticStringMap(Kind).initComptime(.{
            .{ "actor", .kw_actor },
            .{ "do", .kw_do },
            .{ "end", .kw_end },
            .{ "state", .kw_state },
            .{ "on", .kw_on },
            .{ "become", .kw_become },
            .{ "reply", .kw_reply },
            .{ "when", .kw_when },
            .{ "def", .kw_def },
            .{ "true", .true_lit },
            .{ "false", .false_lit },
            .{ "nil", .nil_lit },
        });
        return keywords.get(lexeme);
    }
};

const std = @import("std");
const Value = @import("value.zig").Value;
const Environment = @import("env.zig").Environment;

/// A rich, Elm-style error with source context, explanation, and hints.
pub const BlimpError = struct {
    title: []const u8,
    source_line: ?[]const u8 = null,
    col: ?u32 = null,
    message: []const u8,
    hint: ?[]const u8 = null,

    /// Format the error in Elm style to the given writer.
    pub fn format(self: BlimpError, writer: anytype) void {
        // Title bar
        writer.writeAll("\n\x1b[36m-- ") catch {};
        writer.writeAll(self.title) catch {};
        writer.writeAll(" ") catch {};
        // Fill with dashes
        const title_len = self.title.len + 4;
        const dash_count = if (title_len < 50) 50 - title_len else 5;
        for (0..dash_count) |_| {
            writer.writeAll("\xe2\x94\x80") catch {};
        }
        writer.writeAll("\x1b[0m\n\n") catch {};

        // Source line with caret
        if (self.source_line) |src| {
            writer.writeAll("  \x1b[90m") catch {};
            writer.writeAll(src) catch {};
            writer.writeAll("\x1b[0m\n") catch {};

            if (self.col) |c| {
                // Caret pointing at the problem
                for (0..c + 1) |_| {
                    writer.writeAll(" ") catch {};
                }
                writer.writeAll("\x1b[31m^\x1b[0m\n") catch {};
            }
        }

        // Message
        writer.writeAll("  ") catch {};
        writer.writeAll(self.message) catch {};
        writer.writeAll("\n") catch {};

        // Hint
        if (self.hint) |h| {
            writer.writeAll("\n  \x1b[33m") catch {};
            writer.writeAll(h) catch {};
            writer.writeAll("\x1b[0m\n") catch {};
        }

        writer.writeAll("\n") catch {};
    }

    /// Format without ANSI colors (for piped/non-TTY output).
    pub fn formatPlain(self: BlimpError, writer: anytype) void {
        writer.writeAll("\n-- ") catch {};
        writer.writeAll(self.title) catch {};
        writer.writeAll(" ") catch {};
        const title_len = self.title.len + 4;
        const dash_count = if (title_len < 50) 50 - title_len else 5;
        for (0..dash_count) |_| {
            writer.writeAll("-") catch {};
        }
        writer.writeAll("\n\n") catch {};

        if (self.source_line) |src| {
            writer.writeAll("  ") catch {};
            writer.writeAll(src) catch {};
            writer.writeAll("\n") catch {};

            if (self.col) |c| {
                for (0..c + 1) |_| {
                    writer.writeAll(" ") catch {};
                }
                writer.writeAll("^\n") catch {};
            }
        }

        writer.writeAll("  ") catch {};
        writer.writeAll(self.message) catch {};
        writer.writeAll("\n") catch {};

        if (self.hint) |h| {
            writer.writeAll("\n  Hint: ") catch {};
            writer.writeAll(h) catch {};
            writer.writeAll("\n") catch {};
        }

        writer.writeAll("\n") catch {};
    }
};

/// Build a rich error for an undefined variable, suggesting similar names.
pub fn undefinedVariable(name: []const u8, source: []const u8, env: *const Environment, allocator: std.mem.Allocator) BlimpError {
    const bindings = env.allBindings(allocator);

    var hint_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };

    if (bindings.len > 0) {
        hint_buf.appendSlice(allocator, "Variables in scope:\n") catch {};
        for (bindings) |binding| {
            hint_buf.appendSlice(allocator, "      ") catch {};
            hint_buf.appendSlice(allocator, binding.name) catch {};
            hint_buf.appendSlice(allocator, " = ") catch {};
            binding.val.format(hint_buf.writer(allocator));
            hint_buf.appendSlice(allocator, "\n") catch {};
        }
    } else {
        hint_buf.appendSlice(allocator, "No variables defined yet. Try:\n      x = 42") catch {};
    }

    var msg_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    msg_buf.appendSlice(allocator, "I can't find a variable called `") catch {};
    msg_buf.appendSlice(allocator, name) catch {};
    msg_buf.appendSlice(allocator, "`.") catch {};

    return .{
        .title = "UNDEFINED VARIABLE",
        .source_line = source,
        .message = msg_buf.items,
        .hint = hint_buf.items,
    };
}

/// Build a rich error for a type error in a binary operation.
pub fn typeMismatch(source: []const u8) BlimpError {
    return .{
        .title = "TYPE MISMATCH",
        .source_line = source,
        .message = "I can't do this operation because the types don't match.",
        .hint = "Both sides of an operator need to be the same type (Int, Float, or String).",
    };
}

/// Build a rich error for division by zero.
pub fn divisionByZero(source: []const u8) BlimpError {
    return .{
        .title = "DIVISION BY ZERO",
        .source_line = source,
        .message = "You're dividing by zero, which isn't defined.",
        .hint = "Check the denominator before dividing.",
    };
}

/// Build a rich error for unsupported actor constructs in the REPL.
pub fn notSupportedInRepl(keyword: []const u8, source: []const u8) BlimpError {
    return .{
        .title = "NOT AVAILABLE HERE",
        .source_line = source,
        .message = std.fmt.allocPrint(std.heap.page_allocator, "`{s}` can only be used inside an actor definition.", .{keyword}) catch "This construct isn't available here.",
        .hint = "Define an actor first:\n      actor Counter do\n        state count: Int :: 0\n        on :increment do ... end\n      end",
    };
}

/// Build a rich error for an unknown function.
pub fn unknownFunction(name: []const u8, source: []const u8) BlimpError {
    return .{
        .title = "UNKNOWN FUNCTION",
        .source_line = source,
        .message = std.fmt.allocPrint(std.heap.page_allocator, "I don't know a function called `{s}`.", .{name}) catch "Unknown function.",
        .hint = "Built-in functions:\n      length, max, min, append, reverse,\n      lookup, put, keys, now",
    };
}

/// Build a rich error when an actor has no matching handler for a message.
pub fn noMatchingHandler(actor_name: []const u8, message_name: []const u8, source: []const u8) BlimpError {
    return .{
        .title = "NO MATCHING HANDLER",
        .source_line = source,
        .message = std.fmt.allocPrint(std.heap.page_allocator, "Actor {s} has no handler for :{s}.", .{ actor_name, message_name }) catch "No matching handler.",
        .hint = "Define a handler with:\n      on :message_name do ... end",
    };
}

/// Build a rich error when become is used outside a message handler.
pub fn becomeOutsideHandler(source: []const u8) BlimpError {
    return .{
        .title = "BECOME OUTSIDE HANDLER",
        .source_line = source,
        .message = "become can only be used inside a message handler.",
        .hint = "Use become inside an on :message do ... end block.",
    };
}

/// Build a rich error when reply is used outside a message handler.
pub fn replyOutsideHandler(source: []const u8) BlimpError {
    return .{
        .title = "REPLY OUTSIDE HANDLER",
        .source_line = source,
        .message = "reply can only be used inside a message handler.",
        .hint = "Use reply inside an on :message do ... end block.",
    };
}

/// Build a rich error when a message send target is not an actor.
pub fn notAnActor(source: []const u8) BlimpError {
    return .{
        .title = "NOT AN ACTOR",
        .source_line = source,
        .message = "Message send target is not an actor.",
        .hint = "The left side of <- must be an actor instance.",
    };
}

/// Build a rich error when a handler receives the wrong number of arguments.
pub fn wrongArgCount(handler_name: []const u8, expected: usize, got: usize, source: []const u8) BlimpError {
    return .{
        .title = "WRONG ARGUMENT COUNT",
        .source_line = source,
        .message = std.fmt.allocPrint(std.heap.page_allocator, "Handler :{s} expects {d} argument(s), got {d}.", .{ handler_name, expected, got }) catch "Wrong number of arguments.",
        .hint = null,
    };
}

/// Build a rich error when no actor template is found for a spawn.
pub fn templateNotFound(name: []const u8, source: []const u8) BlimpError {
    return .{
        .title = "TEMPLATE NOT FOUND",
        .source_line = source,
        .message = std.fmt.allocPrint(std.heap.page_allocator, "No actor template called `{s}` is defined.", .{name}) catch "Template not found.",
        .hint = "Define an actor first:\n      actor Counter do\n        state count: Int :: 0\n        on :increment do ... end\n      end",
    };
}

/// Build a rich error when an actor template is already defined.
pub fn alreadyDefined(name: []const u8, source: []const u8) BlimpError {
    return .{
        .title = "ALREADY DEFINED",
        .source_line = source,
        .message = std.fmt.allocPrint(std.heap.page_allocator, "Actor template `{s}` is already defined.", .{name}) catch "Template already defined.",
        .hint = "Each actor name can only be defined once per program.",
    };
}

/// Build a rich error for a parse error, detecting common mistakes.
pub fn parseError(source: []const u8) BlimpError {
    // Check for common keyword-as-variable mistakes
    // Note: "actor" is now supported in the REPL via multi-line input
    const keywords = [_][]const u8{ "state", "on", "become", "reply", "do", "end", "when", "bubbles", "situation", "case", "orelse", "def" };
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, source, kw)) {
            return notSupportedInRepl(kw, source);
        }
    }

    return .{
        .title = "PARSE ERROR",
        .source_line = source,
        .message = "I couldn't understand this expression.",
        .hint = "Try a simpler expression:\n      42\n      x = [1, 2, 3]\n      length(x)",
    };
}

const std = @import("std");
const Value = @import("value.zig").Value;
const Environment = @import("env.zig").Environment;

/// A rich, Elm-style error with source context, explanation, and hints.
pub const BlimpError = struct {
    title: []const u8,
    source_line: ?[]const u8 = null,
    line: ?u32 = null,
    col: ?u32 = null,
    col_end: ?u32 = null, // end column for region underline
    message: []const u8, // shown BEFORE the code snippet
    post_message: ?[]const u8 = null, // shown AFTER the code snippet
    hint: ?[]const u8 = null,

    /// Format the error in Elm style to the given writer.
    pub fn format(self: BlimpError, writer: anytype) void {
        // Title bar
        writer.writeAll("\n\x1b[36m-- ") catch {};
        writer.writeAll(self.title) catch {};
        writer.writeAll(" ") catch {};
        const title_len = self.title.len + 4;
        const dash_count = if (title_len < 50) 50 - title_len else 5;
        for (0..dash_count) |_| {
            writer.writeAll("\xe2\x94\x80") catch {};
        }
        writer.writeAll("\x1b[0m\n\n") catch {};

        // Pre-message (explanation BEFORE the code)
        writer.writeAll("  ") catch {};
        writer.writeAll(self.message) catch {};
        writer.writeAll("\n\n") catch {};

        // Source line with line number gutter + region underline
        if (self.source_line) |src| {
            if (self.line) |ln| {
                writer.print("\x1b[90m{d}|\x1b[0m ", .{ln}) catch {};
            } else {
                writer.writeAll("  ") catch {};
            }
            writer.writeAll("\x1b[91m") catch {};
            writer.writeAll(src) catch {};
            writer.writeAll("\x1b[0m\n") catch {};

            if (self.col) |c| {
                const gutter = if (self.line != null) @as(usize, 4) else @as(usize, 2);
                for (0..c + gutter) |_| {
                    writer.writeAll(" ") catch {};
                }
                // Region underline: ^^^^ if col_end is set, else single ^
                if (self.col_end) |ce| {
                    const span = if (ce > c) ce - c else 1;
                    writer.writeAll("\x1b[31m") catch {};
                    for (0..span) |_| {
                        writer.writeAll("^") catch {};
                    }
                    writer.writeAll("\x1b[0m\n") catch {};
                } else {
                    writer.writeAll("\x1b[31m^\x1b[0m\n") catch {};
                }
            }
        }

        // Post-message (explanation AFTER the code)
        if (self.post_message) |pm| {
            writer.writeAll("\n  ") catch {};
            writer.writeAll(pm) catch {};
            writer.writeAll("\n") catch {};
        }

        // Hint
        if (self.hint) |h| {
            writer.writeAll("\n  \x1b[33mHint: ") catch {};
            writer.writeAll(h) catch {};
            writer.writeAll("\x1b[0m\n") catch {};
        }

        writer.writeAll("\n") catch {};
    }

    /// Format to stderr using std.debug.print (no writer needed).
    pub fn formatStderr(self: BlimpError) void {
        // Title bar
        std.debug.print("\n\x1b[36m-- {s} ", .{self.title});
        const title_len = self.title.len + 4;
        const dash_count = if (title_len < 60) 60 - title_len else 5;
        for (0..dash_count) |_| std.debug.print("\xe2\x94\x80", .{});
        std.debug.print("\x1b[0m\n\n", .{});

        // Pre-message
        std.debug.print("  {s}\n\n", .{self.message});

        // Source line with line number + region underline
        if (self.source_line) |src| {
            if (self.line) |ln| {
                std.debug.print("\x1b[90m{d}|\x1b[0m \x1b[91m{s}\x1b[0m\n", .{ ln, src });
            } else {
                std.debug.print("  \x1b[91m{s}\x1b[0m\n", .{src});
            }

            if (self.col) |col| {
                const gutter: usize = if (self.line != null) 4 else 2;
                for (0..col + gutter) |_| std.debug.print(" ", .{});
                if (self.col_end) |ce| {
                    const span = if (ce > col) ce - col else 1;
                    std.debug.print("\x1b[31m", .{});
                    for (0..span) |_| std.debug.print("^", .{});
                    std.debug.print("\x1b[0m\n", .{});
                } else {
                    std.debug.print("\x1b[31m^\x1b[0m\n", .{});
                }
            }
        }

        // Post-message
        if (self.post_message) |pm| {
            std.debug.print("\n  {s}\n", .{pm});
        }

        // Hint
        if (self.hint) |h| {
            std.debug.print("\n  \x1b[33mHint: {s}\x1b[0m\n", .{h});
        }

        std.debug.print("\n", .{});
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

        // Pre-message
        writer.writeAll("  ") catch {};
        writer.writeAll(self.message) catch {};
        writer.writeAll("\n\n") catch {};

        // Source with gutter + region underline
        if (self.source_line) |src| {
            if (self.line) |ln| {
                writer.print("{d}| ", .{ln}) catch {};
            } else {
                writer.writeAll("  ") catch {};
            }
            writer.writeAll(src) catch {};
            writer.writeAll("\n") catch {};

            if (self.col) |c| {
                const gutter = if (self.line != null) @as(usize, 4) else @as(usize, 2);
                for (0..c + gutter) |_| {
                    writer.writeAll(" ") catch {};
                }
                if (self.col_end) |ce| {
                    const span = if (ce > c) ce - c else 1;
                    for (0..span) |_| {
                        writer.writeAll("^") catch {};
                    }
                    writer.writeAll("\n") catch {};
                } else {
                    writer.writeAll("^\n") catch {};
                }
            }
        }

        // Post-message
        if (self.post_message) |pm| {
            writer.writeAll("\n  ") catch {};
            writer.writeAll(pm) catch {};
            writer.writeAll("\n") catch {};
        }

        if (self.hint) |h| {
            writer.writeAll("\n  Hint: ") catch {};
            writer.writeAll(h) catch {};
            writer.writeAll("\n") catch {};
        }

        writer.writeAll("\n") catch {};
    }
};

/// Simple edit distance for "did you mean?" suggestions
fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    // Simple approach for short strings
    if (a.len > 20 or b.len > 20) return 100;

    var prev_row: [21]usize = undefined;
    var curr_row: [21]usize = undefined;

    for (0..b.len + 1) |j| prev_row[j] = j;

    for (a, 0..) |ca, i| {
        curr_row[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            curr_row[j + 1] = @min(@min(curr_row[j] + 1, prev_row[j + 1] + 1), prev_row[j] + cost);
        }
        for (0..b.len + 1) |j| prev_row[j] = curr_row[j];
    }
    return prev_row[b.len];
}

/// Build a rich error for an undefined variable, suggesting similar names.
pub fn undefinedVariable(name: []const u8, source: []const u8, env: *const Environment, allocator: std.mem.Allocator) BlimpError {
    const bindings = env.allBindings(allocator);

    var hint_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };

    // Find the closest match for "Did you mean?"
    var best_match: ?[]const u8 = null;
    var best_dist: usize = 100;
    for (bindings) |binding| {
        const dist = editDistance(name, binding.name);
        if (dist < best_dist and dist <= 3) {
            best_dist = dist;
            best_match = binding.name;
        }
    }

    if (best_match) |match| {
        hint_buf.appendSlice(allocator, "Did you mean `") catch {};
        hint_buf.appendSlice(allocator, match) catch {};
        hint_buf.appendSlice(allocator, "`?\n\n") catch {};
    }

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

    // Detect common other-language keywords used as variables
    if (std.mem.eql(u8, name, "return")) {
        return .{
            .title = "NO RETURN KEYWORD",
            .source_line = source,
            .message = "Blimp doesn't use `return`. The last expression in a block is the return value.",
            .hint = "Just write the value:\n      def add(a, b) do\n        a + b\n      end",
        };
    }
    if (std.mem.eql(u8, name, "class")) {
        return .{
            .title = "NO CLASSES",
            .source_line = source,
            .message = "Blimp doesn't have classes. Use actors instead.",
            .hint = "Actors are Blimp's unit of encapsulation:\n      actor Counter do\n        state count: Int :: 0\n        on :increment do ... end\n      end",
        };
    }
    if (std.mem.eql(u8, name, "function")) {
        return .{
            .title = "USE DEF OR FN",
            .source_line = source,
            .message = "Blimp uses `def` for named functions and `fn` for anonymous functions.",
            .hint = "Named:     def add(a, b) do a + b end\n      Anonymous: fn(x) do x * 2 end",
        };
    }
    if (std.mem.eql(u8, name, "var") or std.mem.eql(u8, name, "let") or std.mem.eql(u8, name, "const")) {
        return .{
            .title = "NO VAR/LET/CONST",
            .source_line = source,
            .message = "Blimp doesn't need variable declaration keywords.",
            .hint = "Just assign directly:\n      x = 42\n      name = \"hello\"",
        };
    }
    if (std.mem.eql(u8, name, "if")) {
        return .{
            .title = "USE SITUATION",
            .source_line = source,
            .message = "Blimp doesn't have `if`. Use `situation` for branching.",
            .hint = "situation condition do\n        true -> do_this\n        _ -> do_that\n      end",
        };
    }
    if (std.mem.eql(u8, name, "while") or std.mem.eql(u8, name, "loop")) {
        return .{
            .title = "USE FOR",
            .source_line = source,
            .message = "Blimp doesn't have `while` or `loop`. Use `for` to iterate.",
            .hint = "for x in range(1, 10) do\n        x * 2\n      end",
        };
    }

    var msg_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    msg_buf.appendSlice(allocator, "I can't find a variable called `") catch {};
    msg_buf.appendSlice(allocator, name) catch {};
    msg_buf.appendSlice(allocator, "`.") catch {};

    // Post-message with "did you mean" suggestion
    var post: ?[]const u8 = null;
    if (best_match) |match| {
        var post_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        post_buf.appendSlice(allocator, "Did you mean `") catch {};
        post_buf.appendSlice(allocator, match) catch {};
        post_buf.appendSlice(allocator, "`?") catch {};
        post = post_buf.items;
    }

    return .{
        .title = "UNDEFINED VARIABLE",
        .source_line = source,
        .col_end = if (name.len > 0) @as(u32, @intCast(name.len)) else null,
        .message = msg_buf.items,
        .post_message = post,
        .hint = hint_buf.items,
    };
}

/// Build a rich error for a type error in a binary operation.
pub fn typeMismatch(source: []const u8) BlimpError {
    return .{
        .title = "TYPE MISMATCH",
        .source_line = source,
        .message = "I can't do this operation because the types don't match.",
        .hint = "Both sides of an operator need to be compatible types.\n\n" ++
            "      Int + Int       => Int\n" ++
            "      Float + Float   => Float\n" ++
            "      String + String => String (use ++ for lists)\n" ++
            "      Int + Float     => Float (auto-promoted)",
    };
}

/// Build a rich error with specific left/right types shown, with operator-specific advice.
pub fn typeMismatchDetailed(left_type: []const u8, right_type: []const u8, op: []const u8, source: []const u8) BlimpError {
    const alloc = std.heap.page_allocator;

    // Operator-specific advice (inspired by Elm)
    var post: ?[]const u8 = null;
    if (std.mem.eql(u8, op, "+")) {
        if (std.mem.eql(u8, left_type, "String") or std.mem.eql(u8, right_type, "String")) {
            post = "The `+` operator works with Int and Float values.\nTo join strings, use `++` or `concat`:\n      \"hello\" ++ \" world\"";
        } else if (std.mem.eql(u8, left_type, "List") or std.mem.eql(u8, right_type, "List")) {
            post = "To join lists, use the `++` operator:\n      [1, 2] ++ [3, 4]";
        }
    } else if (std.mem.eql(u8, op, "++")) {
        post = "The `++` operator joins lists or strings.\nBoth sides must be the same type:\n      [1, 2] ++ [3, 4]     # lists\n      \"hi\" ++ \" there\"     # strings";
    } else if (std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "/")) {
        if (std.mem.eql(u8, left_type, "String") or std.mem.eql(u8, right_type, "String")) {
            post = "Arithmetic operators only work with numbers.\nTo convert a string to a number, use `to_int`:\n      to_int(\"42\") + 1";
        }
    } else if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) {
        post = "Equality comparison works between values of the same type.\nUse `to_string` or `to_int` to convert first.";
    }

    return .{
        .title = "TYPE MISMATCH",
        .source_line = source,
        .message = std.fmt.allocPrint(alloc, "I can't use `{s}` with {s} on the left and {s} on the right.", .{ op, left_type, right_type }) catch "Types don't match.",
        .post_message = post,
        .hint = "Both sides need to be compatible types.",
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
    // Check for close matches among builtins
    const builtins = [_][]const u8{
        "length",  "max",     "min",      "append",  "reverse",
        "lookup",  "put",     "keys",     "now",     "concat",
        "split",   "contains", "to_string", "to_int", "slice",
        "upcase",  "downcase", "range",    "head",    "tail",
        "sort",    "merge",   "values",   "type_of",  "print",
        "rem",     "abs",     "nil?",     "elem",    "floor",
        "ceil",    "round",   "not",      "size",    "empty?",
        "flat",    "zip",     "uniq",     "sum",
        "map",     "filter",  "reduce",   "each",
    };

    var best_match: ?[]const u8 = null;
    var best_dist: usize = 100;
    for (builtins) |b| {
        const dist = editDistance(name, b);
        if (dist < best_dist and dist <= 3) {
            best_dist = dist;
            best_match = b;
        }
    }

    var hint = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    const alloc = std.heap.page_allocator;
    if (best_match) |match| {
        hint.appendSlice(alloc, "Did you mean `") catch {};
        hint.appendSlice(alloc, match) catch {};
        hint.appendSlice(alloc, "`?\n\n") catch {};
    }
    hint.appendSlice(alloc, "Built-in functions:\n      length, max, min, append, reverse, lookup, put,\n      keys, now, concat, split, contains, to_string,\n      to_int, slice, upcase, downcase, range, head, tail,\n      sort, merge, values, type_of, print, rem, abs,\n      nil?, elem, floor, ceil, round, not, size, empty?,\n      flat, zip, uniq, sum, map, filter, reduce, each") catch {};

    return .{
        .title = "UNKNOWN FUNCTION",
        .source_line = source,
        .message = std.fmt.allocPrint(alloc, "I don't know a function called `{s}`.", .{name}) catch "Unknown function.",
        .hint = hint.items,
    };
}

/// Build a rich error when trying to call a non-callable value.
pub fn notCallable(source: []const u8) BlimpError {
    return .{
        .title = "NOT CALLABLE",
        .source_line = source,
        .message = "This value is not a function and cannot be called.",
        .hint = "Define a function with:\n      fn(x, y) do ... end",
    };
}

/// Build a rich error when an actor has no matching handler for a message.
pub fn noMatchingHandler(actor_name: []const u8, message_name: []const u8, source: []const u8) BlimpError {
    const alloc = std.heap.page_allocator;

    // Check for close match in message name
    var hint_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };

    hint_buf.appendSlice(alloc, "Actor `") catch {};
    hint_buf.appendSlice(alloc, actor_name) catch {};
    hint_buf.appendSlice(alloc, "` has no handler for `:") catch {};
    hint_buf.appendSlice(alloc, message_name) catch {};
    hint_buf.appendSlice(alloc, "`.\n\n") catch {};
    hint_buf.appendSlice(alloc, "Define a handler with:\n      on :") catch {};
    hint_buf.appendSlice(alloc, message_name) catch {};
    hint_buf.appendSlice(alloc, " do ... end") catch {};

    return .{
        .title = "NO MATCHING HANDLER",
        .source_line = source,
        .message = std.fmt.allocPrint(alloc, "I tried to send :{s} to this actor, but it doesn't know how to handle it.", .{message_name}) catch "No matching handler.",
        .hint = hint_buf.items,
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
    const keywords = [_][]const u8{ "state", "on", "become", "reply", "when", "bubbles" };
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, source, kw)) {
            return notSupportedInRepl(kw, source);
        }
    }

    // Detect other-language operators
    if (std.mem.indexOf(u8, source, "===") != null) {
        return .{
            .title = "UNKNOWN OPERATOR",
            .source_line = source,
            .message = "Blimp does not have a `===` operator like JavaScript.",
            .hint = "Use `==` instead. In Blimp, `==` does structural equality.",
        };
    }
    if (std.mem.indexOf(u8, source, "!==") != null) {
        return .{
            .title = "UNKNOWN OPERATOR",
            .source_line = source,
            .message = "Blimp does not have a `!==` operator like JavaScript.",
            .hint = "Use `!=` instead.",
        };
    }
    if (std.mem.indexOf(u8, source, "**") != null) {
        return .{
            .title = "UNKNOWN OPERATOR",
            .source_line = source,
            .message = "Blimp does not have a `**` exponentiation operator like Python.",
            .hint = "Use a function like `pow(base, exp)` instead (not yet built-in).",
        };
    }
    if (std.mem.indexOf(u8, source, "elsif") != null or std.mem.indexOf(u8, source, "elif") != null) {
        return .{
            .title = "NO ELSIF/ELIF",
            .source_line = source,
            .message = "Blimp doesn't have elsif or elif.",
            .hint = "Use `situation` for branching:\n      situation condition do\n        true -> first_thing\n        _ -> other_thing\n      end",
        };
    }
    if (std.mem.indexOf(u8, source, "return ") != null) {
        return .{
            .title = "NO RETURN KEYWORD",
            .source_line = source,
            .message = "Blimp doesn't use `return`. The last expression in a block is the return value.",
            .hint = "Just write the value:\n      def add(a, b) do\n        a + b\n      end",
        };
    }
    if (std.mem.indexOf(u8, source, "class ") != null) {
        return .{
            .title = "NO CLASSES",
            .source_line = source,
            .message = "Blimp doesn't have classes. Use actors instead.",
            .hint = "Actors are Blimp's unit of encapsulation:\n      actor Counter do\n        state count: Int :: 0\n        on :increment do ... end\n      end",
        };
    }
    if (std.mem.indexOf(u8, source, "function ") != null) {
        return .{
            .title = "USE DEF OR FN",
            .source_line = source,
            .message = "Blimp uses `def` for named functions and `fn` for anonymous functions.",
            .hint = "Named:     def add(a, b) do a + b end\n      Anonymous: fn(x) do x * 2 end",
        };
    }

    return .{
        .title = "PARSE ERROR",
        .source_line = source,
        .message = "I couldn't understand this expression.",
        .hint = "Try a simpler expression:\n      42\n      x = [1, 2, 3]\n      length(x)",
    };
}

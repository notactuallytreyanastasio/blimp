/// Tests for errors.zig - run with: zig test src/errors_test.zig -target x86_64-macos
///
/// Note: unknownFunction and noMatchingHandler use the pre-0.14 ArrayList API
/// and cannot be tested until the source is updated. All other functions are tested here.
const std = @import("std");
const errors = @import("errors.zig");
const BlimpError = errors.BlimpError;

// ============================================================
// formatPlain - no ANSI codes, easy to assert on
// ============================================================

test "formatPlain includes title" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "TYPE MISMATCH",
        .message = "Types don't match.",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "TYPE MISMATCH") != null);
}

test "formatPlain includes message" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "SOME ERROR",
        .message = "Something went wrong here.",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "Something went wrong here.") != null);
}

test "formatPlain includes source line" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "PARSE ERROR",
        .source_line = "x = 1 + \"hello\"",
        .message = "Types don't match.",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "x = 1 + \"hello\"") != null);
}

test "formatPlain includes line number" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "ERROR",
        .source_line = "foo",
        .line = 5,
        .message = "msg",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "5|") != null);
}

test "formatPlain single caret when no col_end" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "ERROR",
        .source_line = "foo bar",
        .col = 0,
        .message = "msg",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "^") != null);
}

test "formatPlain region underline with col_end" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "ERROR",
        .source_line = "foo bar baz",
        .col = 0,
        .col_end = 3,
        .message = "msg",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "^^^") != null);
}

test "formatPlain includes hint" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "ERROR",
        .message = "msg",
        .hint = "Try using `def` instead.",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "Hint:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Try using `def` instead.") != null);
}

test "formatPlain includes post_message" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "ERROR",
        .message = "pre",
        .post_message = "Did you mean `foo`?",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "Did you mean `foo`?") != null);
}

test "formatPlain no source line omits gutter" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "ERROR",
        .message = "no source",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    // No | character from a line number gutter
    try std.testing.expect(std.mem.indexOf(u8, out, "|") == null);
}

test "formatPlain title separator dashes are present" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const err = BlimpError{
        .title = "X",
        .message = "m",
    };
    err.formatPlain(stream.writer());
    const out = stream.getWritten();
    // Should have at least 5 dashes after title
    try std.testing.expect(std.mem.indexOf(u8, out, "-----") != null);
}

// ============================================================
// Error builder functions (functions that compile cleanly)
// ============================================================

test "typeMismatch has correct title" {
    const err = errors.typeMismatch("1 + \"hello\"");
    try std.testing.expectEqualStrings("TYPE MISMATCH", err.title);
}

test "typeMismatch source_line is set" {
    const err = errors.typeMismatch("1 + \"hello\"");
    try std.testing.expectEqualStrings("1 + \"hello\"", err.source_line.?);
}

test "typeMismatch has a hint" {
    const err = errors.typeMismatch("x");
    try std.testing.expect(err.hint != null);
}

test "typeMismatchDetailed title" {
    const err = errors.typeMismatchDetailed("Int", "String", "+", "1 + \"x\"");
    try std.testing.expectEqualStrings("TYPE MISMATCH", err.title);
}

test "typeMismatchDetailed message contains types and op" {
    const err = errors.typeMismatchDetailed("Int", "String", "+", "1 + \"x\"");
    try std.testing.expect(std.mem.indexOf(u8, err.message, "Int") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "String") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "+") != null);
}

test "typeMismatchDetailed string + advice mentions ++" {
    const err = errors.typeMismatchDetailed("String", "String", "+", "a + b");
    try std.testing.expect(err.post_message != null);
    try std.testing.expect(std.mem.indexOf(u8, err.post_message.?, "++") != null);
}

test "typeMismatchDetailed list + advice mentions ++" {
    const err = errors.typeMismatchDetailed("List", "Int", "+", "xs + 1");
    try std.testing.expect(err.post_message != null);
    try std.testing.expect(std.mem.indexOf(u8, err.post_message.?, "++") != null);
}

test "typeMismatchDetailed ++ operator post message" {
    const err = errors.typeMismatchDetailed("String", "Int", "++", "s ++ 1");
    try std.testing.expect(err.post_message != null);
}

test "typeMismatchDetailed arithmetic with string" {
    const err = errors.typeMismatchDetailed("String", "Int", "-", "s - 1");
    try std.testing.expect(err.post_message != null);
    try std.testing.expect(std.mem.indexOf(u8, err.post_message.?, "to_int") != null);
}

test "typeMismatchDetailed equality advice present" {
    const err = errors.typeMismatchDetailed("Int", "String", "==", "1 == \"a\"");
    try std.testing.expect(err.post_message != null);
}

test "divisionByZero title" {
    const err = errors.divisionByZero("x / 0");
    try std.testing.expectEqualStrings("DIVISION BY ZERO", err.title);
}

test "divisionByZero source_line" {
    const err = errors.divisionByZero("x / 0");
    try std.testing.expectEqualStrings("x / 0", err.source_line.?);
}

test "divisionByZero has hint" {
    const err = errors.divisionByZero("x / 0");
    try std.testing.expect(err.hint != null);
}

test "notCallable title" {
    const err = errors.notCallable("42()");
    try std.testing.expectEqualStrings("NOT CALLABLE", err.title);
}

test "notCallable source_line" {
    const err = errors.notCallable("42()");
    try std.testing.expectEqualStrings("42()", err.source_line.?);
}

test "becomeOutsideHandler title" {
    const err = errors.becomeOutsideHandler("become x: 1");
    try std.testing.expectEqualStrings("BECOME OUTSIDE HANDLER", err.title);
}

test "becomeOutsideHandler source_line" {
    const err = errors.becomeOutsideHandler("become x: 1");
    try std.testing.expectEqualStrings("become x: 1", err.source_line.?);
}

test "replyOutsideHandler title" {
    const err = errors.replyOutsideHandler("reply 42");
    try std.testing.expectEqualStrings("REPLY OUTSIDE HANDLER", err.title);
}

test "replyOutsideHandler source_line" {
    const err = errors.replyOutsideHandler("reply 42");
    try std.testing.expectEqualStrings("reply 42", err.source_line.?);
}

test "notAnActor title" {
    const err = errors.notAnActor("42 <- :msg");
    try std.testing.expectEqualStrings("NOT AN ACTOR", err.title);
}

test "notAnActor source_line" {
    const err = errors.notAnActor("42 <- :msg");
    try std.testing.expectEqualStrings("42 <- :msg", err.source_line.?);
}

test "wrongArgCount title" {
    const err = errors.wrongArgCount("increment", 0, 2, "counter <- :increment(1, 2)");
    try std.testing.expectEqualStrings("WRONG ARGUMENT COUNT", err.title);
}

test "wrongArgCount message contains handler name" {
    const err = errors.wrongArgCount("add", 2, 3, "add(1, 2, 3)");
    try std.testing.expect(std.mem.indexOf(u8, err.message, "add") != null);
}

test "wrongArgCount message contains expected count" {
    const err = errors.wrongArgCount("add", 2, 3, "add(1, 2, 3)");
    try std.testing.expect(std.mem.indexOf(u8, err.message, "2") != null);
}

test "wrongArgCount message contains actual count" {
    const err = errors.wrongArgCount("add", 2, 3, "add(1, 2, 3)");
    try std.testing.expect(std.mem.indexOf(u8, err.message, "3") != null);
}

test "templateNotFound title" {
    const err = errors.templateNotFound("Foo", "spawn Foo");
    try std.testing.expectEqualStrings("TEMPLATE NOT FOUND", err.title);
}

test "templateNotFound message contains name" {
    const err = errors.templateNotFound("Foo", "spawn Foo");
    try std.testing.expect(std.mem.indexOf(u8, err.message, "Foo") != null);
}

test "templateNotFound has hint with actor example" {
    const err = errors.templateNotFound("Foo", "spawn Foo");
    try std.testing.expect(err.hint != null);
    try std.testing.expect(std.mem.indexOf(u8, err.hint.?, "actor") != null);
}

test "alreadyDefined title" {
    const err = errors.alreadyDefined("Counter", "actor Counter do end");
    try std.testing.expectEqualStrings("ALREADY DEFINED", err.title);
}

test "alreadyDefined message contains name" {
    const err = errors.alreadyDefined("Counter", "actor Counter do end");
    try std.testing.expect(std.mem.indexOf(u8, err.message, "Counter") != null);
}

test "notSupportedInRepl title" {
    const err = errors.notSupportedInRepl("become", "become x: 1");
    try std.testing.expectEqualStrings("NOT AVAILABLE HERE", err.title);
}

test "notSupportedInRepl message contains keyword" {
    const err = errors.notSupportedInRepl("state", "state x: Int :: 0");
    try std.testing.expect(std.mem.indexOf(u8, err.message, "state") != null);
}

// ============================================================
// parseError - detects common mistakes
// ============================================================

test "parseError with === detects JS operator" {
    const err = errors.parseError("a === b");
    try std.testing.expectEqualStrings("UNKNOWN OPERATOR", err.title);
}

test "parseError with !== detects JS operator" {
    const err = errors.parseError("a !== b");
    try std.testing.expectEqualStrings("UNKNOWN OPERATOR", err.title);
}

test "parseError with ** detects Python exponentiation" {
    const err = errors.parseError("2 ** 10");
    try std.testing.expectEqualStrings("UNKNOWN OPERATOR", err.title);
}

test "parseError with return keyword" {
    const err = errors.parseError("return 42");
    try std.testing.expectEqualStrings("NO RETURN KEYWORD", err.title);
}

test "parseError with class keyword" {
    const err = errors.parseError("class Foo {}");
    try std.testing.expectEqualStrings("NO CLASSES", err.title);
}

test "parseError with function keyword" {
    const err = errors.parseError("function foo() {}");
    try std.testing.expectEqualStrings("USE DEF OR FN", err.title);
}

test "parseError with elsif" {
    const err = errors.parseError("elsif condition do end");
    try std.testing.expectEqualStrings("NO ELSIF/ELIF", err.title);
}

test "parseError with elif" {
    const err = errors.parseError("elif condition do end");
    try std.testing.expectEqualStrings("NO ELSIF/ELIF", err.title);
}

test "parseError with state keyword is notSupportedInRepl" {
    const err = errors.parseError("state count: Int :: 0");
    try std.testing.expectEqualStrings("NOT AVAILABLE HERE", err.title);
}

test "parseError with on keyword is notSupportedInRepl" {
    const err = errors.parseError("on :increment do end");
    try std.testing.expectEqualStrings("NOT AVAILABLE HERE", err.title);
}

test "parseError with become keyword is notSupportedInRepl" {
    const err = errors.parseError("become count: 0");
    try std.testing.expectEqualStrings("NOT AVAILABLE HERE", err.title);
}

test "parseError generic falls through to PARSE ERROR" {
    const err = errors.parseError("@#$%");
    try std.testing.expectEqualStrings("PARSE ERROR", err.title);
}

test "parseError generic has message" {
    const err = errors.parseError("@#$%");
    try std.testing.expect(err.message.len > 0);
}

test "parseError generic has hint" {
    const err = errors.parseError("@#$%");
    try std.testing.expect(err.hint != null);
}

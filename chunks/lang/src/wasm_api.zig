const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Evaluator = @import("eval.zig").Evaluator;
const Value = @import("value.zig").Value;
const builtins = @import("builtins.zig");

// ── JS imports ──────────────────────────────────────────

extern "env" fn blimp_js_print(ptr: [*]const u8, len: u32) void;
extern "env" fn blimp_js_error(ptr: [*]const u8, len: u32) void;

// ── Global state ────────────────────────────────────────

const allocator = std.heap.wasm_allocator;
const gc = @import("gc.zig");

var evaluator: ?Evaluator = null;

// The evaluator allocates every value on one of two arenas and never frees.
// After each eval, gc.compact copies what is still reachable into the other
// arena and the old one is released, so a long browser session does not
// grow without bound.  Source text and ASTs stay on `allocator` because
// closures and handlers keep pointing into them.
var heaps: [2]std.heap.ArenaAllocator = .{
    std.heap.ArenaAllocator.init(std.heap.wasm_allocator),
    std.heap.ArenaAllocator.init(std.heap.wasm_allocator),
};
var live_heap: usize = 0;

fn heap() std.mem.Allocator {
    return heaps[live_heap].allocator();
}

fn freshEvaluator() Evaluator {
    _ = heaps[0].reset(.free_all);
    _ = heaps[1].reset(.free_all);
    live_heap = 0;
    return Evaluator.init(heap());
}

/// Copy the live evaluator data into the idle arena and free the busy one.
/// If the copy fails the evaluator keeps using its current arena.
fn compactHeap() void {
    var eval = &(evaluator orelse return);
    const next = 1 - live_heap;
    gc.compact(eval, heaps[next].allocator(), allocator) catch return;
    _ = heaps[live_heap].reset(.free_all);
    live_heap = next;
    // Error details were already formatted into error_buf.
    eval.last_error = null;
}

/// Bytes currently held by the evaluator's arena (for host-side monitoring).
export fn blimp_heap_bytes() u32 {
    return @intCast(heaps[live_heap].queryCapacity());
}

// Result/error buffers - we write into these, JS reads them
var result_buf: [16384]u8 = undefined;
var result_len: u32 = 0;
var error_buf: [4096]u8 = undefined;
var error_len: u32 = 0;
var state_buf: [65536]u8 = undefined;
var state_len: u32 = 0;
var last_status: i32 = 0;
var view_buf: [65536]u8 = undefined;
var view_len: u32 = 0;
var has_view: bool = false;

// Message log - track recent sends for canvas rays
const MaxMessages = 64;
const MessageEntry = struct {
    from_id: i32, // -1 = REPL/global
    to_id: u32,
    to_name: []const u8,
    msg_name: []const u8,
};
var message_log: [MaxMessages]MessageEntry = undefined;
var message_count: u32 = 0;

// ── WASM exports ────────────────────────────────────────

/// Initialize the Blimp interpreter. Call once before eval.
export fn blimp_init() void {
    evaluator = freshEvaluator();
    result_len = 0;
    error_len = 0;
    state_len = 0;
    last_status = 0;
}

/// Evaluate a Blimp source string.
/// Returns 0 on success, 1 on parse error, 2 on eval error.
export fn blimp_eval(source_ptr: [*]const u8, source_len: u32) i32 {
    var eval = &(evaluator orelse return 3);

    const source_slice = source_ptr[0..source_len];

    // Duplicate the source so the evaluator owns it. The parser's AST
    // holds slices into the source string (handler names, field names,
    // actor names), so the source must live as long as the evaluator.
    const source = allocator.dupe(u8, source_slice) catch return 3;
    eval.setSource(source);

    // Parse -- use the global allocator, NOT a temporary arena.
    // The AST must live as long as the evaluator because the actor
    // registry holds pointers into it (handler bodies, state defaults).
    var parser = Parser.init(allocator, source);
    const nodes = parser.parseFile() catch {
        // Parse error
        const msg = std.fmt.bufPrint(&error_buf, "Parse error at line {}, col {}", .{
            parser.current.line,
            parser.current.col,
        }) catch "Parse error";
        error_len = @intCast(msg.len);
        result_len = 0;
        last_status = 1;
        return 1;
    };

    // Evaluate each node, keep the last result
    var last_value: ?*const Value = null;
    for (nodes) |node| {
        last_value = eval.eval(node) catch {
            // Eval error
            if (eval.last_error) |err| {
                var fbs = std.io.fixedBufferStream(&error_buf);
                err.formatPlain(fbs.writer());
                error_len = @intCast(fbs.pos);
            } else {
                const msg = std.fmt.bufPrint(&error_buf, "Evaluation error", .{}) catch "Evaluation error";
                error_len = @intCast(msg.len);
            }
            result_len = 0;
            last_status = 2;
            compactHeap();
            return 2;
        };
    }

    // Format result
    if (last_value) |val| {
        // Check if result is a view_node -- serialize as JSON for DOM rendering
        if (val.* == .view_node) {
            has_view = true;
            var vfbs = std.io.fixedBufferStream(&view_buf);
            writeViewJson(vfbs.writer(), val);
            view_len = @intCast(vfbs.pos);
            // Also set text result for REPL display
            var fbs = std.io.fixedBufferStream(&result_buf);
            val.format(fbs.writer());
            result_len = @intCast(fbs.pos);
        } else {
            has_view = false;
            view_len = 0;
            var fbs = std.io.fixedBufferStream(&result_buf);
            val.format(fbs.writer());
            result_len = @intCast(fbs.pos);
        }
    } else {
        has_view = false;
        view_len = 0;
        result_len = 0;
    }
    error_len = 0;
    last_status = 0;

    // Update state JSON for sidebar
    updateStateJson();

    // Everything the JS side needs is in the buffers now, so drop the
    // garbage this eval produced.
    compactHeap();

    return 0;
}

fn writeJsonEscaped(w: anytype, val: *const Value) void {
    // Write value as JSON-safe string (no raw quotes)
    switch (val.*) {
        .string => |s| w.writeAll(s) catch {},
        .atom => |a| {
            w.writeAll(":") catch {};
            w.writeAll(a) catch {};
        },
        .integer => |n| w.print("{d}", .{n}) catch {},
        .float => |f| w.print("{d}", .{f}) catch {},
        .boolean => |b| w.print("{}", .{b}) catch {},
        .nil => w.writeAll("nil") catch {},
        .hole => w.writeAll("_") catch {},
        .actor_ref => |r| w.print("ref<{s}:{d}>", .{ r.type_name, r.id }) catch {},
        .list => |items| {
            w.writeAll("[") catch {};
            for (items, 0..) |item, i| {
                if (i > 0) w.writeAll(", ") catch {};
                writeJsonEscaped(w, item);
            }
            w.writeAll("]") catch {};
        },
        .tuple => |items| {
            w.writeAll("{") catch {};
            for (items, 0..) |item, i| {
                if (i > 0) w.writeAll(", ") catch {};
                writeJsonEscaped(w, item);
            }
            w.writeAll("}") catch {};
        },
        .map => |entries| {
            w.writeAll("%{") catch {};
            for (entries, 0..) |entry, i| {
                if (i > 0) w.writeAll(", ") catch {};
                w.writeAll(entry.key) catch {};
                w.writeAll(": ") catch {};
                writeJsonEscaped(w, entry.val);
            }
            w.writeAll("}") catch {};
        },
        .closure => |c| {
            w.writeAll("fn(") catch {};
            for (c.params, 0..) |p, i| {
                if (i > 0) w.writeAll(", ") catch {};
                w.writeAll(p.name) catch {};
                if (p.type_name) |t| {
                    w.writeAll(": ") catch {};
                    w.writeAll(t) catch {};
                }
            }
            w.writeAll(")") catch {};
            if (c.return_type) |rt| {
                w.writeAll(" -> ") catch {};
                w.writeAll(rt) catch {};
            }
            w.writeAll(" do ... end") catch {};
        },
        .view_node => w.writeAll("<view_node>") catch {},
    }
}

fn updateStateJson() void {
    var eval = &(evaluator orelse return);
    var fbs = std.io.fixedBufferStream(&state_buf);
    const w = fbs.writer();

    w.writeAll("{\"vars\":[") catch {};
    const bindings = eval.env.allBindings(allocator);
    for (bindings, 0..) |b, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.writeAll("{\"name\":\"") catch {};
        w.writeAll(b.name) catch {};
        w.writeAll("\",\"value\":\"") catch {};
        writeJsonEscaped(w, b.val);
        w.writeAll("\"}") catch {};
    }

    w.writeAll("],\"actors\":[") catch {};
    var actor_idx: usize = 0;
    for (eval.registry.instances.items) |entry| {
        if (actor_idx > 0) w.writeAll(",") catch {};
        w.writeAll("{\"ref\":\"") catch {};
        w.print("ref<{s}:{d}>", .{ entry.ref.type_name, entry.ref.id }) catch {};
        w.writeAll("\",\"type\":\"") catch {};
        w.writeAll(entry.ref.type_name) catch {};
        w.writeAll("\",\"state\":{") catch {};
        for (entry.state_fields, 0..) |field, fi| {
            if (fi > 0) w.writeAll(",") catch {};
            w.writeAll("\"") catch {};
            w.writeAll(field.key) catch {};
            w.writeAll("\":\"") catch {};
            writeJsonEscaped(w, field.val);
            w.writeAll("\"") catch {};
        }
        w.writeAll("}}") catch {};
        actor_idx += 1;
    }

    // Message log for canvas rays
    w.writeAll("],\"messages\":[") catch {};
    for (0..eval.msg_log_count) |mi| {
        if (mi > 0) w.writeAll(",") catch {};
        const msg = eval.msg_log[mi];
        w.writeAll("{\"target\":\"ref<") catch {};
        w.writeAll(msg.target_type) catch {};
        w.writeAll(":") catch {};
        w.print("{d}", .{msg.target_id}) catch {};
        w.writeAll(">\",\"message\":\"") catch {};
        w.writeAll(msg.message) catch {};
        w.writeAll("\"}") catch {};
    }
    w.writeAll("]}") catch {};

    // Clear the message log after reading
    eval.msg_log_count = 0;

    state_len = @intCast(fbs.pos);
}

/// Serialize a view_node tree as JSON for the JS renderer.
fn writeViewJson(w: anytype, val: *const Value) void {
    switch (val.*) {
        .view_node => |node| {
            w.writeAll("{\"tag\":\"") catch {};
            w.writeAll(node.tag) catch {};
            w.writeAll("\",\"attrs\":{") catch {};
            for (node.attrs, 0..) |attr, i| {
                if (i > 0) w.writeAll(",") catch {};
                w.writeAll("\"") catch {};
                w.writeAll(attr.key) catch {};
                w.writeAll("\":") catch {};
                writeViewJson(w, attr.val);
            }
            w.writeAll("},\"children\":[") catch {};
            for (node.children, 0..) |child, i| {
                if (i > 0) w.writeAll(",") catch {};
                writeViewJson(w, child);
            }
            w.writeAll("]}") catch {};
        },
        .string => |s| {
            w.writeAll("{\"text\":\"") catch {};
            // Escape JSON special chars in string values
            for (s) |c| {
                switch (c) {
                    '"' => w.writeAll("\\\"") catch {},
                    '\\' => w.writeAll("\\\\") catch {},
                    '\n' => w.writeAll("\\n") catch {},
                    '\t' => w.writeAll("\\t") catch {},
                    else => w.writeByte(c) catch {},
                }
            }
            w.writeAll("\"}") catch {};
        },
        .integer => |n| {
            w.writeAll("{\"text\":\"") catch {};
            w.print("{d}", .{n}) catch {};
            w.writeAll("\"}") catch {};
        },
        .float => |f| {
            w.writeAll("{\"text\":\"") catch {};
            w.print("{d}", .{f}) catch {};
            w.writeAll("\"}") catch {};
        },
        .atom => |a| {
            w.writeAll("\"") catch {};
            w.writeAll(a) catch {};
            w.writeAll("\"") catch {};
        },
        .boolean => |b| {
            if (b) w.writeAll("true") catch {} else w.writeAll("false") catch {};
        },
        else => {
            w.writeAll("{\"text\":\"") catch {};
            val.format(w);
            w.writeAll("\"}") catch {};
        },
    }
}

/// Returns 1 if the last eval result was a view_node, 0 otherwise.
export fn blimp_has_view() i32 {
    return if (has_view) 1 else 0;
}

/// Get the view JSON pointer.
export fn blimp_get_view_ptr() [*]const u8 {
    return &view_buf;
}

/// Get the view JSON length.
export fn blimp_get_view_len() u32 {
    return view_len;
}

/// Get the result string pointer.
export fn blimp_get_result_ptr() [*]const u8 {
    return &result_buf;
}

/// Get the result string length.
export fn blimp_get_result_len() u32 {
    return result_len;
}

/// Get the error string pointer.
export fn blimp_get_error_ptr() [*]const u8 {
    return &error_buf;
}

/// Get the error string length.
export fn blimp_get_error_len() u32 {
    return error_len;
}

/// Get the state JSON pointer (for introspection sidebar).
export fn blimp_get_state_ptr() [*]const u8 {
    return &state_buf;
}

/// Get the state JSON length.
export fn blimp_get_state_len() u32 {
    return state_len;
}

/// Reset the interpreter to a clean state.
export fn blimp_reset() void {
    evaluator = freshEvaluator();
    result_len = 0;
    error_len = 0;
    state_len = 0;
    view_len = 0;
    has_view = false;
    last_status = 0;
}

// ── Completion ──────────────────────────────────────────

var complete_buf: [32768]u8 = undefined;
var complete_len: u32 = 0;

/// Get completions for a prefix string. Returns JSON array.
export fn blimp_complete(prefix_ptr: [*]const u8, prefix_len: u32) u32 {
    const eval = &(evaluator orelse return 0);
    const prefix = prefix_ptr[0..prefix_len];

    const CompletionEngine = @import("complete.zig").CompletionEngine;
    var engine = CompletionEngine.init(allocator);
    const completions = engine.complete(prefix, eval);

    var fbs = std.io.fixedBufferStream(&complete_buf);
    const w = fbs.writer();
    w.writeAll("[") catch {};
    const max_results = @min(completions.len, 10);
    for (completions[0..max_results], 0..) |comp, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.writeAll("{\"label\":\"") catch {};
        w.writeAll(comp.label) catch {};
        w.writeAll("\",\"insert\":\"") catch {};
        w.writeAll(comp.insert) catch {};
        w.writeAll("\",\"kind\":\"") catch {};
        const kind_name: []const u8 = switch (comp.kind) {
            .variable => "variable",
            .function => "function",
            .builtin => "builtin",
            .actor_template => "actor",
            .actor_handler => "handler",
            .keyword => "keyword",
        };
        w.writeAll(kind_name) catch {};
        w.writeAll("\"}") catch {};
    }
    w.writeAll("]") catch {};

    complete_len = @intCast(fbs.pos);
    return complete_len;
}

export fn blimp_get_complete_ptr() [*]const u8 {
    return &complete_buf;
}

export fn blimp_get_complete_len() u32 {
    return complete_len;
}

/// Allocate memory in WASM linear memory (for JS to write source strings).
export fn blimp_alloc(len: u32) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free memory previously allocated with blimp_alloc.
export fn blimp_free(ptr: [*]u8, len: u32) void {
    allocator.free(ptr[0..len]);
}

// ── Test runner (for in-browser tutorials) ──────────────

var test_report_buf: [65536]u8 = undefined;
var test_report_len: u32 = 0;

fn writeJsonStr(w: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch {},
            '\\' => w.writeAll("\\\\") catch {},
            '\n' => w.writeAll("\\n") catch {},
            '\r' => w.writeAll("\\r") catch {},
            '\t' => w.writeAll("\\t") catch {},
            0...8, 11, 12, 14...31 => w.print("\\u{x:0>4}", .{c}) catch {},
            else => w.writeByte(c) catch {},
        }
    }
}

/// Parse a source string, register actors/functions, then run every `test` block
/// found inside any actor. Produces a JSON report in test_report_buf.
/// Returns: 0 = all passed, 1 = at least one failure, 2 = parse error, 3 = not initialized.
export fn blimp_run_tests(source_ptr: [*]const u8, source_len: u32) i32 {
    // Start fresh each call so the tutorial's red/green cycle is clean.
    evaluator = freshEvaluator();
    var eval = &(evaluator orelse return 3);

    const source_slice = source_ptr[0..source_len];
    const source = allocator.dupe(u8, source_slice) catch return 3;
    eval.setSource(source);

    var parser = Parser.init(allocator, source);
    const nodes = parser.parseFile() catch {
        var fbs = std.io.fixedBufferStream(&test_report_buf);
        const w = fbs.writer();
        w.writeAll("{\"error\":\"parse error at line ") catch {};
        w.print("{d}", .{parser.current.line}) catch {};
        w.writeAll(", col ") catch {};
        w.print("{d}", .{parser.current.col}) catch {};
        w.writeAll("\",\"total\":0,\"passed\":0,\"failed\":0,\"tests\":[]}") catch {};
        test_report_len = @intCast(fbs.pos);
        return 2;
    };

    // First pass: evaluate top-level nodes so actors are registered.
    for (nodes) |node| {
        _ = eval.eval(node) catch {};
    }

    var fbs = std.io.fixedBufferStream(&test_report_buf);
    const w = fbs.writer();
    var total: u32 = 0;
    var passed: u32 = 0;
    var first_test = true;

    w.writeAll("{\"tests\":[") catch {};

    for (nodes) |node| {
        if (node.kind != .actor_def) continue;
        const def = node.kind.actor_def;

        for (def.body) |body_node| {
            if (body_node.kind != .test_def) continue;
            const test_def = body_node.kind.test_def;
            total += 1;

            // Fresh scope with re-evaluated state defaults.
            eval.env.pushScope();
            for (def.body) |state_node| {
                if (state_node.kind != .state_def) continue;
                for (state_node.kind.state_def.fields) |field| {
                    if (field.default_value) |default_ptr| {
                        const val = eval.eval(default_ptr.*) catch continue;
                        eval.env.define(field.key, val);
                    }
                }
            }

            // Reset the assertion detail buffer so stale detail doesn't leak between tests.
            builtins.last_assertion_detail_len = 0;

            var test_passed = true;
            for (test_def.body) |stmt| {
                _ = eval.eval(stmt) catch {
                    test_passed = false;
                    break;
                };
            }
            eval.env.popScope();
            eval.actor_ctx = null;

            const raw_name = test_def.name;
            const test_name = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"')
                raw_name[1 .. raw_name.len - 1]
            else
                raw_name;

            if (!first_test) w.writeAll(",") catch {};
            first_test = false;
            w.writeAll("{\"actor\":\"") catch {};
            writeJsonStr(w, def.name);
            w.writeAll("\",\"name\":\"") catch {};
            writeJsonStr(w, test_name);
            w.writeAll("\",\"ok\":") catch {};
            if (test_passed) {
                w.writeAll("true}") catch {};
                passed += 1;
            } else {
                w.writeAll("false,\"detail\":\"") catch {};
                if (builtins.last_assertion_detail_len > 0) {
                    writeJsonStr(w, builtins.last_assertion_detail[0..builtins.last_assertion_detail_len]);
                } else {
                    w.writeAll("assertion failed") catch {};
                }
                w.writeAll("\"}") catch {};
            }
        }
    }

    w.writeAll("],\"total\":") catch {};
    w.print("{d}", .{total}) catch {};
    w.writeAll(",\"passed\":") catch {};
    w.print("{d}", .{passed}) catch {};
    w.writeAll(",\"failed\":") catch {};
    w.print("{d}", .{total - passed}) catch {};
    w.writeAll("}") catch {};

    test_report_len = @intCast(fbs.pos);
    return if (passed == total) 0 else 1;
}

export fn blimp_get_test_report_ptr() [*]const u8 {
    return &test_report_buf;
}

export fn blimp_get_test_report_len() u32 {
    return test_report_len;
}

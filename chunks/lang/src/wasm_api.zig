const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Evaluator = @import("eval.zig").Evaluator;
const Value = @import("value.zig").Value;

// ── JS imports ──────────────────────────────────────────

extern "env" fn blimp_js_print(ptr: [*]const u8, len: u32) void;
extern "env" fn blimp_js_error(ptr: [*]const u8, len: u32) void;

// ── Global state ────────────────────────────────────────

const allocator = std.heap.wasm_allocator;

var evaluator: ?Evaluator = null;

// Result/error buffers - we write into these, JS reads them
var result_buf: [16384]u8 = undefined;
var result_len: u32 = 0;
var error_buf: [4096]u8 = undefined;
var error_len: u32 = 0;
var state_buf: [65536]u8 = undefined;
var state_len: u32 = 0;
var last_status: i32 = 0;

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
    evaluator = Evaluator.init(allocator);
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
            return 2;
        };
    }

    // Format result
    if (last_value) |val| {
        var fbs = std.io.fixedBufferStream(&result_buf);
        val.format(fbs.writer());
        result_len = @intCast(fbs.pos);
    } else {
        result_len = 0;
    }
    error_len = 0;
    last_status = 0;

    // Update state JSON for sidebar
    updateStateJson();

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

    w.writeAll("]}") catch {};
    state_len = @intCast(fbs.pos);
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
    evaluator = Evaluator.init(allocator);
    result_len = 0;
    error_len = 0;
    state_len = 0;
    last_status = 0;
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

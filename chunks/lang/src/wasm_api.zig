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
const wasm_bufs = @import("wasm_bufs.zig");
const wasm_json = @import("wasm_json.zig");
const Guard = wasm_json.Guard;
const writeViewJson = wasm_json.writeViewJson;
const writeJsonString = wasm_json.writeJsonString;

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
    var eval = Evaluator.init(heap());
    // Source and ASTs live on `allocator`, which compaction never frees.
    eval.code_allocator = allocator;
    return eval;
}

/// Copy the live evaluator data into the idle arena and free the busy one.
/// If the copy fails the evaluator keeps using its current arena.
fn compactHeap() void {
    var eval = &(evaluator orelse return);
    const next = 1 - live_heap;
    gc.compact(eval, heaps[next].allocator(), allocator) catch return;
    _ = heaps[live_heap].reset(.free_all);
    live_heap = next;
    // Error details were already formatted into err_out.
    eval.last_error = null;
}

/// Bytes currently held by the evaluator's arena (for host-side monitoring).
export fn blimp_heap_bytes() u32 {
    return @intCast(heaps[live_heap].queryCapacity());
}

// Everything below is written here and read by JS through a pointer and a
// length. The result, view, state and reply buffers grow to fit: each was a
// fixed array once (16 KiB, 64 KiB, 256 KiB), and a write past the end was
// dropped without a word, so the page parsed cut-off JSON -- nine chess
// boards on one page "did not produce a view". A buffer that grows moves,
// so the pointer is only good until the next call; blimp.js asks for it
// after every call.
//
// A buffer that grows can fail to: an allocation fails and the write with
// it. Every write used to be `catch {}`, which after the buffers grew meant
// out of memory cut the output exactly as a full buffer had. Each buffer is
// now written through a Guard, and when a write fails it hands JS a fixed
// message that says so (and the call returns 3, out of memory, where it
// returns a status).
const Out = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    /// Set when writing failed: what JS reads instead of the list.
    failed: ?[]const u8 = null,

    fn clear(self: *Out) void {
        self.list.clearRetainingCapacity();
        self.failed = null;
    }

    fn ptr(self: *const Out) [*]const u8 {
        return if (self.failed) |f| f.ptr else self.list.items.ptr;
    }

    fn len(self: *const Out) u32 {
        return @intCast(if (self.failed) |f| f.len else self.list.items.len);
    }

    /// Start writing it over: clear it, and hand back the writer.
    fn begin(self: *Out, aw: *std.Io.Writer.Allocating, g: *Guard) *std.Io.Writer {
        self.clear();
        aw.* = std.Io.Writer.Allocating.fromArrayList(allocator, &self.list);
        g.* = Guard.init(&aw.writer, false);
        return g.start();
    }

    /// Take the list back; if any write failed, hand out `message` instead.
    /// Returns whether the write got through whole.
    fn end(self: *Out, aw: *std.Io.Writer.Allocating, g: *Guard, message: []const u8) bool {
        const ok = if (g.finish()) true else |_| false;
        self.list = aw.toArrayList();
        if (!ok) self.failed = message;
        return ok;
    }
};

var result: Out = .{};
// An error keeps a cap, and says when it hit it (see wasm_bufs.capError).
var err_out: Out = .{};
// The state JSON grows with the program. It was a fixed 256 KiB, and a
// write past the end was dropped without a word, so a big program -- Snake
// compiled from Temper makes an actor of every point, 800 after a few
// frames -- got cut-off JSON, and getState() answered with nothing at all.
var state: Out = .{};
// Messages accumulate here, already serialized, across evals and sends until
// JS reads the state (a view host runs two evals per send and reads once).
// Value pointers in eval.msg_log only live for one eval, so the text is
// kept. The log has a cap, and past it drops the oldest and counts them in
// the state's "messages_dropped" (see wasm_bufs.MessageLog for why a cap).
const messages_cap = 196608;
var messages: wasm_bufs.MessageLog = .init(messages_cap);
var message_entry: std.ArrayListUnmanaged(u8) = .empty;
var messages_read: bool = false;
var last_status: i32 = 0;
var view: Out = .{};
var has_view: bool = false;

const oom_error = "Out of memory writing the error message";
const oom_state = "{\"vars\":[],\"actors\":[],\"messages\":[],\"messages_dropped\":0,\"error\":\"out of memory writing the state JSON\"}";

/// Replace the error text with `fmt` and `args`, cut and marked at the cap.
fn setError(comptime fmt: []const u8, args: anytype) void {
    var aw: std.Io.Writer.Allocating = undefined;
    var g: Guard = undefined;
    const w = err_out.begin(&aw, &g);
    w.print(fmt, args) catch {};
    if (err_out.end(&aw, &g, oom_error)) wasm_bufs.capError(&err_out.list, wasm_bufs.error_cap);
}

/// The evaluator's error as the error text, or `fallback` when there is none.
fn setEvalError(eval: *Evaluator, fallback: []const u8) void {
    const err = eval.last_error orelse return setError("{s}", .{fallback});
    var aw: std.Io.Writer.Allocating = undefined;
    var g: Guard = undefined;
    const w = err_out.begin(&aw, &g);
    err.formatPlain(w);
    if (err_out.end(&aw, &g, oom_error)) wasm_bufs.capError(&err_out.list, wasm_bufs.error_cap);
}

/// Write `val` into `out`, replacing what was there, as view JSON or as the
/// REPL's text. False, with the error set, if it could not be written whole.
fn writeValueInto(out: *Out, val: *const Value, comptime as: enum { view_json, text }) bool {
    var aw: std.Io.Writer.Allocating = undefined;
    var g: Guard = undefined;
    const w = out.begin(&aw, &g);
    switch (as) {
        .view_json => writeViewJson(w, val) catch {},
        .text => val.format(w),
    }
    const what = switch (as) {
        .view_json => "view JSON",
        .text => "result",
    };
    if (out.end(&aw, &g, "")) return true;
    setError("Out of memory writing the {s}", .{what});
    return false;
}

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
/// The page's clock, for now(), now_ms() and utc_offset(): WebAssembly has
/// none. blimp.js calls this before every eval and send.
export fn blimp_set_clock(epoch_ms: f64, mono_ms: f64, utc_offset_s: i32) void {
    builtins.wasm_clock = .{ .epoch_ms = epoch_ms, .mono_ms = mono_ms, .utc_offset_s = utc_offset_s };
}

export fn blimp_init() void {
    evaluator = freshEvaluator();
    result.clear();
    err_out.clear();
    state.clear();
    last_status = 0;
}

/// Evaluate a Blimp source string.
/// Returns 0 on success, 1 on parse error, 2 on eval error, 3 when there is
/// no evaluator or the result could not be written (out of memory; the
/// error text says which).
export fn blimp_eval(source_ptr: [*]const u8, source_len: u32) i32 {
    var eval = &(evaluator orelse return 3);

    const source_slice = source_ptr[0..source_len];

    // Duplicate the source so the evaluator owns it. The parser's AST
    // holds slices into the source string (handler names, field names,
    // actor names), so the source must live as long as the evaluator.
    const source = allocator.dupe(u8, source_slice) catch return 3;
    eval.setSource(source);
    // The message log holds pointers into the previous eval's heap, which
    // compactHeap has already dropped, so it starts empty every eval.
    eval.msg_log_count = 0;

    // Parse -- use the global allocator, NOT a temporary arena.
    // The AST must live as long as the evaluator because the actor
    // registry holds pointers into it (handler bodies, state defaults).
    var parser = Parser.init(allocator, source);
    const nodes = parser.parseFile() catch {
        // Parse error
        setError("Parse error at line {}, col {}", .{
            parser.current.line,
            parser.current.col,
        });
        result.clear();
        last_status = 1;
        return 1;
    };

    // Evaluate each node, keep the last result
    var last_value: ?*const Value = null;
    for (nodes) |node| {
        last_value = eval.eval(node) catch {
            setEvalError(eval, "Evaluation error");
            result.clear();
            last_status = 2;
            compactHeap();
            return 2;
        };
    }

    // Format result
    if (last_value) |val| {
        // Check if result is a view_node -- serialize as JSON for DOM rendering
        has_view = val.* == .view_node;
        view.clear();
        // The text result for the REPL, a view's too; the view as JSON.
        if (!writeValueInto(&result, val, .text) or
            (has_view and !writeValueInto(&view, val, .view_json)))
        {
            has_view = false;
            view.clear();
            result.clear();
            last_status = 3;
            compactHeap();
            return 3;
        }
    } else {
        has_view = false;
        view.clear();
        result.clear();
    }
    err_out.clear();
    last_status = 0;

    // Update state JSON for sidebar
    updateStateJson();

    // Everything the JS side needs is in the buffers now, so drop the
    // garbage this eval produced.
    compactHeap();

    return 0;
}

/// Format a value into a quoted JSON string, capped so a board full of rows
/// does not blow up the state buffer. Quotes, backslashes and control
/// characters are escaped; a truncated value ends in "...".
const value_string_cap = 80;
fn writeValueJsonString(w: anytype, val: *const Value) void {
    var buf: [value_string_cap]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    writeJsonEscaped(&fbs, val);
    const truncated = fbs.buffered().len == value_string_cap;
    w.writeAll("\"") catch {};
    for (buf[0..fbs.buffered().len]) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch {},
            '\\' => w.writeAll("\\\\") catch {},
            '\n' => w.writeAll("\\n") catch {},
            '\r' => w.writeAll("\\r") catch {},
            '\t' => w.writeAll("\\t") catch {},
            else => if (c < 0x20) {
                w.print("\\u{x:0>4}", .{c}) catch {};
            } else {
                w.writeByte(c) catch {};
            },
        }
    }
    if (truncated) w.writeAll("...") catch {};
    w.writeAll("\"") catch {};
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

/// A binding's or a state field's value, as a JSON string: formatted the way
/// the sidebar shows it, escaped, and cut at `state_value_cap` bytes with
/// "..." after. These used to be written between quotes unescaped, so one
/// string holding a `"` -- any HTML at all -- made the whole state invalid
/// JSON, and a host reading it got nothing.
const state_value_cap = 2048;
fn writeStateValue(g: *Guard, val: *const Value) void {
    const w = &g.writer;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var tg = Guard.init(&aw.writer, false);
    writeJsonEscaped(tg.start(), val);
    tg.finish() catch {
        g.failed = true;
        return;
    };
    const text = aw.written();
    const cut = text.len > state_value_cap;
    w.writeAll("\"") catch {};
    wasm_json.writeJsonStringBody(w, if (cut) text[0..state_value_cap] else text) catch {};
    if (cut) w.writeAll("...") catch {};
    w.writeAll("\"") catch {};
}

fn updateStateJson() void {
    var eval = &(evaluator orelse return);
    var aw: std.Io.Writer.Allocating = undefined;
    var g: Guard = undefined;
    const w = state.begin(&aw, &g);

    w.writeAll("{\"vars\":[") catch {};
    const bindings = eval.env.allBindings(allocator);
    for (bindings, 0..) |b, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.writeAll("{\"name\":\"") catch {};
        w.writeAll(b.name) catch {};
        w.writeAll("\",\"value\":") catch {};
        writeStateValue(&g, b.val);
        w.writeAll("}") catch {};
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
            w.writeAll("\":") catch {};
            writeStateValue(&g, field.val);
        }
        w.writeAll("}}") catch {};
        actor_idx += 1;
    }

    // Message log for canvas rays and the inspector: this eval's entries are
    // appended to the accumulated text, which JS clears by reading it.
    if (messages_read) {
        messages.clear();
        messages_read = false;
    }
    appendMessagesJson(eval);
    messages.trim();
    w.writeAll("],\"messages\":[") catch {};
    messages.writeJoined(w) catch {};
    w.print("],\"messages_dropped\":{d}}}", .{messages.dropped}) catch {};

    eval.msg_log_count = 0;

    _ = state.end(&aw, &g, oom_state);
}

/// A send's messages go where an eval's do, into the text getState hands
/// the canvas (and clears on reading): a page that runs its program by
/// send -- every game on the blog -- drew its actors with no rays between
/// them, because send cleared the log and nothing had read it. The log is
/// bounded; past the cap the oldest go, and the state says how many.
fn keepSendMessages(eval: *Evaluator) void {
    if (messages_read) {
        messages.clear();
        messages_read = false;
    }
    appendMessagesJson(eval);
}

fn appendMessagesJson(eval: *Evaluator) void {
    for (0..eval.msg_log_count) |mi| {
        const msg = eval.msg_log[mi];
        message_entry.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &message_entry);
        var g = Guard.init(&aw.writer, false);
        const w = g.start();
        w.writeAll("{\"target\":\"ref<") catch {};
        w.writeAll(msg.target_type) catch {};
        w.writeAll(":") catch {};
        w.print("{d}", .{msg.target_id}) catch {};
        w.writeAll(">\",\"message\":\"") catch {};
        w.writeAll(msg.message) catch {};
        w.writeAll("\",\"from\":") catch {};
        if (msg.source_type) |src_type| {
            w.writeAll("\"ref<") catch {};
            w.writeAll(src_type) catch {};
            w.writeAll(":") catch {};
            w.print("{d}", .{msg.source_id.?}) catch {};
            w.writeAll(">\"") catch {};
        } else {
            w.writeAll("null") catch {};
        }
        w.writeAll(",\"args\":[") catch {};
        for (msg.args, 0..) |arg, ai| {
            if (ai > 0) w.writeAll(",") catch {};
            writeValueJsonString(w, arg);
        }
        w.writeAll("],\"reply\":") catch {};
        if (msg.reply) |reply| {
            writeValueJsonString(w, reply);
        } else {
            w.writeAll("null") catch {};
        }
        w.writeAll("}") catch {};
        const ok = if (g.finish()) true else |_| false;
        message_entry = aw.toArrayList();
        // an entry that could not be written whole is dropped, and counted
        if (ok) messages.push(allocator, message_entry.items) else messages.dropped += 1;
    }
}

// ── blimp_send ──────────────────────────────────────────
//
// A host that animates an actor sends it a message many times a second.
// Doing that through blimp_eval costs about 390 bytes a call that are never
// returned: eval copies its source, and the AST parsed from it, onto the
// permanent allocator, because a definition in that source may be pointed at
// by a handler forever. A send defines nothing. So blimp_send builds the
// source `target <- :message(args)` on the collected heap, parses and
// evaluates it there, writes the reply out, and compacts; afterwards nothing
// of the call is left but the actor's new state.
//
// It also skips what eval does for the playground's sidebar (the state JSON
// and the message log), and it writes the reply as real JSON, into a buffer
// that grows, rather than into a fixed one.

var reply_out: Out = .{};

/// blimp_send(target, message, args) -> 0 ok, 1 parse error, 2 eval error,
/// 3 no evaluator or out of memory, 4 a reply JSON cannot represent.
///   target   name of a global binding holding the actor, e.g. "app"
///   message  handler name without the colon, e.g. "frame"
///   args     Blimp source for the arguments, comma-separated, or empty
export fn blimp_send(
    target_ptr: [*]const u8,
    target_len: u32,
    msg_ptr: [*]const u8,
    msg_len: u32,
    args_ptr: [*]const u8,
    args_len: u32,
) i32 {
    var eval = &(evaluator orelse return 3);
    const target = target_ptr[0..target_len];
    const msg = msg_ptr[0..msg_len];
    const args = args_ptr[0..args_len];

    const source = if (args.len == 0)
        std.fmt.allocPrint(heap(), "{s} <- :{s}", .{ target, msg })
    else
        std.fmt.allocPrint(heap(), "{s} <- :{s}({s})", .{ target, msg, args });
    const src = source catch return 3;

    const saved_source = eval.source;
    eval.setSource(src);
    defer eval.setSource(saved_source);
    eval.msg_log_count = 0;

    var parser = Parser.init(heap(), src);
    const nodes = parser.parseFile() catch {
        setError("Parse error in send: {s}", .{src});
        compactHeap();
        return 1;
    };
    if (nodes.len != 1) {
        setError("A send must be one expression: {s}", .{src});
        compactHeap();
        return 1;
    }

    const value = eval.eval(nodes[0]) catch {
        if (eval.last_error == null) {
            setError("Evaluation error in send: {s}", .{src});
        } else {
            setEvalError(eval, "");
        }
        keepSendMessages(eval);
        eval.msg_log_count = 0;
        compactHeap();
        return 2;
    };

    var aw: std.Io.Writer.Allocating = undefined;
    var g: Guard = undefined;
    const w = reply_out.begin(&aw, &g);
    const written = wasm_json.writeReplyJson(w, value);
    const whole = reply_out.end(&aw, &g, "");
    // Set the error before compacting: it quotes `src`, which is on the heap.
    const status: i32 = if (written) |_|
        (if (whole) 0 else 3)
    else |e| switch (e) {
        error.Unrepresentable => 4,
        error.WriteFailed => 3,
    };
    switch (status) {
        0 => err_out.clear(),
        3 => setError("Out of memory writing the reply to {s}", .{src}),
        else => setError("The reply to {s} cannot be written as JSON", .{src}),
    }
    if (status != 0) reply_out.clear();
    keepSendMessages(eval);
    eval.msg_log_count = 0;
    compactHeap();
    return status;
}

export fn blimp_get_reply_ptr() [*]const u8 {
    return reply_out.ptr();
}

export fn blimp_get_reply_len() u32 {
    return reply_out.len();
}

/// Returns 1 if the last eval result was a view_node, 0 otherwise.
export fn blimp_has_view() i32 {
    return if (has_view) 1 else 0;
}

/// Get the view JSON pointer.
export fn blimp_get_view_ptr() [*]const u8 {
    return view.ptr();
}

/// Get the view JSON length.
export fn blimp_get_view_len() u32 {
    return view.len();
}

/// Get the result string pointer.
export fn blimp_get_result_ptr() [*]const u8 {
    return result.ptr();
}

/// Get the result string length.
export fn blimp_get_result_len() u32 {
    return result.len();
}

/// Get the error string pointer.
export fn blimp_get_error_ptr() [*]const u8 {
    return err_out.ptr();
}

/// Get the error string length.
export fn blimp_get_error_len() u32 {
    return err_out.len();
}

/// Rebuild the state JSON from the program as it is now. eval rebuilds it
/// after every evaluation; send does not (it is the cheap path), so a host
/// that runs its program by send and draws it -- the blog's games and their
/// canvases -- asks for it when it wants it.
export fn blimp_refresh_state() void {
    updateStateJson();
}

/// Get the state JSON pointer (for introspection sidebar).
export fn blimp_get_state_ptr() [*]const u8 {
    messages_read = true;
    return state.ptr();
}

/// Get the state JSON length.
export fn blimp_get_state_len() u32 {
    return state.len();
}

/// Reset the interpreter to a clean state.
export fn blimp_reset() void {
    evaluator = freshEvaluator();
    result.clear();
    err_out.clear();
    state.clear();
    messages.clear();
    messages_read = false;
    view.clear();
    has_view = false;
    last_status = 0;
}

// ── Completion ──────────────────────────────────────────

// Grows, like the rest. It was a fixed 32 KiB: ten completions are small
// until one of them is a long name, and then the JSON came out cut and the
// page's parse answered "no completions". A cap buys nothing here -- the
// list is ten entries by construction.
var completions_out: Out = .{};
const oom_complete = "[{\"label\":\"(out of memory listing completions)\",\"insert\":\"\",\"kind\":\"error\"}]";

/// Get completions for a prefix string. Returns JSON array.
export fn blimp_complete(prefix_ptr: [*]const u8, prefix_len: u32) u32 {
    const eval = &(evaluator orelse return 0);
    const prefix = prefix_ptr[0..prefix_len];

    const CompletionEngine = @import("complete.zig").CompletionEngine;
    var engine = CompletionEngine.init(allocator);
    const completions = engine.complete(prefix, eval);

    var aw: std.Io.Writer.Allocating = undefined;
    var g: Guard = undefined;
    const w = completions_out.begin(&aw, &g);
    w.writeAll("[") catch {};
    const max_results = @min(completions.len, 10);
    for (completions[0..max_results], 0..) |comp, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.writeAll("{\"label\":") catch {};
        writeJsonString(w, comp.label) catch {};
        w.writeAll(",\"insert\":") catch {};
        writeJsonString(w, comp.insert) catch {};
        w.writeAll(",\"kind\":\"") catch {};
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

    _ = completions_out.end(&aw, &g, oom_complete);
    return completions_out.len();
}

export fn blimp_get_complete_ptr() [*]const u8 {
    return completions_out.ptr();
}

export fn blimp_get_complete_len() u32 {
    return completions_out.len();
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

// Grows. It was a fixed 64 KiB, and a tutorial with enough tests (or long
// enough names) got a report cut mid-string. A report is one JSON document,
// so a cut with a marker would still not parse; growing is the only fix
// that keeps it whole.
var test_report: Out = .{};
const oom_test_report = "{\"error\":\"out of memory writing the test report\",\"total\":0,\"passed\":0,\"failed\":0,\"tests\":[]}";

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
/// found inside any actor. Produces a JSON report in test_report.
/// Returns: 0 = all passed, 1 = at least one failure, 2 = parse error, 3 = not initialized,
/// 4 = out of memory writing the report (the report then says so in "error").
export fn blimp_run_tests(source_ptr: [*]const u8, source_len: u32) i32 {
    // Start fresh each call so the tutorial's red/green cycle is clean.
    evaluator = freshEvaluator();
    var eval = &(evaluator orelse return 3);

    const source_slice = source_ptr[0..source_len];
    const source = allocator.dupe(u8, source_slice) catch return 3;
    eval.setSource(source);

    var parser = Parser.init(allocator, source);
    const nodes = parser.parseFile() catch {
        var aw: std.Io.Writer.Allocating = undefined;
        var g: Guard = undefined;
        const w = test_report.begin(&aw, &g);
        w.writeAll("{\"error\":\"parse error at line ") catch {};
        w.print("{d}", .{parser.current.line}) catch {};
        w.writeAll(", col ") catch {};
        w.print("{d}", .{parser.current.col}) catch {};
        w.writeAll("\",\"total\":0,\"passed\":0,\"failed\":0,\"tests\":[]}") catch {};
        if (!test_report.end(&aw, &g, oom_test_report)) return 4;
        return 2;
    };

    // First pass: evaluate top-level nodes so actors are registered.
    for (nodes) |node| {
        _ = eval.eval(node) catch {};
    }

    var aw: std.Io.Writer.Allocating = undefined;
    var g: Guard = undefined;
    const w = test_report.begin(&aw, &g);
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

    if (!test_report.end(&aw, &g, oom_test_report)) return 4;
    return if (passed == total) 0 else 1;
}

export fn blimp_get_test_report_ptr() [*]const u8 {
    return test_report.ptr();
}

export fn blimp_get_test_report_len() u32 {
    return test_report.len();
}

//! What a web application compiled from Temper needs from the machine, and
//! the interpreter did not have: SQLite and subprocesses. Native only
//! (builtins.zig stubs them on WASM).
//!
//!   sqlite_open(path) -> Int            sqlite_close(db) -> nil
//!   sqlite_exec(db, sql) -> Int         sqlite_query(db, sql, params) -> [[String|nil]]
//!   sqlite_last_id(db) -> Int           sqlite_changes(db) -> Int
//!   exec(argv, stdin, cwd) -> [status, stdout, stderr]
//!
//! Every failure is a TypeError carrying a message (builtins.failArg), which
//! the evaluator reports as BAD ARGUMENT with the source line.

const std = @import("std");
const builtins = @import("builtins.zig");
const Value = @import("value.zig").Value;
const EvalError = builtins.EvalError;

fn box(allocator: std.mem.Allocator, v: Value) EvalError!*const Value {
    const p = allocator.create(Value) catch return error.OutOfMemory;
    p.* = v;
    return p;
}

const c = struct {
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn dup2(a: c_int, b: c_int) c_int;
    extern "c" fn chdir(path: [*:0]const u8) c_int;
};

// ── exec ────────────────────────────────────────────────────

/// exec(argv, stdin, cwd) runs argv[0] (searched on PATH) with the rest as its
/// arguments, in directory `cwd` (nil: the interpreter's), feeds it `stdin`,
/// and answers when it has exited: the LIST [status, stdout, stderr] (Int,
/// String, String). A list rather than a map because Temper receives lists well.
///
/// status is the exit code, or the negated signal number when a signal ended
/// it, 127 when execvp failed, 126 when chdir to `cwd` failed (the child cannot
/// report errno any other way). Fds 3..1023 are closed in the child.
/// TypeError for a non-list argv, an empty argv, a non-String element, a
/// NUL byte in an argument, or a cwd that is neither String nor nil.
/// NotSupported when pipe() or fork() fails.
///
/// There is no timeout: this blocks the whole interpreter until the child
/// exits, and under --serve every other request with it.
pub fn exec(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3 or args[0].* != .list or args[1].* != .string) return error.TypeError;
    const list = args[0].list;
    if (list.len == 0) return error.TypeError;
    const input = args[1].string;
    const cwd_z: ?[:0]u8 = switch (args[2].*) {
        .nil => null,
        .string => |p| blk: {
            if (std.mem.indexOfScalar(u8, p, 0) != null) return error.TypeError;
            break :blk allocator.dupeZ(u8, p) catch return error.OutOfMemory;
        },
        else => return error.TypeError,
    };

    // Everything the child needs is built before fork(): after it, only
    // async-signal-safe calls are allowed in a process with other threads.
    const argv = allocator.alloc(?[*:0]const u8, list.len + 1) catch return error.OutOfMemory;
    defer allocator.free(argv);
    for (list, 0..) |item, i| {
        if (item.* != .string) return error.TypeError;
        if (std.mem.indexOfScalar(u8, item.string, 0) != null) return error.TypeError;
        argv[i] = (allocator.dupeZ(u8, item.string) catch return error.OutOfMemory).ptr;
    }
    argv[list.len] = null;
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);

    var in_p: [2]c_int = undefined;
    var out_p: [2]c_int = undefined;
    var err_p: [2]c_int = undefined;
    if (c.pipe(&in_p) != 0) return error.NotSupported;
    if (c.pipe(&out_p) != 0) {
        closeAll(&.{ in_p[0], in_p[1] });
        return error.NotSupported;
    }
    if (c.pipe(&err_p) != 0) {
        closeAll(&.{ in_p[0], in_p[1], out_p[0], out_p[1] });
        return error.NotSupported;
    }

    const pid = std.c.fork();
    if (pid < 0) {
        closeAll(&.{ in_p[0], in_p[1], out_p[0], out_p[1], err_p[0], err_p[1] });
        return error.NotSupported;
    }
    if (pid == 0) {
        _ = c.dup2(in_p[0], 0);
        _ = c.dup2(out_p[1], 1);
        _ = c.dup2(err_p[1], 2);
        if (cwd_z) |d| if (c.chdir(d.ptr) != 0) c._exit(126);
        // tcp_listen and tcp_accept do not set FD_CLOEXEC, so without this the
        // program would inherit the listening socket and every client socket.
        var fd: c_int = 3;
        while (fd < 1024) : (fd += 1) _ = std.c.close(fd);
        _ = c.execvp(argv_z[0].?, argv_z);
        c._exit(127);
    }

    _ = std.c.close(in_p[0]);
    _ = std.c.close(out_p[1]);
    _ = std.c.close(err_p[1]);

    // Write stdin and drain both outputs with poll(), so a child that fills
    // its stdout pipe before reading its stdin cannot deadlock us.
    var out: std.ArrayList(u8) = .empty;
    var err: std.ArrayList(u8) = .empty;
    var in_fd: c_int = in_p[1];
    // poll() says a pipe is writable when it has room for a few bytes, and a
    // blocking write of 64 KiB then waits for room for all of it, while the
    // child waits for us to read what it has written. Non-blocking, the
    // write takes what fits and the loop goes back to draining.
    const nonblock: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const fl = std.c.fcntl(in_fd, std.posix.F.GETFL, @as(c_int, 0));
    if (fl >= 0) _ = std.c.fcntl(in_fd, std.posix.F.SETFL, fl | nonblock);
    var out_fd: c_int = out_p[0];
    var err_fd: c_int = err_p[0];
    var off: usize = 0;
    if (input.len == 0) {
        _ = std.c.close(in_fd);
        in_fd = -1;
    }
    var buf: [65536]u8 = undefined;
    while (in_fd >= 0 or out_fd >= 0 or err_fd >= 0) {
        var pfds: [3]std.posix.pollfd = .{
            .{ .fd = in_fd, .events = std.posix.POLL.OUT, .revents = 0 },
            .{ .fd = out_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = err_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&pfds, -1) catch break;
        if (in_fd >= 0 and pfds[0].revents != 0) {
            // MSG_NOSIGNAL does not apply to a pipe; a child that exited
            // without reading gives EPIPE, and SIGPIPE ends us unless the
            // process ignores it (blimp --serve does; a plain run does not).
            const n = std.c.write(in_fd, input[off..].ptr, @min(input.len - off, 65536));
            if (n > 0) off += @intCast(n);
            if (n < 0 and (std.c._errno().* == @intFromEnum(std.posix.E.INTR) or std.c._errno().* == @intFromEnum(std.posix.E.AGAIN))) continue;
            if (n < 0 or off == input.len) {
                _ = std.c.close(in_fd);
                in_fd = -1;
            }
        }
        if (out_fd >= 0 and pfds[1].revents != 0) {
            const n = std.c.read(out_fd, &buf, buf.len);
            if (n > 0) {
                out.appendSlice(allocator, buf[0..@intCast(n)]) catch return error.OutOfMemory;
            } else if (n == 0 or std.c._errno().* != @intFromEnum(std.posix.E.INTR)) {
                _ = std.c.close(out_fd);
                out_fd = -1;
            }
        }
        if (err_fd >= 0 and pfds[2].revents != 0) {
            const n = std.c.read(err_fd, &buf, buf.len);
            if (n > 0) {
                err.appendSlice(allocator, buf[0..@intCast(n)]) catch return error.OutOfMemory;
            } else if (n == 0 or std.c._errno().* != @intFromEnum(std.posix.E.INTR)) {
                _ = std.c.close(err_fd);
                err_fd = -1;
            }
        }
    }

    var wstatus: c_int = 0;
    while (std.c.waitpid(pid, &wstatus, 0) < 0) {
        if (std.c._errno().* != @intFromEnum(std.posix.E.INTR)) break;
    }
    const sig = wstatus & 0x7f; // WIFEXITED: sig == 0; same encoding on macOS and Linux
    const status: i64 = if (sig == 0) (wstatus >> 8) & 0xff else -@as(i64, sig);

    const items = allocator.alloc(*const Value, 3) catch return error.OutOfMemory;
    items[0] = try box(allocator, .{ .integer = status });
    items[1] = try box(allocator, .{ .string = out.toOwnedSlice(allocator) catch return error.OutOfMemory });
    items[2] = try box(allocator, .{ .string = err.toOwnedSlice(allocator) catch return error.OutOfMemory });
    return box(allocator, .{ .list = items });
}

fn closeAll(fds: []const c_int) void {
    for (fds) |fd| _ = std.c.close(fd);
}

// ── SQLite ──────────────────────────────────────────────────

const sqlite = struct {
    const Db = opaque {};
    const Stmt = opaque {};
    const OK = 0;
    const ROW = 100;
    const DONE = 101;
    const BLOB = 4;
    const NULL = 5;
    const OPEN_READWRITE = 0x2;
    const OPEN_CREATE = 0x4;
    // SQLITE_TRANSIENT is (void(*)(void*))-1: sqlite copies the bytes at once.
    const TRANSIENT: isize = -1; // declared as an integer: the ABI is the same and Zig will not align -1

    extern "c" fn sqlite3_open_v2(path: [*:0]const u8, db: *?*Db, flags: c_int, vfs: ?[*:0]const u8) c_int;
    extern "c" fn sqlite3_close(db: *Db) c_int;
    extern "c" fn sqlite3_errmsg(db: *Db) [*:0]const u8;
    extern "c" fn sqlite3_exec(db: *Db, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
    extern "c" fn sqlite3_prepare_v2(db: *Db, sql: [*]const u8, n: c_int, stmt: *?*Stmt, tail: *[*]const u8) c_int;
    extern "c" fn sqlite3_finalize(stmt: *Stmt) c_int;
    extern "c" fn sqlite3_step(stmt: *Stmt) c_int;
    extern "c" fn sqlite3_changes64(db: *Db) i64;
    extern "c" fn sqlite3_total_changes64(db: *Db) i64;
    extern "c" fn sqlite3_last_insert_rowid(db: *Db) i64;
    extern "c" fn sqlite3_bind_parameter_count(stmt: *Stmt) c_int;
    extern "c" fn sqlite3_bind_null(stmt: *Stmt, i: c_int) c_int;
    extern "c" fn sqlite3_bind_int64(stmt: *Stmt, i: c_int, v: i64) c_int;
    extern "c" fn sqlite3_bind_double(stmt: *Stmt, i: c_int, v: f64) c_int;
    extern "c" fn sqlite3_bind_text(stmt: *Stmt, i: c_int, s: [*]const u8, n: c_int, d: isize) c_int;
    extern "c" fn sqlite3_column_count(stmt: *Stmt) c_int;
    extern "c" fn sqlite3_column_name(stmt: *Stmt, i: c_int) ?[*:0]const u8;
    extern "c" fn sqlite3_column_type(stmt: *Stmt, i: c_int) c_int;
    extern "c" fn sqlite3_column_text(stmt: *Stmt, i: c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_blob(stmt: *Stmt, i: c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_bytes(stmt: *Stmt, i: c_int) c_int;
};

/// Open databases. A handle is the table index plus one, so 0 and negatives
/// are never valid; a closed slot is reused. Not locked: the interpreter
/// calls builtins from one thread at a time.
const max_dbs = 256;
var dbs: [max_dbs]?*sqlite.Db = .{null} ** max_dbs;

fn dbFrom(v: *const Value, who: []const u8) EvalError!*sqlite.Db {
    if (v.* != .integer) return error.TypeError;
    const n = v.integer;
    if (n < 1 or n > max_dbs or dbs[@intCast(n - 1)] == null)
        return builtins.failArg("{s}: {d} is not an open database handle", .{ who, n });
    return dbs[@intCast(n - 1)].?;
}

fn errmsg(h: *sqlite.Db) []const u8 {
    return std.mem.span(sqlite.sqlite3_errmsg(h));
}

/// sqlite_open(path: String) -> Int
///
/// Opens (creating if need be) the database at `path` and runs
/// `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON`.
/// Answers a handle for the other sqlite_* builtins. ":memory:" works and is
/// private to its handle. Raises with sqlite's message when it cannot open,
/// or when 256 databases are already open.
pub fn sqliteOpen(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const path = allocator.dupeZ(u8, args[0].string) catch return error.OutOfMemory;
    defer allocator.free(path);
    var slot: usize = 0;
    while (slot < max_dbs and dbs[slot] != null) slot += 1;
    if (slot == max_dbs) return builtins.failArg("sqlite_open: {d} databases are open already", .{max_dbs});

    var db: ?*sqlite.Db = null;
    const rc = sqlite.sqlite3_open_v2(path.ptr, &db, sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE, null);
    const h = db orelse return error.OutOfMemory;
    if (rc != sqlite.OK) {
        const r = builtins.failArg("sqlite_open: cannot open {s}: {s}", .{ args[0].string, errmsg(h) });
        _ = sqlite.sqlite3_close(h);
        return r;
    }
    if (sqlite.sqlite3_exec(h, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON", null, null, null) != sqlite.OK) {
        const r = builtins.failArg("sqlite_open: {s}: {s}", .{ args[0].string, errmsg(h) });
        _ = sqlite.sqlite3_close(h);
        return r;
    }
    dbs[slot] = h;
    return box(allocator, .{ .integer = @intCast(slot + 1) });
}

/// sqlite_close(db: Int) -> nil. The handle is invalid afterwards. Raises on a
/// handle that is not open.
pub fn sqliteClose(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const h = try dbFrom(args[0], "sqlite_close");
    _ = sqlite.sqlite3_close(h);
    dbs[@intCast(args[0].integer - 1)] = null;
    return box(allocator, .nil);
}

/// sqlite_exec(db: Int, sql: String) -> Int
///
/// Runs `sql` through sqlite3_exec: any number of statements, no parameters,
/// results discarded. Answers how many rows those statements changed in all
/// (the difference in sqlite3_total_changes across the call). Raises with
/// sqlite's message; statements before the failing one have already run.
pub fn sqliteExec(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[1].* != .string) return error.TypeError;
    const h = try dbFrom(args[0], "sqlite_exec");
    if (std.mem.indexOfScalar(u8, args[1].string, 0) != null) return error.TypeError;
    const sql = allocator.dupeZ(u8, args[1].string) catch return error.OutOfMemory;
    defer allocator.free(sql);
    const before = sqlite.sqlite3_total_changes64(h);
    if (sqlite.sqlite3_exec(h, sql.ptr, null, null, null) != sqlite.OK)
        return builtins.failArg("sqlite_exec: {s}", .{errmsg(h)});
    return box(allocator, .{ .integer = sqlite.sqlite3_total_changes64(h) - before });
}

/// sqlite_last_id(db: Int) -> Int: the rowid of the last INSERT on this handle.
pub fn sqliteLastId(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const h = try dbFrom(args[0], "sqlite_last_id");
    return box(allocator, .{ .integer = sqlite.sqlite3_last_insert_rowid(h) });
}

/// sqlite_changes(db: Int) -> Int: rows changed by the most recent
/// INSERT, UPDATE or DELETE on this handle.
pub fn sqliteChanges(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const h = try dbFrom(args[0], "sqlite_changes");
    return box(allocator, .{ .integer = sqlite.sqlite3_changes64(h) });
}

/// sqlite_query(db: Int, sql: String, params: List) -> [[String|nil]]
///
/// Runs ONE statement; a second statement after it is an error. `params` are
/// bound by position (?, ?NNN, $1 ...): nil binds NULL, Int and Float bind
/// natively, a String binds as TEXT, and a Bool or atom binds as its
/// to_string; anything else (list, map, ...) is an error. The number of
/// params must equal the statement's parameter count.
///
/// Every cell comes back as text (sqlite3_column_text), NULL as nil, a BLOB as
/// lowercase hex. The FIRST row is the column names, then one row per result
/// row, so a SELECT that matches nothing answers just the header.
/// A statement with no result columns (INSERT, UPDATE, DELETE, DDL) answers
/// [["changes"], ["<n>"]], n being the rows it changed.
/// Empty or comment-only SQL answers [["changes"], ["0"]].
///
/// Raises with sqlite's message (e.g. "no such table: nope").
pub fn sqliteQuery(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3 or args[1].* != .string or args[2].* != .list) return error.TypeError;
    const h = try dbFrom(args[0], "sqlite_query");
    const params = args[2].list;
    const sql = args[1].string;

    var stmt: ?*sqlite.Stmt = null;
    var tail: [*]const u8 = sql.ptr;
    if (sqlite.sqlite3_prepare_v2(h, sql.ptr, @intCast(sql.len), &stmt, &tail) != sqlite.OK)
        return builtins.failArg("sqlite_query: {s}", .{errmsg(h)});
    const st = stmt orelse return changesResult(allocator, 0);
    defer _ = sqlite.sqlite3_finalize(st);
    const rest = sql[(@intFromPtr(tail) - @intFromPtr(sql.ptr))..];
    if (std.mem.trim(u8, rest, " \t\r\n;").len != 0)
        return builtins.failArg("sqlite_query: one statement per call, found more after the first", .{});

    const want: usize = @intCast(sqlite.sqlite3_bind_parameter_count(st));
    if (want != params.len)
        return builtins.failArg("sqlite_query: statement has {d} parameters, got {d}", .{ want, params.len });
    for (params, 1..) |p, i| {
        const idx: c_int = @intCast(i);
        const rc = switch (p.*) {
            .integer => |n| sqlite.sqlite3_bind_int64(st, idx, n),
            .float => |f| sqlite.sqlite3_bind_double(st, idx, f),
            .nil => sqlite.sqlite3_bind_null(st, idx),
            .string => |s| bindText(st, idx, s),
            .boolean => |b| bindText(st, idx, if (b) "true" else "false"),
            .atom => |a| bindText(st, idx, a),
            else => return builtins.failArg("sqlite_query: parameter {d} is a {s}; bindable: String, Int, Float, Bool, atom, nil", .{ i, @tagName(p.*) }),
        };
        if (rc != sqlite.OK) return builtins.failArg("sqlite_query: bind {d}: {s}", .{ i, errmsg(h) });
    }

    const ncols: usize = @intCast(sqlite.sqlite3_column_count(st));
    if (ncols == 0) {
        const rc = sqlite.sqlite3_step(st);
        if (rc != sqlite.DONE and rc != sqlite.ROW) return builtins.failArg("sqlite_query: {s}", .{errmsg(h)});
        return changesResult(allocator, sqlite.sqlite3_changes64(h));
    }

    var rows: std.ArrayList(*const Value) = .empty;
    const header = allocator.alloc(*const Value, ncols) catch return error.OutOfMemory;
    for (header, 0..) |*cell_, j| {
        const name = sqlite.sqlite3_column_name(st, @intCast(j));
        const copy = allocator.dupe(u8, if (name) |nm| std.mem.span(nm) else "") catch return error.OutOfMemory;
        cell_.* = try box(allocator, .{ .string = copy });
    }
    rows.append(allocator, try box(allocator, .{ .list = header })) catch return error.OutOfMemory;

    while (true) {
        const rc = sqlite.sqlite3_step(st);
        if (rc == sqlite.DONE) break;
        if (rc != sqlite.ROW) return builtins.failArg("sqlite_query: {s}", .{errmsg(h)});
        const cells = allocator.alloc(*const Value, ncols) catch return error.OutOfMemory;
        for (cells, 0..) |*cell_, j| {
            const col: c_int = @intCast(j);
            cell_.* = switch (sqlite.sqlite3_column_type(st, col)) {
                sqlite.NULL => try box(allocator, .nil),
                sqlite.BLOB => blk: {
                    const n: usize = @intCast(sqlite.sqlite3_column_bytes(st, col));
                    const p = sqlite.sqlite3_column_blob(st, col);
                    const hex = allocator.alloc(u8, n * 2) catch return error.OutOfMemory;
                    if (p) |q| _ = std.fmt.bufPrint(hex, "{x}", .{q[0..n]}) catch unreachable;
                    break :blk try box(allocator, .{ .string = hex });
                },
                else => blk: {
                    // sqlite3_column_text converts INTEGER and FLOAT to their text form.
                    const p = sqlite.sqlite3_column_text(st, col);
                    const n: usize = @intCast(sqlite.sqlite3_column_bytes(st, col));
                    const copy = allocator.dupe(u8, if (p) |q| q[0..n] else "") catch return error.OutOfMemory;
                    break :blk try box(allocator, .{ .string = copy });
                },
            };
        }
        rows.append(allocator, try box(allocator, .{ .list = cells })) catch return error.OutOfMemory;
    }
    return box(allocator, .{ .list = rows.toOwnedSlice(allocator) catch return error.OutOfMemory });
}

/// Binds text; sqlite copies it at once (SQLITE_TRANSIENT), so any slice will do.
fn bindText(st: *sqlite.Stmt, idx: c_int, s: []const u8) c_int {
    return sqlite.sqlite3_bind_text(st, idx, s.ptr, @intCast(s.len), sqlite.TRANSIENT);
}

/// [["changes"], ["<n>"]]
fn changesResult(allocator: std.mem.Allocator, n: i64) EvalError!*const Value {
    const head = allocator.alloc(*const Value, 1) catch return error.OutOfMemory;
    head[0] = try box(allocator, .{ .string = "changes" });
    const body = allocator.alloc(*const Value, 1) catch return error.OutOfMemory;
    body[0] = try box(allocator, .{ .string = std.fmt.allocPrint(allocator, "{d}", .{n}) catch return error.OutOfMemory });
    const rows = allocator.alloc(*const Value, 2) catch return error.OutOfMemory;
    rows[0] = try box(allocator, .{ .list = head });
    rows[1] = try box(allocator, .{ .list = body });
    return box(allocator, .{ .list = rows });
}

// ── tests ───────────────────────────────────────────────────

fn sv(a: std.mem.Allocator, s: []const u8) !*const Value {
    return box(a, .{ .string = s });
}

fn iv(a: std.mem.Allocator, n: i64) !*const Value {
    return box(a, .{ .integer = n });
}

fn nilv(a: std.mem.Allocator) !*const Value {
    return box(a, .nil);
}

fn lv(a: std.mem.Allocator, items: []const *const Value) !*const Value {
    return box(a, .{ .list = try a.dupe(*const Value, items) });
}

fn cell(v: *const Value, row: usize, col: usize) *const Value {
    return v.list[row].list[col];
}

fn memDb(a: std.mem.Allocator) !*const Value {
    return sqliteOpen(a, &.{try sv(a, ":memory:")});
}

test "exec answers status, stdout and stderr, and feeds stdin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try exec(a, &.{ try lv(a, &.{ try sv(a, "sh"), try sv(a, "-c"), try sv(a, "cat; echo oops 1>&2; exit 3") }), try sv(a, "hi"), try nilv(a) });
    try std.testing.expectEqual(@as(i64, 3), r.list[0].integer);
    try std.testing.expectEqualStrings("hi", r.list[1].string);
    try std.testing.expectEqualStrings("oops\n", r.list[2].string);

    const missing = try exec(a, &.{ try lv(a, &.{try sv(a, "no-such-program-xyz")}), try sv(a, ""), try nilv(a) });
    try std.testing.expectEqual(@as(i64, 127), missing.list[0].integer);

    try std.testing.expectError(error.TypeError, exec(a, &.{ try lv(a, &.{}), try sv(a, ""), try nilv(a) }));
    try std.testing.expectError(error.TypeError, exec(a, &.{ try lv(a, &.{try sv(a, "true")}), try sv(a, ""), try iv(a, 1) }));
}

test "exec honours cwd, reports a signal as negative, and a bad cwd as 126" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pwd = try exec(a, &.{ try lv(a, &.{try sv(a, "pwd")}), try sv(a, ""), try sv(a, "/") });
    try std.testing.expectEqualStrings("/\n", pwd.list[1].string);

    const killed = try exec(a, &.{ try lv(a, &.{ try sv(a, "sh"), try sv(a, "-c"), try sv(a, "kill -9 $$") }), try sv(a, ""), try nilv(a) });
    try std.testing.expectEqual(@as(i64, -9), killed.list[0].integer);

    const bad = try exec(a, &.{ try lv(a, &.{try sv(a, "true")}), try sv(a, ""), try sv(a, "/no/such/dir") });
    try std.testing.expectEqual(@as(i64, 126), bad.list[0].integer);
}

test "exec feeds a payload far bigger than a pipe to a child that echoes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // cat writes as it reads, so once both pipes (64 KiB each) are full each
    // side waits on the other unless the parent's writes to stdin never block.
    const big = try a.alloc(u8, 2 * 1024 * 1024);
    for (big, 0..) |*byte, i| byte.* = @intCast('a' + i % 26);
    const r = try exec(a, &.{ try lv(a, &.{try sv(a, "cat")}), try sv(a, big), try nilv(a) });
    try std.testing.expectEqual(@as(i64, 0), r.list[0].integer);
    try std.testing.expectEqualStrings(big, r.list[1].string);
}

test "exec closes inherited fds above 2 in the child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer closeAll(&fds);
    const cmd = try std.fmt.allocPrint(a, "if [ -e /dev/fd/{d} ]; then echo open; else echo closed; fi", .{fds[0]});
    const r = try exec(a, &.{ try lv(a, &.{ try sv(a, "sh"), try sv(a, "-c"), try sv(a, cmd) }), try sv(a, ""), try nilv(a) });
    try std.testing.expectEqualStrings("closed\n", r.list[1].string);
}

test "sqlite_query binds params and answers the header row then text cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try memDb(a);

    const rows = try sqliteQuery(a, &.{
        db,
        try sv(a, "select ? as i, ? as f, ? as t, null as n, x'00ff' as b"),
        try lv(a, &.{ try iv(a, 7), try box(a, .{ .float = 2.5 }), try sv(a, "it's \"x\" é") }),
    });
    try std.testing.expectEqual(@as(usize, 2), rows.list.len);
    try std.testing.expectEqualStrings("i", cell(rows, 0, 0).string);
    try std.testing.expectEqualStrings("n", cell(rows, 0, 3).string);
    try std.testing.expectEqualStrings("7", cell(rows, 1, 0).string);
    try std.testing.expectEqualStrings("2.5", cell(rows, 1, 1).string);
    try std.testing.expectEqualStrings("it's \"x\" é", cell(rows, 1, 2).string);
    try std.testing.expect(cell(rows, 1, 3).* == .nil);
    try std.testing.expectEqualStrings("00ff", cell(rows, 1, 4).string);
}

test "sqlite_query: nil, bool and atom params; wrong count, bad type, second statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try memDb(a);

    const r = try sqliteQuery(a, &.{ db, try sv(a, "select ?, ?, ?"), try lv(a, &.{ try nilv(a), try box(a, .{ .boolean = true }), try box(a, .{ .atom = "ok" }) }) });
    try std.testing.expect(cell(r, 1, 0).* == .nil);
    try std.testing.expectEqualStrings("true", cell(r, 1, 1).string);
    try std.testing.expectEqualStrings("ok", cell(r, 1, 2).string);

    try std.testing.expectError(error.TypeError, sqliteQuery(a, &.{ db, try sv(a, "select ?"), try lv(a, &.{}) }));
    try std.testing.expectError(error.TypeError, sqliteQuery(a, &.{ db, try sv(a, "select ?"), try lv(a, &.{try lv(a, &.{})}) }));
    try std.testing.expectError(error.TypeError, sqliteQuery(a, &.{ db, try sv(a, "select 1; select 2"), try lv(a, &.{}) }));
    _ = builtins.takeFailure();
    // A trailing semicolon and whitespace are not a second statement.
    _ = try sqliteQuery(a, &.{ db, try sv(a, "select 1; \n"), try lv(a, &.{}) });
}

test "sqlite errors carry sqlite's message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try memDb(a);

    try std.testing.expectError(error.TypeError, sqliteQuery(a, &.{ db, try sv(a, "select * from nope"), try lv(a, &.{}) }));
    try std.testing.expect(std.mem.indexOf(u8, builtins.takeFailure().?, "no such table: nope") != null);

    try std.testing.expectError(error.TypeError, sqliteExec(a, &.{ db, try sv(a, "create table t(a); bogus") }));
    try std.testing.expect(std.mem.indexOf(u8, builtins.takeFailure().?, "syntax error") != null);

    try std.testing.expectError(error.TypeError, sqliteOpen(a, &.{try sv(a, "/no/such/dir/x.db")}));
    try std.testing.expect(std.mem.indexOf(u8, builtins.takeFailure().?, "unable to open database file") != null);
}

test "sqlite round trip: exec, insert, changes, last_id, update, delete, no-column statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try memDb(a);
    const none = try lv(a, &.{});

    const created = try sqliteExec(a, &.{ db, try sv(a, "create table t(id integer primary key, name text, n integer); create index tn on t(n);") });
    try std.testing.expectEqual(@as(i64, 0), created.integer);

    const ins = try sqliteQuery(a, &.{ db, try sv(a, "insert into t(name, n) values (?, ?), (?, ?)"), try lv(a, &.{ try sv(a, "a"), try iv(a, 1), try nilv(a), try iv(a, 2) }) });
    try std.testing.expectEqualStrings("changes", cell(ins, 0, 0).string);
    try std.testing.expectEqualStrings("2", cell(ins, 1, 0).string);
    try std.testing.expectEqual(@as(i64, 2), (try sqliteChanges(a, &.{db})).integer);
    try std.testing.expectEqual(@as(i64, 2), (try sqliteLastId(a, &.{db})).integer);

    const all = try sqliteQuery(a, &.{ db, try sv(a, "select id, name, n from t order by id"), none });
    try std.testing.expectEqual(@as(usize, 3), all.list.len);
    try std.testing.expectEqualStrings("name", cell(all, 0, 1).string);
    try std.testing.expectEqualStrings("a", cell(all, 1, 1).string);
    try std.testing.expect(cell(all, 2, 1).* == .nil);
    try std.testing.expectEqualStrings("2", cell(all, 2, 2).string);

    const upd = try sqliteExec(a, &.{ db, try sv(a, "update t set n = n + 10; delete from t where id = 1") });
    try std.testing.expectEqual(@as(i64, 3), upd.integer);

    const empty = try sqliteQuery(a, &.{ db, try sv(a, "select * from t where id = 99"), none });
    try std.testing.expectEqual(@as(usize, 1), empty.list.len); // header only

    const comment = try sqliteQuery(a, &.{ db, try sv(a, "-- nothing"), none });
    try std.testing.expectEqualStrings("0", cell(comment, 1, 0).string);
}

test "sqlite: foreign keys are on, handles close and are reused, a stale handle raises" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try memDb(a);

    const fk = try sqliteQuery(a, &.{ db, try sv(a, "pragma foreign_keys"), try lv(a, &.{}) });
    try std.testing.expectEqualStrings("1", cell(fk, 1, 0).string);
    const bt = try sqliteQuery(a, &.{ db, try sv(a, "pragma busy_timeout"), try lv(a, &.{}) });
    try std.testing.expectEqualStrings("5000", cell(bt, 1, 0).string);

    _ = try sqliteClose(a, &.{db});
    try std.testing.expectError(error.TypeError, sqliteChanges(a, &.{db}));
    try std.testing.expect(std.mem.indexOf(u8, builtins.takeFailure().?, "not an open database") != null);
    const again = try memDb(a);
    try std.testing.expectEqual(db.integer, again.integer);
    _ = try sqliteClose(a, &.{again});
    try std.testing.expectError(error.TypeError, sqliteClose(a, &.{again}));
    _ = builtins.takeFailure();
}

test "sqlite_open on a file turns on WAL and persists across handles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/blimp-native-ext-{d}.db", .{std.c.getpid()});
    defer for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| {
        var b: [80]u8 = undefined;
        const p = std.fmt.bufPrintZ(&b, "{s}{s}", .{ path, suffix }) catch continue;
        _ = std.c.unlink(p.ptr);
    };

    const db = try sqliteOpen(a, &.{try sv(a, path)});
    const mode = try sqliteQuery(a, &.{ db, try sv(a, "pragma journal_mode"), try lv(a, &.{}) });
    try std.testing.expectEqualStrings("wal", cell(mode, 1, 0).string);
    _ = try sqliteExec(a, &.{ db, try sv(a, "create table t(x); insert into t values ('kept')") });
    _ = try sqliteClose(a, &.{db});

    const db2 = try sqliteOpen(a, &.{try sv(a, path)});
    const r = try sqliteQuery(a, &.{ db2, try sv(a, "select x from t"), try lv(a, &.{}) });
    try std.testing.expectEqualStrings("kept", cell(r, 1, 0).string);
    _ = try sqliteClose(a, &.{db2});
}

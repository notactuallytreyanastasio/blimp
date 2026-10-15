//! What a web application compiled from Temper needs from the machine, and
//! the interpreter did not have. Native only (builtins.zig stubs them on WASM).
//!
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

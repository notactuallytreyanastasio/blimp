//! Postgres, off the interpreter's thread.
//!
//!   h = pg_start(conn, sql, params)
//!   h = pg_start(conn, sql, params, %{timeout_ms: 2000})
//!   pg_result(h) -> nil (still going) | {:ok, rows} | {:error, reason}
//!   pg_stats()   -> %{in_flight: Int, idle: Int}
//!
//! `conn` is either the map the site's pg_connect takes
//! (%{host:, port:, user:, password:, database:}) or a URL,
//! "postgres://user:pass@host:5432/name" (ecto:// too; the password may be
//! percent-encoded). `params` go out as $1, $2, ... in the extended protocol,
//! never pasted into the SQL, and are sent and received as text:
//!
//!   nil -> NULL, true/false -> t/f, String as is, Int and Float as
//!   to_string writes them, Map and List as json_encode writes them.
//!   Anything else raises at pg_start.
//!
//! Rows are a list of maps from column name to value, decoded the way the
//! site's Blimp client (blimp_site/src/80_postgres.blimp) decodes them:
//!
//!   bool -> true/false; int2, int4, int8, oid -> Int; json, jsonb -> what
//!   json_decode makes of it; NULL -> nil; anything else its text, exactly
//!   as Postgres writes it (numeric, float, timestamps, arrays, ...).
//!
//! Why: the site is one thread. Its Blimp client waits on a blocking socket,
//! so one slow query stops every page and every WebSocket until Postgres
//! answers, and nothing bounds how long that is. Here the query runs on a
//! thread of its own and the program asks, from its own loop, whether it is
//! done -- the shape of http_start/http_result.
//!
//! Every query has a deadline, `timeout_ms` (15s unless the options say
//! otherwise, at most 600s), for all of it: DNS aside, connect, login, the
//! query and its rows. At the deadline pg_result answers {:error, "timeout"}
//! and the handle is free. The worker, on the same deadline, sends Postgres a
//! CancelRequest for the statement (so the server stops running it, rather
//! than finishing a query nobody will read) and closes that connection.
//! getaddrinfo cannot be interrupted; a resolver that hangs holds a worker
//! thread, never the program.
//!
//! Connections: a worker takes an idle connection with the same host, port,
//! user, password and database, or dials one. After a query that ended in
//! ReadyForQuery (rows or a server error alike) outside any transaction, the
//! connection goes back to an idle pool of `pool_max`; one past that is
//! closed. One left inside a transaction block, failed or not, is closed:
//! a transaction is one pg_start (a single statement, or a function), never
//! a run of them. Anything else -- a
//! timeout, a cut connection, a protocol surprise -- closes it. An idle
//! connection the server has closed (Postgres restarted) is readable, and is
//! dropped when it is taken instead of failing the query.
//!
//! Queries in flight at once run on separate connections, so two pg_starts
//! are not ordered against each other. A caller that needs order waits for
//! the first answer before starting the second.
//!
//! Login: trust, SCRAM-SHA-256 and md5. A cleartext password request is
//! refused, as the Blimp client refuses it. No TLS, as the Blimp client has
//! none. Passwords are used as bytes, without SASLprep: right for ASCII.
//!
//! The WebAssembly build has no threads or sockets; these raise there.

const std = @import("std");
const builtin = @import("builtin");
const builtins = @import("builtins.zig");
const ioenv = @import("ioenv.zig");
const Value = @import("value.zig").Value;
const EvalError = builtins.EvalError;

pub const slots_max = 32;
pub const pool_max = 4;
pub const timeout_default_ms: i64 = 15_000;
pub const timeout_max_ms: i64 = 600_000;
/// The most bytes of row data one query may hand back.
pub const result_max: usize = 64 * 1024 * 1024;
/// The largest single message accepted from the server.
const message_max: usize = 256 * 1024 * 1024;
const cancel_timeout_ms: i64 = 2_000;

const pa = std.heap.page_allocator;

// ── connection parameters ───────────────────────────────────────────

pub const ConnInfo = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,

    fn eql(a: ConnInfo, b: ConnInfo) bool {
        return a.port == b.port and std.mem.eql(u8, a.host, b.host) and
            std.mem.eql(u8, a.user, b.user) and std.mem.eql(u8, a.password, b.password) and
            std.mem.eql(u8, a.database, b.database);
    }

    fn dupe(self: ConnInfo, a: std.mem.Allocator) !ConnInfo {
        return .{
            .host = try a.dupe(u8, self.host),
            .port = self.port,
            .user = try a.dupe(u8, self.user),
            .password = try a.dupe(u8, self.password),
            .database = try a.dupe(u8, self.database),
        };
    }
};

/// %XX decoding, nothing else: a '+' in a URL's userinfo is a '+'.
fn percentDecode(a: std.mem.Allocator, s: []const u8) !?[]u8 {
    const out = try a.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return null;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return null;
            out[n] = hi * 16 + lo;
            i += 2;
        } else out[n] = s[i];
        n += 1;
    }
    return out[0..n];
}

/// "postgres://user:pass@host:port/db?..." -> ConnInfo, or null. The same
/// reading as the site's pg_parse_url: the last '@' ends the userinfo, the
/// port is 5432 unless one is given, anything after '?' is ignored.
pub fn parseUrl(a: std.mem.Allocator, url: []const u8) !?ConnInfo {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return null;
    if (scheme == 0) return null;
    const rest = url[scheme + 3 ..];
    const at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse return null;
    if (at == 0) return null;
    const slash = std.mem.indexOfScalarPos(u8, rest, at + 1, '/') orelse return null;
    const userinfo = rest[0..at];
    const hostport = rest[at + 1 .. slash];
    const path = rest[slash + 1 ..];
    const colon = std.mem.indexOfScalar(u8, userinfo, ':');
    const user_raw = if (colon) |c| userinfo[0..c] else userinfo;
    const pass_raw = if (colon) |c| userinfo[c + 1 ..] else "";
    const host_colon = std.mem.indexOfScalar(u8, hostport, ':');
    const host = if (host_colon) |c| hostport[0..c] else hostport;
    var port: u16 = 5432;
    if (host_colon) |c| port = std.fmt.parseInt(u16, hostport[c + 1 ..], 10) catch return null;
    const db = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[0..q] else path;
    if (host.len == 0 or db.len == 0) return null;
    return .{
        .host = host,
        .port = port,
        .user = (try percentDecode(a, user_raw)) orelse return null,
        .password = (try percentDecode(a, pass_raw)) orelse return null,
        .database = db,
    };
}

// ── a deadline-bound socket ─────────────────────────────────────────

fn monoMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

const Fail = error{ Failed, Timeout };

/// Where a worker writes why it failed. Fixed size: it is read after the
/// worker has finished, from the job, never shared.
const Reason = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn set(self: *Reason, comptime fmt: []const u8, args: anytype) Fail {
        self.write(fmt, args);
        return error.Failed;
    }

    fn write(self: *Reason, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            const tail = "...";
            @memcpy(self.buf[self.buf.len - tail.len ..], tail);
            break :blk self.buf[0..];
        };
        self.len = msg.len;
    }

    fn text(self: *const Reason) []const u8 {
        return self.buf[0..self.len];
    }
};

fn setNonblocking(fd: c_int) bool {
    const fl = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (fl < 0) return false;
    const nonblock: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    return std.c.fcntl(fd, std.posix.F.SETFL, fl | nonblock) >= 0;
}

/// Wait until `fd` is ready for `events` or the deadline passes.
fn waitFor(fd: c_int, events: i16, deadline: i64) Fail!void {
    while (true) {
        const left = deadline - monoMs();
        if (left <= 0) return error.Timeout;
        var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const n = std.posix.poll(&pfd, @intCast(@min(left, 1000))) catch return error.Failed;
        if (n > 0) return;
    }
}

/// A TCP connection to host:port, made before the deadline, non-blocking.
fn dialTcp(host: []const u8, port: u16, deadline: i64, why: *Reason) Fail!c_int {
    var host_buf: [256]u8 = undefined;
    if (host.len == 0 or host.len >= host_buf.len) return why.set("cannot reach a host of {d} bytes", .{host.len});
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    var port_buf: [8]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_buf, "{d}\x00", .{port}) catch unreachable;

    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.posix.AF.UNSPEC;
    hints.socktype = std.posix.SOCK.STREAM;
    var res: ?*std.c.addrinfo = null;
    if (std.c.getaddrinfo(@ptrCast(&host_buf), @ptrCast(port_text.ptr), &hints, &res) != @as(std.c.EAI, @enumFromInt(0)))
        return why.set("cannot resolve {s}", .{host});
    defer if (res) |r| std.c.freeaddrinfo(r);

    var it = res;
    var timed_out = false;
    while (it) |info| : (it = info.next) {
        const addr = info.addr orelse continue;
        const fd = std.c.socket(@intCast(info.family), @intCast(info.socktype), @intCast(info.protocol));
        if (fd < 0) continue;
        if (!setNonblocking(fd)) {
            _ = std.c.close(fd);
            continue;
        }
        if (builtin.os.tag.isDarwin()) {
            // A write to a closed socket must be an error here, not SIGPIPE.
            var one: c_int = 1;
            _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, @ptrCast(&one), @sizeOf(c_int));
        }
        if (std.c.connect(fd, addr, info.addrlen) == 0) return fd;
        if (std.c._errno().* != @intFromEnum(std.posix.E.INPROGRESS)) {
            _ = std.c.close(fd);
            continue;
        }
        waitFor(fd, std.posix.POLL.OUT, deadline) catch |e| {
            _ = std.c.close(fd);
            if (e == error.Timeout) {
                timed_out = true;
                break;
            }
            continue;
        };
        var err: c_int = 0;
        var len: std.posix.socklen_t = @sizeOf(c_int);
        if (std.c.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&err), &len) == 0 and err == 0) return fd;
        _ = std.c.close(fd);
    }
    if (timed_out) return error.Timeout;
    return why.set("cannot reach {s}:{d}", .{ host, port });
}

fn sendAll(fd: c_int, bytes: []const u8, deadline: i64, why: *Reason) Fail!void {
    const flags: c_int = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.send(fd, bytes[off..].ptr, bytes.len - off, flags);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        const e = std.c._errno().*;
        if (n < 0 and e == @intFromEnum(std.posix.E.INTR)) continue;
        if (n < 0 and e == @intFromEnum(std.posix.E.AGAIN)) {
            try waitFor(fd, std.posix.POLL.OUT, deadline);
            continue;
        }
        return why.set("the database connection is closed (write failed, errno {d})", .{e});
    }
}

// ── messages out ────────────────────────────────────────────────────

const Out = struct {
    buf: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn byte(self: *Out, b: u8) !void {
        try self.buf.append(self.a, b);
    }
    fn int32(self: *Out, n: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, n, .big);
        try self.buf.appendSlice(self.a, &b);
    }
    fn int16(self: *Out, n: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, n, .big);
        try self.buf.appendSlice(self.a, &b);
    }
    fn bytes(self: *Out, s: []const u8) !void {
        try self.buf.appendSlice(self.a, s);
    }
    fn cstr(self: *Out, s: []const u8) !void {
        try self.buf.appendSlice(self.a, s);
        try self.buf.append(self.a, 0);
    }
    /// A typed message: the type byte, then room for its length.
    fn begin(self: *Out, t: u8) !usize {
        try self.byte(t);
        const at = self.buf.items.len;
        try self.int32(0);
        return at;
    }
    /// The length counts itself and the body, not the type byte.
    fn end(self: *Out, at: usize) void {
        const len: i32 = @intCast(self.buf.items.len - at);
        std.mem.writeInt(i32, self.buf.items[at..][0..4], len, .big);
    }
};

/// StartupMessage: no type byte, protocol 3.0, then name/value pairs.
pub fn writeStartup(o: *Out, info: ConnInfo) !void {
    const at = o.buf.items.len;
    try o.int32(0);
    try o.int32(196608);
    try o.cstr("user");
    try o.cstr(info.user);
    try o.cstr("database");
    try o.cstr(info.database);
    try o.cstr("client_encoding");
    try o.cstr("UTF8");
    try o.byte(0);
    o.end(at);
}

/// Parse, Bind (text params, text results), Describe the portal, Execute
/// with no row limit, Sync -- one round trip.
pub fn writeQuery(o: *Out, sql: []const u8, params: []const ?[]const u8) !void {
    var at = try o.begin('P');
    try o.cstr("");
    try o.cstr(sql);
    try o.int16(0);
    o.end(at);
    at = try o.begin('B');
    try o.cstr("");
    try o.cstr("");
    try o.int16(0);
    try o.int16(@intCast(params.len));
    for (params) |p| {
        if (p) |text| {
            try o.int32(@intCast(text.len));
            try o.bytes(text);
        } else try o.int32(-1);
    }
    try o.int16(0);
    o.end(at);
    at = try o.begin('D');
    try o.byte('P');
    try o.cstr("");
    o.end(at);
    at = try o.begin('E');
    try o.cstr("");
    try o.int32(0);
    o.end(at);
    at = try o.begin('S');
    o.end(at);
}

// ── messages in ─────────────────────────────────────────────────────

pub const Msg = struct { t: u8, body: []const u8 };

/// Bytes read from a socket and not yet handed out as messages. A message's
/// body points into `buf` and is good until the next `next`.
const Reader = struct {
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    fn deinit(self: *Reader) void {
        self.buf.deinit(pa);
    }

    /// The next whole message in what has been read, if there is one.
    fn take(self: *Reader, why: *Reason) Fail!?Msg {
        const have = self.buf.items[self.pos..];
        if (have.len < 5) return null;
        const len = std.mem.readInt(u32, have[1..5], .big);
        if (len < 4 or len > message_max) return why.set("the server sent a message of length {d}", .{len});
        const total = @as(usize, len) + 1;
        if (have.len < total) return null;
        self.pos += total;
        return .{ .t = have[0], .body = have[5..total] };
    }

    fn next(self: *Reader, fd: c_int, deadline: i64, why: *Reason) Fail!Msg {
        // what was handed out last time is spent: move the rest down
        if (self.pos > 0) {
            const rest = self.buf.items.len - self.pos;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.pos..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.pos = 0;
        }
        while (true) {
            if (try self.take(why)) |m| return m;
            self.buf.ensureUnusedCapacity(pa, 64 * 1024) catch return why.set("out of memory reading a reply", .{});
            const room = self.buf.unusedCapacitySlice();
            const n = std.c.read(fd, room.ptr, room.len);
            if (n > 0) {
                self.buf.items.len += @intCast(n);
                continue;
            }
            if (n == 0) return why.set("the database closed the connection", .{});
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.posix.E.INTR)) continue;
            if (e == @intFromEnum(std.posix.E.AGAIN)) {
                try waitFor(fd, std.posix.POLL.IN, deadline);
                continue;
            }
            return why.set("the database connection failed (read errno {d})", .{e});
        }
    }
};

fn readI32(b: []const u8, at: usize) ?i32 {
    if (at + 4 > b.len) return null;
    return std.mem.readInt(i32, b[at..][0..4], .big);
}

fn readU16(b: []const u8, at: usize) ?u16 {
    if (at + 2 > b.len) return null;
    return std.mem.readInt(u16, b[at..][0..2], .big);
}

/// The NUL-terminated string at `at`, and where the next field starts.
fn readCstr(b: []const u8, at: usize) ?struct { []const u8, usize } {
    if (at > b.len) return null;
    const z = std.mem.indexOfScalarPos(u8, b, at, 0) orelse return null;
    return .{ b[at..z], z + 1 };
}

/// An ErrorResponse body -> "ERROR 42P01: relation \"x\" does not exist",
/// the text the site's pg_error_text makes.
pub fn errorText(body: []const u8, why: *Reason) Fail {
    writeErrorText(body, why);
    return error.Failed;
}

fn writeErrorText(body: []const u8, why: *Reason) void {
    var sev: []const u8 = "";
    var code: []const u8 = "";
    var msg: []const u8 = "";
    var at: usize = 0;
    while (at < body.len and body[at] != 0) {
        const field = body[at];
        const s = readCstr(body, at + 1) orelse break;
        switch (field) {
            'S' => sev = s[0],
            'C' => code = s[0],
            'M' => msg = s[0],
            else => {},
        }
        at = s[1];
    }
    why.write("{s} {s}: {s}", .{ sev, code, msg });
}

pub const Column = struct { name: []const u8, oid: i32 };

/// RowDescription -> columns, names copied into `a`.
pub fn parseColumns(a: std.mem.Allocator, body: []const u8, why: *Reason) Fail![]Column {
    const n = readU16(body, 0) orelse return why.set("a RowDescription too short", .{});
    const cols = a.alloc(Column, n) catch return why.set("out of memory", .{});
    var at: usize = 2;
    for (cols) |*c| {
        const s = readCstr(body, at) orelse return why.set("a RowDescription cut short", .{});
        // after the name: table oid (4), column number (2), type oid (4),
        // type size (2), type modifier (4), format (2)
        const oid = readI32(body, s[1] + 6) orelse return why.set("a RowDescription cut short", .{});
        if (s[1] + 18 > body.len) return why.set("a RowDescription cut short", .{});
        c.* = .{ .name = a.dupe(u8, s[0]) catch return why.set("out of memory", .{}), .oid = oid };
        at = s[1] + 18;
    }
    return cols;
}

/// DataRow -> one cell per column (null for NULL), pointing into a copy of
/// the body made in `a`.
pub fn parseRow(a: std.mem.Allocator, body: []const u8, ncols: usize, why: *Reason) Fail![]?[]const u8 {
    const n = readU16(body, 0) orelse return why.set("a DataRow too short", .{});
    if (n != ncols) return why.set("a DataRow of {d} columns after a RowDescription of {d}", .{ n, ncols });
    const copy = a.dupe(u8, body) catch return why.set("out of memory", .{});
    const cells = a.alloc(?[]const u8, n) catch return why.set("out of memory", .{});
    var at: usize = 2;
    for (cells) |*cell| {
        const len = readI32(copy, at) orelse return why.set("a DataRow cut short", .{});
        at += 4;
        if (len < 0) {
            cell.* = null;
            continue;
        }
        const l: usize = @intCast(len);
        if (at + l > copy.len) return why.set("a DataRow cut short", .{});
        cell.* = copy[at .. at + l];
        at += l;
    }
    return cells;
}

// ── login ───────────────────────────────────────────────────────────

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.standard;

fn hmac(key: []const u8, msg: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Hmac.create(&out, msg, key);
    return out;
}

/// The value of `key=` in a SCRAM message, or "".
fn scramAttr(message: []const u8, key: u8) []const u8 {
    var it = std.mem.splitScalar(u8, message, ',');
    while (it.next()) |p| {
        if (p.len >= 2 and p[0] == key and p[1] == '=') return p[2..];
    }
    return "";
}

pub const ScramAnswer = struct { client_final: []u8, server_final: []u8 };

/// The client's final message and the server's final message it must get
/// back if the server knows the password too (RFC 5802, RFC 7677). Pure, so
/// RFC 7677's worked example can check it.
pub fn scramAnswer(a: std.mem.Allocator, password: []const u8, bare: []const u8, server_first: []const u8, why: *Reason) Fail!ScramAnswer {
    const salt_b64 = scramAttr(server_first, 's');
    const iter_text = scramAttr(server_first, 'i');
    const nonce = scramAttr(server_first, 'r');
    const iterations = std.fmt.parseInt(u32, iter_text, 10) catch return why.set("the server's SCRAM iteration count is not a number", .{});
    if (iterations < 1 or iterations > 10_000_000) return why.set("the server asks for {d} SCRAM iterations", .{iterations});
    var salt_buf: [128]u8 = undefined;
    const salt_len = b64.Decoder.calcSizeForSlice(salt_b64) catch return why.set("the server's SCRAM salt is not base64", .{});
    if (salt_len > salt_buf.len) return why.set("the server's SCRAM salt is too long", .{});
    b64.Decoder.decode(salt_buf[0..salt_len], salt_b64) catch return why.set("the server's SCRAM salt is not base64", .{});

    var salted: [32]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&salted, password, salt_buf[0..salt_len], iterations, Hmac) catch return why.set("PBKDF2 refused its parameters", .{});
    const client_key = hmac(&salted, "Client Key");
    var stored_key: [32]u8 = undefined;
    Sha256.hash(&client_key, &stored_key, .{});
    const without_proof = std.fmt.allocPrint(a, "c=biws,r={s}", .{nonce}) catch return why.set("out of memory", .{});
    const auth_message = std.fmt.allocPrint(a, "{s},{s},{s}", .{ bare, server_first, without_proof }) catch return why.set("out of memory", .{});
    var proof = hmac(&stored_key, auth_message);
    for (&proof, client_key) |*p, k| p.* ^= k;
    const server_key = hmac(&salted, "Server Key");
    const server_sig = hmac(&server_key, auth_message);
    var proof_b64: [44]u8 = undefined;
    var sig_b64: [44]u8 = undefined;
    _ = b64.Encoder.encode(&proof_b64, &proof);
    _ = b64.Encoder.encode(&sig_b64, &server_sig);
    return .{
        .client_final = std.fmt.allocPrint(a, "{s},p={s}", .{ without_proof, proof_b64 }) catch return why.set("out of memory", .{}),
        .server_final = std.fmt.allocPrint(a, "v={s}", .{sig_b64}) catch return why.set("out of memory", .{}),
    };
}

/// "md5" ++ hex(md5(hex(md5(password ++ user)) ++ salt)), NUL-terminated
/// in the PasswordMessage by the caller.
pub fn md5Password(user: []const u8, password: []const u8, salt: [4]u8) [35]u8 {
    const Md5 = std.crypto.hash.Md5;
    var inner: [16]u8 = undefined;
    var h = Md5.init(.{});
    h.update(password);
    h.update(user);
    h.final(&inner);
    const inner_hex = std.fmt.bytesToHex(inner, .lower);
    var outer: [16]u8 = undefined;
    h = Md5.init(.{});
    h.update(&inner_hex);
    h.update(&salt);
    h.final(&outer);
    var out: [35]u8 = undefined;
    @memcpy(out[0..3], "md5");
    out[3..].* = std.fmt.bytesToHex(outer, .lower);
    return out;
}

// ── a connection ────────────────────────────────────────────────────

const Conn = struct {
    fd: c_int,
    info: ConnInfo,
    info_arena: std.heap.ArenaAllocator,
    pid: i32 = 0,
    secret: i32 = 0,
    reader: Reader = .{},
    /// ReadyForQuery's transaction status after the last query: 'I' idle,
    /// 'T' inside a transaction block, 'E' inside a failed one.
    tx_status: u8 = 'I',

    fn close(self: *Conn, polite: bool) void {
        if (polite) {
            // Terminate; if it does not go out at once, closing says the same
            const x = [_]u8{ 'X', 0, 0, 0, 4 };
            _ = std.c.write(self.fd, &x, x.len);
        }
        _ = std.c.close(self.fd);
        self.reader.deinit();
        self.info_arena.deinit();
        pa.destroy(self);
    }

    fn send(self: *Conn, o: *Out, deadline: i64, why: *Reason) Fail!void {
        try sendAll(self.fd, o.buf.items, deadline, why);
    }
};

fn dial(info: ConnInfo, deadline: i64, why: *Reason) Fail!*Conn {
    const fd = try dialTcp(info.host, info.port, deadline, why);
    const conn = pa.create(Conn) catch {
        _ = std.c.close(fd);
        return why.set("out of memory", .{});
    };
    conn.* = .{ .fd = fd, .info = undefined, .info_arena = .init(pa) };
    conn.info = info.dupe(conn.info_arena.allocator()) catch {
        conn.close(false);
        return why.set("out of memory", .{});
    };
    login(conn, deadline, why) catch |e| {
        conn.close(false);
        return e;
    };
    return conn;
}

/// Everything between the startup message and the first ReadyForQuery.
fn login(conn: *Conn, deadline: i64, why: *Reason) Fail!void {
    var scratch = std.heap.ArenaAllocator.init(pa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var o: Out = .{ .a = a };
    writeStartup(&o, conn.info) catch return why.set("out of memory", .{});
    try conn.send(&o, deadline, why);

    var bare: []const u8 = "";
    var expect: []const u8 = "";
    while (true) {
        const m = try conn.reader.next(conn.fd, deadline, why);
        switch (m.t) {
            'R' => {
                const code = readI32(m.body, 0) orelse return why.set("an Authentication message too short", .{});
                const data = m.body[4..];
                o.buf.clearRetainingCapacity();
                switch (code) {
                    0 => {},
                    5 => {
                        if (data.len < 4) return why.set("an md5 request without a salt", .{});
                        const pw = md5Password(conn.info.user, conn.info.password, data[0..4].*);
                        const at = o.begin('p') catch return why.set("out of memory", .{});
                        o.cstr(&pw) catch return why.set("out of memory", .{});
                        o.end(at);
                        try conn.send(&o, deadline, why);
                    },
                    10 => {
                        if (std.mem.indexOf(u8, data, "SCRAM-SHA-256\x00") == null)
                            return why.set("the server offers no SCRAM-SHA-256", .{});
                        var nonce_raw: [18]u8 = undefined;
                        ioenv.io.randomSecure(&nonce_raw) catch return why.set("no random bytes for a SCRAM nonce", .{});
                        var nonce: [24]u8 = undefined;
                        _ = b64.Encoder.encode(&nonce, &nonce_raw);
                        // The user name goes in the startup message, and
                        // Postgres ignores the one here, so it is left empty.
                        bare = std.fmt.allocPrint(a, "n=,r={s}", .{nonce}) catch return why.set("out of memory", .{});
                        const at = o.begin('p') catch return why.set("out of memory", .{});
                        o.cstr("SCRAM-SHA-256") catch return why.set("out of memory", .{});
                        o.int32(@intCast(bare.len + 3)) catch return why.set("out of memory", .{});
                        o.bytes("n,,") catch return why.set("out of memory", .{});
                        o.bytes(bare) catch return why.set("out of memory", .{});
                        o.end(at);
                        try conn.send(&o, deadline, why);
                    },
                    11 => {
                        if (bare.len == 0) return why.set("a SASLContinue before SASL began", .{});
                        const theirs = scramAttr(data, 'r');
                        const mine = scramAttr(bare, 'r');
                        if (!std.mem.startsWith(u8, theirs, mine) or theirs.len <= mine.len)
                            return why.set("the server's SCRAM nonce does not extend ours", .{});
                        const ans = try scramAnswer(a, conn.info.password, bare, data, why);
                        expect = ans.server_final;
                        const at = o.begin('p') catch return why.set("out of memory", .{});
                        o.bytes(ans.client_final) catch return why.set("out of memory", .{});
                        o.end(at);
                        try conn.send(&o, deadline, why);
                    },
                    12 => {
                        if (expect.len == 0 or !std.mem.eql(u8, data, expect))
                            return why.set("the server's SCRAM signature is wrong: it does not know the password", .{});
                    },
                    // 3 is a cleartext password. Not sent: there is no TLS
                    // here, and a server that asks for less than md5 is not
                    // the one this was meant to reach.
                    else => return why.set("unsupported authentication method {d}", .{code}),
                }
            },
            'K' => {
                conn.pid = readI32(m.body, 0) orelse 0;
                conn.secret = readI32(m.body, 4) orelse 0;
            },
            'S', 'N' => {},
            'E' => return errorText(m.body, why),
            'Z' => return,
            else => return why.set("unexpected message during login: {c}", .{m.t}),
        }
    }
}

/// CancelRequest on a connection of its own: Postgres stops the statement
/// the backend `pid` is running. Best effort, on its own short deadline.
fn cancel(conn: *Conn) void {
    if (conn.pid == 0) return;
    var why: Reason = .{};
    const deadline = monoMs() + cancel_timeout_ms;
    const fd = dialTcp(conn.info.host, conn.info.port, deadline, &why) catch return;
    defer _ = std.c.close(fd);
    var msg: [16]u8 = undefined;
    std.mem.writeInt(i32, msg[0..4], 16, .big);
    std.mem.writeInt(i32, msg[4..8], 80877102, .big);
    std.mem.writeInt(i32, msg[8..12], conn.pid, .big);
    std.mem.writeInt(i32, msg[12..16], conn.secret, .big);
    sendAll(fd, &msg, deadline, &why) catch return;
    // The server answers by closing; waiting for that makes sure the request
    // was read before our close could reset it.
    var b: [16]u8 = undefined;
    waitFor(fd, std.posix.POLL.IN, deadline) catch return;
    _ = std.c.read(fd, &b, b.len);
}

// ── the pool ────────────────────────────────────────────────────────

var pool_lock: std.atomic.Value(bool) = .init(false);
var pool: [pool_max]?*Conn = .{null} ** pool_max;
var in_flight: std.atomic.Value(u32) = .init(0);

fn lock() void {
    while (pool_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    pool_lock.store(false, .release);
}

/// An idle connection to the same place, alive as far as can be told.
fn takeIdle(info: ConnInfo) ?*Conn {
    while (true) {
        lock();
        var found: ?*Conn = null;
        for (&pool) |*slot| {
            if (slot.*) |c| if (c.info.eql(info)) {
                found = c;
                slot.* = null;
                break;
            };
        }
        unlock();
        const c = found orelse return null;
        // An idle connection has nothing to say. One that is readable has
        // been closed by the server (a restart, idle_session_timeout) or
        // sent something unasked; either way it is not one to query on.
        var pfd = [1]std.posix.pollfd{.{ .fd = c.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&pfd, 0) catch 1;
        if (n == 0) return c;
        c.close(false);
    }
}

fn giveIdle(c: *Conn) void {
    lock();
    for (&pool) |*slot| {
        if (slot.* == null) {
            slot.* = c;
            unlock();
            return;
        }
    }
    unlock();
    c.close(true);
}

fn idleCount() usize {
    lock();
    defer unlock();
    var n: usize = 0;
    for (pool) |slot| {
        if (slot != null) n += 1;
    }
    return n;
}

/// Close every idle connection. For tests, and for a program that wants
/// its connections to see a changed password.
pub fn drainPool() void {
    while (true) {
        lock();
        var found: ?*Conn = null;
        for (&pool) |*slot| {
            if (slot.*) |c| {
                found = c;
                slot.* = null;
                break;
            }
        }
        unlock();
        const c = found orelse return;
        c.close(true);
    }
}

// ── a query, on its worker ──────────────────────────────────────────

pub const Job = struct {
    // 1 running, 2 rows, 3 failed, 4 abandoned by the program. The worker
    // moves 1 -> 2|3, pg_result moves 1 -> 4; whoever loses the race to move
    // it off 1 knows the other side owns the job now.
    state: std.atomic.Value(u8) = .init(1),
    arena: std.heap.ArenaAllocator,
    info: ConnInfo = undefined,
    sql: []const u8 = "",
    params: []const ?[]const u8 = &.{},
    deadline: i64 = 0,
    columns: []Column = &.{},
    rows: std.ArrayList([]?[]const u8) = .empty,
    why: Reason = .{},
};

fn freeJob(job: *Job) void {
    job.arena.deinit();
    pa.destroy(job);
}

fn runQuery(job: *Job, conn: *Conn) Fail!bool {
    const a = job.arena.allocator();
    var o: Out = .{ .a = a };
    writeQuery(&o, job.sql, job.params) catch return job.why.set("out of memory", .{});
    try conn.send(&o, job.deadline, &job.why);
    var bytes: usize = 0;
    var server_error = false;
    while (true) {
        const m = try conn.reader.next(conn.fd, job.deadline, &job.why);
        switch (m.t) {
            'T' => job.columns = try parseColumns(a, m.body, &job.why),
            'D' => {
                bytes += m.body.len;
                if (bytes > result_max) return job.why.set("the result is more than {d} MiB", .{result_max >> 20});
                const row = try parseRow(a, m.body, job.columns.len, &job.why);
                job.rows.append(a, row) catch return job.why.set("out of memory", .{});
            },
            'E' => {
                // the first error is the one that says why; keep reading
                // to ReadyForQuery so the connection can be used again
                if (!server_error) writeErrorText(m.body, &job.why);
                server_error = true;
            },
            'Z' => {
                conn.tx_status = if (m.body.len >= 1) m.body[0] else 'E';
                return !server_error;
            },
            // ParseComplete, BindComplete, NoData, CommandComplete,
            // EmptyQueryResponse, Notice, ParameterStatus, Notification
            '1', '2', 'n', 'C', 'I', 'N', 'S', 'A' => {},
            else => return job.why.set("unexpected message during a query: {c}", .{m.t}),
        }
    }
}

fn worker(job: *Job) void {
    const ok = blk: {
        const conn = takeIdle(job.info) orelse (dial(job.info, job.deadline, &job.why) catch |e| {
            if (e == error.Timeout) job.why.write("timeout", .{});
            break :blk false;
        });
        const clean = runQuery(job, conn) catch |e| {
            if (e == error.Timeout) {
                cancel(conn);
                job.why.write("timeout", .{});
            }
            conn.close(false);
            break :blk false;
        };
        // Only a connection outside any transaction goes back to the pool.
        // One left in a block ('T', after a BEGIN with no COMMIT) or a failed
        // one ('E') would hand the next, unrelated pg_start someone else's
        // transaction: after a failed statement every later query on it is
        // ERROR 25P02 until it leaves the pool. Pooled connections were never
        // a way to run a transaction across pg_starts (two calls may land on
        // different connections), so closing it rolls back what nobody could
        // have committed.
        if (conn.tx_status == 'I') giveIdle(conn) else conn.close(true);
        break :blk clean;
    };
    _ = in_flight.fetchSub(1, .monotonic);
    if (job.state.cmpxchgStrong(1, if (ok) 2 else 3, .acq_rel, .acquire) != null) {
        freeJob(job); // the program stopped waiting; nobody else will
    }
}

// ── the builtins ────────────────────────────────────────────────────

const Slot = struct { job: ?*Job = null, deadline: i64 = 0 };
// touched only by the interpreter's thread
var slots: [slots_max]Slot = [_]Slot{.{}} ** slots_max;

fn box(allocator: std.mem.Allocator, v: Value) EvalError!*const Value {
    const p = allocator.create(Value) catch return error.OutOfMemory;
    p.* = v;
    return p;
}

fn pair(allocator: std.mem.Allocator, tag: []const u8, v: *const Value) EvalError!*const Value {
    const items = allocator.alloc(*const Value, 2) catch return error.OutOfMemory;
    items[0] = try box(allocator, .{ .atom = tag });
    items[1] = v;
    return box(allocator, .{ .tuple = items });
}

fn connFromMap(entries: []const Value.MapEntry) EvalError!ConnInfo {
    var info: ConnInfo = .{ .host = "", .port = 0, .user = "", .password = "", .database = "" };
    var seen: u8 = 0;
    for (entries) |e| {
        const k = e.key;
        if (std.mem.eql(u8, k, "port")) {
            if (e.val.* != .integer or e.val.integer < 1 or e.val.integer > 65535)
                return builtins.failArg("pg_start: port must be an Int in 1..65535", .{});
            info.port = @intCast(e.val.integer);
            seen |= 1;
            continue;
        }
        const field: *[]const u8, const bit: u8 = if (std.mem.eql(u8, k, "host"))
            .{ &info.host, 2 }
        else if (std.mem.eql(u8, k, "user"))
            .{ &info.user, 4 }
        else if (std.mem.eql(u8, k, "password"))
            .{ &info.password, 8 }
        else if (std.mem.eql(u8, k, "database"))
            .{ &info.database, 16 }
        else
            return builtins.failArg("pg_start: the connection map has a key `{s}`; it takes host, port, user, password, database", .{k});
        if (e.val.* != .string) return builtins.failArg("pg_start: `{s}` must be a String", .{k});
        if (std.mem.indexOfScalar(u8, e.val.string, 0) != null) return builtins.failArg("pg_start: `{s}` has a NUL in it", .{k});
        field.* = e.val.string;
        seen |= bit;
    }
    if (seen != 31) return builtins.failArg("pg_start: the connection map needs host, port, user, password and database", .{});
    if (info.host.len == 0) return builtins.failArg("pg_start: host is empty", .{});
    return info;
}

/// One parameter as the text Postgres is sent, or null for NULL.
fn paramText(a: std.mem.Allocator, v: *const Value, i: usize) EvalError!?[]const u8 {
    return switch (v.*) {
        .nil => null,
        .boolean => |b| if (b) "t" else "f",
        .string => |s| try dupeOom(a, s),
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}) catch error.OutOfMemory,
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}) catch error.OutOfMemory,
        .map, .list => blk: {
            const s = try builtins.builtinJsonEncode(a, &.{v});
            break :blk s.string;
        },
        else => builtins.failArg("pg_start: parameter ${d} is a {s}; a query parameter is nil, a Bool, String, Int, Float, Map or List", .{ i + 1, @tagName(v.*) }),
    };
}

fn dupeOom(a: std.mem.Allocator, s: []const u8) EvalError![]const u8 {
    return a.dupe(u8, s) catch error.OutOfMemory;
}

pub fn pgStart(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3 and args.len != 4) return builtins.failArg("pg_start(conn, sql, params) or pg_start(conn, sql, params, %{{timeout_ms: Int}})", .{});
    if (args[1].* != .string) return builtins.failArg("pg_start: the SQL must be a String", .{});
    if (std.mem.indexOfScalar(u8, args[1].string, 0) != null) return builtins.failArg("pg_start: the SQL has a NUL in it", .{});
    if (args[2].* != .list) return builtins.failArg("pg_start: the parameters must be a List", .{});
    if (args[2].list.len > 65535) return builtins.failArg("pg_start: {d} parameters; Postgres takes at most 65535", .{args[2].list.len});
    var timeout_ms = timeout_default_ms;
    if (args.len == 4) {
        const opts: []const Value.MapEntry = switch (args[3].*) {
            .map => |m| m,
            .nil => &.{},
            else => return builtins.failArg("pg_start: options must be a Map", .{}),
        };
        for (opts) |e| {
            if (!std.mem.eql(u8, e.key, "timeout_ms")) return builtins.failArg("pg_start: unknown option `{s}`; it takes timeout_ms", .{e.key});
            if (e.val.* != .integer or e.val.integer < 1 or e.val.integer > timeout_max_ms)
                return builtins.failArg("pg_start: timeout_ms must be an Int in 1..{d}", .{timeout_max_ms});
            timeout_ms = e.val.integer;
        }
    }

    // A slot, and room under the thread cap, before anything is allocated:
    // the -1 answer then has nothing to free. A worker whose query timed out
    // keeps running (it cancels on the server, then closes) after pg_result
    // has given its slot back, so in_flight, not the slots, bounds threads;
    // without this a program reissuing timed-out queries piled up detached
    // workers and sockets with no limit.
    var free_i: ?usize = null;
    for (&slots, 0..) |*slot, i| {
        if (slot.job == null) {
            free_i = i;
            break;
        }
    }
    // Every slot busy, or slots_max workers still alive: -1, as http_start
    // answers, and pg_result(-1) raises.
    const slot_i = free_i orelse return box(allocator, .{ .integer = -1 });
    if (in_flight.load(.monotonic) >= slots_max) return box(allocator, .{ .integer = -1 });

    const job = pa.create(Job) catch return error.OutOfMemory;
    job.* = .{ .arena = .init(pa) };
    // The only free of a job that never reached a worker. No path below
    // frees it by hand: an error return runs this, and a second free was a
    // double deinit of the arena.
    errdefer freeJob(job);
    // the worker owns copies: the interpreter's heap is compacted under it
    const a = job.arena.allocator();
    const info: ConnInfo = switch (args[0].*) {
        .map => |m| try connFromMap(m),
        .string => |url| (parseUrl(a, url) catch return error.OutOfMemory) orelse
            return builtins.failArg("pg_start: not a postgres://user:password@host:port/database URL", .{}),
        else => return builtins.failArg("pg_start: the connection is a Map or a postgres:// URL", .{}),
    };
    job.info = info.dupe(a) catch return error.OutOfMemory;
    job.sql = try dupeOom(a, args[1].string);
    const params = a.alloc(?[]const u8, args[2].list.len) catch return error.OutOfMemory;
    for (args[2].list, 0..) |p, i| params[i] = try paramText(a, p, i);
    job.params = params;

    job.deadline = monoMs() + timeout_ms;
    _ = in_flight.fetchAdd(1, .monotonic);
    const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        _ = in_flight.fetchSub(1, .monotonic);
        return error.NotSupported; // the errdefer frees the job
    };
    thread.detach();
    slots[slot_i] = .{ .job = job, .deadline = job.deadline };
    return box(allocator, .{ .integer = @intCast(slot_i) });
}

fn decodeCell(allocator: std.mem.Allocator, oid: i32, text: []const u8) EvalError!union(enum) { ok: *const Value, bad: []const u8 } {
    switch (oid) {
        16 => return .{ .ok = try box(allocator, .{ .boolean = std.mem.eql(u8, text, "t") }) },
        20, 21, 23, 26 => {
            const n = std.fmt.parseInt(i64, text, 10) catch
                return .{ .bad = std.fmt.allocPrint(allocator, "Postgres sent an integer column that does not parse: {s}", .{text}) catch return error.OutOfMemory };
            return .{ .ok = try box(allocator, .{ .integer = n }) };
        },
        114, 3802 => {
            const s = try box(allocator, .{ .string = text });
            const r = try builtins.builtinJsonDecode(allocator, &.{s});
            if (std.mem.eql(u8, r.tuple[0].atom, "ok")) return .{ .ok = r.tuple[1] };
            return .{ .bad = std.fmt.allocPrint(allocator, "Postgres sent JSON that json_decode refuses: {s}", .{r.tuple[1].string}) catch return error.OutOfMemory };
        },
        // a copy: the job's rows are freed as soon as pg_result returns
        else => return .{ .ok = try box(allocator, .{ .string = try dupeOom(allocator, text) }) },
    }
}

/// The finished job's rows as Blimp values: a list of maps, column name to
/// value. A repeated column name keeps its first position and the last
/// value, as `put` in the Blimp client did.
fn rowsValue(allocator: std.mem.Allocator, job: *Job) EvalError!*const Value {
    const cols = job.columns;
    const place = allocator.alloc(usize, cols.len) catch return error.OutOfMemory;
    var names: std.ArrayList([]const u8) = .empty;
    for (cols, 0..) |c, j| {
        var at: ?usize = null;
        for (names.items, 0..) |n, k| if (std.mem.eql(u8, n, c.name)) {
            at = k;
            break;
        };
        place[j] = at orelse blk: {
            names.append(allocator, try dupeOom(allocator, c.name)) catch return error.OutOfMemory;
            break :blk names.items.len - 1;
        };
    }
    const nil_v = try box(allocator, .nil);
    const list = allocator.alloc(*const Value, job.rows.items.len) catch return error.OutOfMemory;
    for (job.rows.items, 0..) |row, r| {
        const entries = allocator.alloc(Value.MapEntry, names.items.len) catch return error.OutOfMemory;
        for (row, 0..) |cell, j| {
            const v = if (cell) |text| switch (try decodeCell(allocator, cols[j].oid, text)) {
                .ok => |v| v,
                .bad => |why| return pair(allocator, "error", try box(allocator, .{ .string = why })),
            } else nil_v;
            entries[place[j]] = .{ .key = names.items[place[j]], .val = v };
        }
        list[r] = try box(allocator, .{ .map = entries });
    }
    return pair(allocator, "ok", try box(allocator, .{ .list = list }));
}

pub fn pgResult(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return builtins.failArg("pg_result(handle) takes the Int pg_start gave", .{});
    const h = args[0].integer;
    if (h < 0 or h >= slots_max) return builtins.failArg("pg_result: {d} is not a handle (pg_start answers -1 when {d} queries are already in flight)", .{ h, slots_max });
    const slot = &slots[@intCast(h)];
    const job = slot.job orelse return builtins.failArg("pg_result: no query is in flight on handle {d}", .{h});
    if (job.state.load(.acquire) == 1) {
        if (monoMs() < slot.deadline) return box(allocator, .nil);
        // Past the deadline and the worker has not finished: stop waiting.
        // If the worker finishes in between, the exchange fails and its
        // answer is the one given.
        if (job.state.cmpxchgStrong(1, 4, .acq_rel, .acquire) == null) {
            slot.* = .{};
            return pair(allocator, "error", try box(allocator, .{ .string = "timeout" }));
        }
    }
    defer {
        freeJob(job);
        slot.* = .{};
    }
    if (job.state.load(.acquire) == 2) return rowsValue(allocator, job);
    return pair(allocator, "error", try box(allocator, .{ .string = try dupeOom(allocator, job.why.text()) }));
}

pub fn pgStats(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return builtins.failArg("pg_stats() takes nothing", .{});
    const entries = allocator.alloc(Value.MapEntry, 2) catch return error.OutOfMemory;
    entries[0] = .{ .key = "in_flight", .val = try box(allocator, .{ .integer = in_flight.load(.monotonic) }) };
    entries[1] = .{ .key = "idle", .val = try box(allocator, .{ .integer = @intCast(idleCount()) }) };
    return box(allocator, .{ .map = entries });
}

// ============================================================
// tests
// ============================================================
//
// The fixtures below are bytes a real Postgres 16.14 sent, recorded through
// a logging proxy (trust login as `postgres`, then the two queries the
// replay test makes). The live tests run only when BLIMP_PG_TEST_URL names
// a server with a SCRAM user (and BLIMP_PG_MD5_URL an md5 one); otherwise
// they are skipped, and the replay tests are what runs.

const testing = std.testing;

test "scramAnswer: RFC 7677's worked example" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var why: Reason = .{};
    const ans = try scramAnswer(
        arena.allocator(),
        "pencil",
        "n=user,r=rOprNGfwEbeRWgbNEkqO",
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        &why,
    );
    try testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", ans.client_final);
    try testing.expectEqualStrings("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", ans.server_final);
}

test "md5Password: what Postgres stores, salted (checked against pg_authid and Python's hashlib)" {
    const got = md5Password("md5_user", "md5pw", .{ 1, 2, 3, 4 });
    try testing.expectEqualStrings("md5d1ae3db884e6b549abb7c9949015ca62", &got);
}

test "parseUrl: the readings pg_parse_url makes, and the refusals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = (try parseUrl(a, "ecto://blog:p%40ss%3Aw+rd@db:6543/blog_prod?pool=10")).?;
    try testing.expectEqualStrings("blog", u.user);
    try testing.expectEqualStrings("p@ss:w+rd", u.password);
    try testing.expectEqualStrings("db", u.host);
    try testing.expectEqual(@as(u16, 6543), u.port);
    try testing.expectEqualStrings("blog_prod", u.database);
    const d = (try parseUrl(a, "postgres://u:x@y@h/db")).?;
    try testing.expectEqualStrings("x@y", d.password);
    try testing.expectEqual(@as(u16, 5432), d.port);
    try testing.expect((try parseUrl(a, "postgres://h/db")) == null);
    try testing.expect((try parseUrl(a, "postgres://u:p@h")) == null);
    try testing.expect((try parseUrl(a, "postgres://u:p@h:99999/db")) == null);
    try testing.expect((try parseUrl(a, "postgres://u:%zz@h/db")) == null);
    try testing.expect((try parseUrl(a, "nonsense")) == null);
}

test "writeQuery: Parse, Bind with a NULL, Describe, Execute, Sync" {
    var o: Out = .{ .a = testing.allocator };
    defer o.buf.deinit(testing.allocator);
    try writeQuery(&o, "select $1", &.{ "x", null });
    const want = "P\x00\x00\x00\x11\x00select $1\x00\x00\x00" ++
        "B\x00\x00\x00\x15\x00\x00\x00\x00\x00\x02\x00\x00\x00\x01x\xff\xff\xff\xff\x00\x00" ++
        "D\x00\x00\x00\x06P\x00" ++
        "E\x00\x00\x00\x09\x00\x00\x00\x00\x00" ++
        "S\x00\x00\x00\x04";
    try testing.expectEqualSlices(u8, want, o.buf.items);
}
const rec_login_hex =
    \\5200000008000000005300000017696e5f686f745f7374616e646279006f6666005300000019696e74656765725f64617465
    \\74696d6573006f6e00530000001e54696d655a6f6e6500416d65726963612f4e65775f596f726b00530000001b496e746572
    \\76616c5374796c6500706f73746772657300530000001469735f737570657275736572006f6e0053000000166170706c6963
    \\6174696f6e5f6e616d650000530000002664656661756c745f7472616e73616374696f6e5f726561645f6f6e6c79006f6666
    \\00530000001a736372616d5f697465726174696f6e730034303936005300000017446174655374796c650049534f2c204d44
    \\590053000000237374616e646172645f636f6e666f726d696e675f737472696e6773006f6e00530000002373657373696f6e
    \\5f617574686f72697a6174696f6e00706f737467726573005300000019636c69656e745f656e636f64696e67005554463800
    \\53000000247365727665725f76657273696f6e0031362e31342028486f6d6562726577290053000000197365727665725f65
    \\6e636f64696e670055544638004b0000000c0001567d0ef32b375a0000000549
;
const rec_rows_hex =
    \\3100000004320000000454000000610004696400000040120001000000170004ffffffff00006d6574610000004012000500
    \\000edaffffffffffff00006e6f7468696e670000000000000000000019ffffffffffff00006f6b0000004012000700000010
    \\0001ffffffff00004400000034000400000001310000001c7b2267223a20312c202274616773223a205b2261222c20226222
    \\5d7dffffffff00000001664400000034000400000001320000001c7b2267223a20322c202274616773223a205b2261222c20
    \\2262225d7dffffffff0000000174430000000d53454c4543542032005a0000000549
;
const rec_error_hex =
    \\4500000067534552524f5200564552524f5200433432503031004d72656c6174696f6e20226e6f70652220646f6573206e6f
    \\7420657869737400503135004670617273655f72656c6174696f6e2e63004c3134353200527061727365724f70656e546162
    \\6c6500005a0000000549
;

/// A fixture's hex, line breaks and all, as bytes.
fn unhex(a: std.mem.Allocator, hex: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '\n') {
            i += 1;
            continue;
        }
        try out.append(a, try std.fmt.parseInt(u8, hex[i .. i + 2], 16));
        i += 2;
    }
    return out.toOwnedSlice(a);
}

test "the recorded RowDescription, DataRows and ErrorResponse parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Reader = .{};
    try r.buf.appendSlice(pa, try unhex(a, rec_rows_hex));
    try r.buf.appendSlice(pa, try unhex(a, rec_error_hex));
    defer r.deinit();
    var why: Reason = .{};
    var types: std.ArrayList(u8) = .empty;
    var cols: []Column = &.{};
    var rows: usize = 0;
    while (try r.take(&why)) |m| {
        try types.append(a, m.t);
        switch (m.t) {
            'T' => cols = try parseColumns(a, m.body, &why),
            'D' => {
                const cells = try parseRow(a, m.body, cols.len, &why);
                rows += 1;
                try testing.expect(cells[2] == null);
                try testing.expectEqualStrings(if (rows == 1) "f" else "t", cells[3].?);
            },
            'E' => {
                writeErrorText(m.body, &why);
                try testing.expectEqualStrings("ERROR 42P01: relation \"nope\" does not exist", why.text());
            },
            else => {},
        }
    }
    // a Parse that fails sends no ParseComplete: E then Z
    try testing.expectEqualStrings("12TDDCZEZ", types.items);
    try testing.expectEqual(@as(usize, 4), cols.len);
    try testing.expectEqualStrings("meta", cols[1].name);
    try testing.expectEqual(@as(i32, 3802), cols[1].oid);
    try testing.expectEqual(@as(i32, 23), cols[0].oid);
    try testing.expectEqual(@as(i32, 16), cols[3].oid);
}

test "a DataRow that disagrees with its RowDescription, or runs past its end, is an error, not a panic" {
    var why: Reason = .{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Failed, parseRow(arena.allocator(), "\x00\x02\x00\x00\x00\x01x", 1, &why));
    try testing.expectError(error.Failed, parseRow(arena.allocator(), "\x00\x01\x00\x00\x00\x09x", 1, &why));
    try testing.expectError(error.Failed, parseColumns(arena.allocator(), "\x00\x01id\x00\x00", &why));
}

// -- a fake server that replays the recording --------------------------

const FakeServer = struct {
    fd: c_int,
    port: u16,
    /// what to send after each batch the client sends; empty = never answer
    replies: []const []const u8,
    /// the client's bytes, kept for the md5 test to look at
    got: [4096]u8 = undefined,
    got_len: usize = 0,
    closed: std.atomic.Value(u8) = .init(0),

    fn listen(replies: []const []const u8) !*FakeServer {
        const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return error.NoSocket;
        var addr = std.mem.zeroes(std.posix.sockaddr.in);
        addr.family = std.posix.AF.INET;
        addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) != 0) return error.NoBind;
        if (std.c.listen(fd, 4) != 0) return error.NoListen;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        _ = std.c.getsockname(fd, @ptrCast(&addr), &len);
        const s = try testing.allocator.create(FakeServer);
        s.* = .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port), .replies = replies };
        const t = try std.Thread.spawn(.{}, serve, .{s});
        t.detach();
        return s;
    }

    fn done(s: *FakeServer) void {
        var tries: usize = 0;
        while (s.closed.load(.acquire) == 0 and tries < 1000) : (tries += 1) napMs(5);
        _ = std.c.close(s.fd);
        testing.allocator.destroy(s);
    }

    /// Read until the client's batch is complete: the startup message by
    /// its length, anything else up to a Sync or a PasswordMessage.
    fn readBatch(s: *FakeServer, c: c_int, first: bool) bool {
        const start = s.got_len;
        while (true) {
            const have = s.got[start..s.got_len];
            if (first and have.len >= 4 and have.len >= std.mem.readInt(u32, have[0..4], .big)) return true;
            if (!first and have.len >= 5 and std.mem.endsWith(u8, have, "S\x00\x00\x00\x04")) return true;
            if (!first and have.len >= 5 and have[0] == 'p' and have.len >= 1 + std.mem.readInt(u32, have[1..5], .big)) return true;
            const n = std.c.read(c, s.got[s.got_len..].ptr, s.got.len - s.got_len);
            if (n <= 0) return false;
            s.got_len += @intCast(n);
        }
    }

    fn serve(s: *FakeServer) void {
        defer s.closed.store(1, .release);
        var addr: std.posix.sockaddr = undefined;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        const c = std.c.accept(s.fd, &addr, &len);
        if (c < 0) return;
        defer _ = std.c.close(c);
        for (s.replies, 0..) |reply, i| {
            if (!s.readBatch(c, i == 0)) return;
            if (reply.len == 0) {
                // never answer: wait for the client to give up and close
                var b: [64]u8 = undefined;
                while (std.c.read(c, &b, b.len) > 0) {}
                return;
            }
            _ = std.c.write(c, reply.ptr, reply.len);
        }
        var b: [64]u8 = undefined;
        while (std.c.read(c, &b, b.len) > 0) {}
    }
};

fn napMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

fn testConn(a: std.mem.Allocator, port: u16, user: []const u8, password: []const u8) !*const Value {
    const entries = try a.alloc(Value.MapEntry, 5);
    entries[0] = .{ .key = "host", .val = try box(a, .{ .string = "127.0.0.1" }) };
    entries[1] = .{ .key = "port", .val = try box(a, .{ .integer = port }) };
    entries[2] = .{ .key = "user", .val = try box(a, .{ .string = user }) };
    entries[3] = .{ .key = "password", .val = try box(a, .{ .string = password }) };
    entries[4] = .{ .key = "database", .val = try box(a, .{ .string = "blog" }) };
    return box(a, .{ .map = entries });
}

/// pg_start then pg_result until it answers.
fn testQuery(a: std.mem.Allocator, conn: *const Value, sql: []const u8, params: []const *const Value, timeout_ms: ?i64) !*const Value {
    var args: [4]*const Value = .{ conn, try box(a, .{ .string = sql }), try box(a, .{ .list = params }), undefined };
    if (timeout_ms) |t| {
        const e = try a.alloc(Value.MapEntry, 1);
        e[0] = .{ .key = "timeout_ms", .val = try box(a, .{ .integer = t }) };
        args[3] = try box(a, .{ .map = e });
    }
    const h = try pgStart(a, args[0..if (timeout_ms == null) 3 else 4]);
    try testing.expect(h.integer >= 0);
    var tries: usize = 0;
    while (tries < 20_000) : (tries += 1) {
        const r = try pgResult(a, &.{h});
        if (r.* != .nil) return r;
        napMs(1);
    }
    return error.NeverAnswered;
}

fn expectSlotsFree() !void {
    for (slots) |s| try testing.expect(s.job == null);
}

test "pg_start: the recorded login and replies become the rows and the error the Blimp client made" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    drainPool();
    const srv = try FakeServer.listen(&.{ try unhex(a, rec_login_hex), try unhex(a, rec_rows_hex), try unhex(a, rec_error_hex) });
    defer srv.done();
    const conn = try testConn(a, srv.port, "postgres", "");
    const r = try testQuery(a, conn, "select id, meta, null::text as nothing, ok from museum where id <= $1 order by id", &.{try box(a, .{ .integer = 2 })}, null);
    try testing.expectEqualStrings("ok", r.tuple[0].atom);
    const rows = r.tuple[1].list;
    try testing.expectEqual(@as(usize, 2), rows.len);
    const row = rows[1].map;
    try testing.expectEqualStrings("id", row[0].key);
    try testing.expectEqual(@as(i64, 2), row[0].val.integer);
    try testing.expectEqualStrings("meta", row[1].key);
    try testing.expectEqualStrings("g", row[1].val.map[0].key);
    try testing.expectEqual(@as(i64, 2), row[1].val.map[0].val.integer);
    try testing.expect(row[2].val.* == .nil);
    try testing.expect(row[3].val.boolean);
    try testing.expect(!rows[0].map[3].val.boolean);
    // the connection went back to the pool, and the next query used it
    const e = try testQuery(a, conn, "select * from nope", &.{}, null);
    try testing.expectEqualStrings("error", e.tuple[0].atom);
    try testing.expectEqualStrings("ERROR 42P01: relation \"nope\" does not exist", e.tuple[1].string);
    try expectSlotsFree();
    drainPool();
}

test "pg_start: a server that never answers is {:error, \"timeout\"} at the deadline, and the slot comes back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    drainPool();
    const srv = try FakeServer.listen(&.{""});
    defer srv.done();
    const t0 = monoMs();
    const r = try testQuery(a, try testConn(a, srv.port, "postgres", ""), "select 1", &.{}, 200);
    const took = monoMs() - t0;
    try testing.expectEqualStrings("timeout", r.tuple[1].string);
    try testing.expect(took >= 190 and took < 1000);
    try expectSlotsFree();
}

test "pg_start: md5 login sends md5(md5(password ++ user) ++ salt)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    drainPool();
    // AuthenticationMD5Password with salt 01020304, then the recorded rest
    const ask = "R\x00\x00\x00\x0c\x00\x00\x00\x05\x01\x02\x03\x04";
    const srv = try FakeServer.listen(&.{ ask, try unhex(a, rec_login_hex), try unhex(a, rec_error_hex) });
    defer srv.done();
    const r = try testQuery(a, try testConn(a, srv.port, "md5_user", "md5pw"), "select * from nope", &.{}, null);
    try testing.expectEqualStrings("ERROR 42P01: relation \"nope\" does not exist", r.tuple[1].string);
    const got = srv.got[0..srv.got_len];
    try testing.expect(std.mem.indexOf(u8, got, "p\x00\x00\x00\x28md5d1ae3db884e6b549abb7c9949015ca62\x00") != null);
    drainPool();
}

test "pg_start refuses what it cannot send" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conn = try testConn(a, 5432, "u", "p");
    const sql = try box(a, .{ .string = "select $1" });
    const bad_param = try box(a, .{ .list = &.{try box(a, .{ .atom = "nope" })} });
    try testing.expectError(error.TypeError, pgStart(a, &.{ conn, sql, bad_param }));
    const opts = try a.alloc(Value.MapEntry, 1);
    opts[0] = .{ .key = "timeout", .val = try box(a, .{ .integer = 5 }) };
    try testing.expectError(error.TypeError, pgStart(a, &.{ conn, sql, try box(a, .{ .list = &.{} }), try box(a, .{ .map = opts }) }));
    try testing.expectError(error.TypeError, pgStart(a, &.{ try box(a, .{ .string = "not a url" }), sql, try box(a, .{ .list = &.{} }) }));
    try testing.expectError(error.TypeError, pgResult(a, &.{try box(a, .{ .integer = -1 })}));
    try testing.expectError(error.TypeError, pgResult(a, &.{try box(a, .{ .integer = 3 })}));
    try expectSlotsFree();
}

// -- against a real server, when there is one ---------------------------

fn liveUrl(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

test "live: SCRAM login, types, a server error, and a timeout that cancels the statement" {
    const url = liveUrl("BLIMP_PG_TEST_URL") orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // the SCRAM nonce comes from the runtime's Io, which only main installs
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;
    const a = arena.allocator();
    drainPool();
    const conn = try box(a, .{ .string = url });
    const r = try testQuery(a, conn, "select $1::int8 as n, $2::text as s, null::int4 as z, true as b, $3::jsonb as j, 1.5::numeric as num", &.{
        try box(a, .{ .integer = -42 }),
        try box(a, .{ .string = "héllo" }),
        try box(a, .{ .list = &.{ try box(a, .{ .integer = 1 }), try box(a, .nil) } }),
    }, null);
    if (r.tuple[1].* == .string) std.debug.print("live query failed: {s}\n", .{r.tuple[1].string});
    try testing.expectEqualStrings("ok", r.tuple[0].atom);
    const row = r.tuple[1].list[0].map;
    try testing.expectEqual(@as(i64, -42), row[0].val.integer);
    try testing.expectEqualStrings("héllo", row[1].val.string);
    try testing.expect(row[2].val.* == .nil);
    try testing.expect(row[3].val.boolean);
    try testing.expectEqual(@as(usize, 2), row[4].val.list.len);
    try testing.expectEqualStrings("1.5", row[5].val.string);

    const e = try testQuery(a, conn, "selec 1", &.{}, null);
    try testing.expectEqualStrings("ERROR 42601: syntax error at or near \"selec\"", e.tuple[1].string);

    const t = try testQuery(a, conn, "select pg_sleep(30), 'pg-zig-live-cancel' as tag", &.{}, 300);
    try testing.expectEqualStrings("timeout", t.tuple[1].string);
    napMs(300);
    const left = try testQuery(a, conn, "select count(*)::int4 as n from pg_stat_activity where state = 'active' and query like '%pg-zig-live-cancel%' and pid <> pg_backend_pid()", &.{}, null);
    try testing.expectEqual(@as(i64, 0), left.tuple[1].list[0].map[0].val.integer);
    try expectSlotsFree();
    drainPool();
}

test "live: a connection left inside a transaction, failed or not, is closed, not pooled" {
    const url = liveUrl("BLIMP_PG_TEST_URL") orelse return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    drainPool();
    const conn = try box(a, .{ .string = url });
    // 'T': a BEGIN with no COMMIT leaves the block open
    const b = try testQuery(a, conn, "begin", &.{}, null);
    try testing.expectEqualStrings("ok", b.tuple[0].atom);
    try testing.expectEqual(@as(usize, 0), idleCount());
    // a later, unrelated query is not inside it: no transaction id was
    // assigned before this statement on its connection
    const t = try testQuery(a, conn, "select pg_current_xact_id_if_assigned() is null as fresh", &.{}, null);
    try testing.expectEqualStrings("ok", t.tuple[0].atom);
    try testing.expect(t.tuple[1].list[0].map[0].val.boolean);
    try testing.expectEqual(@as(usize, 1), idleCount());
    drainPool();
    // 'E': a failed statement inside a block used to make every later query
    // on the pooled connection ERROR 25P02
    _ = try testQuery(a, conn, "begin", &.{}, null);
    _ = try testQuery(a, conn, "select 1/0", &.{}, null);
    const after = try testQuery(a, conn, "select 2 as two", &.{}, null);
    try testing.expectEqualStrings("ok", after.tuple[0].atom);
    try testing.expectEqual(@as(i64, 2), after.tuple[1].list[0].map[0].val.integer);
    try expectSlotsFree();
    drainPool();
}

test "live: md5 login" {
    const url = liveUrl("BLIMP_PG_MD5_URL") orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try testQuery(a, try box(a, .{ .string = url }), "select 7 as seven", &.{}, null);
    try testing.expectEqual(@as(i64, 7), r.tuple[1].list[0].map[0].val.integer);
    drainPool();
}

fn maxRssBytes() i64 {
    var ru: std.c.rusage = undefined;
    _ = std.c.getrusage(std.c.rusage.SELF, &ru);
    // bytes on macOS, KiB on Linux
    return if (builtin.os.tag.isDarwin()) ru.maxrss else ru.maxrss * 1024;
}

test "live: 5000 queries through the pool and back hold no memory of their own" {
    const url = liveUrl("BLIMP_PG_TEST_URL") orelse return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;
    drainPool();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var warm: i64 = 0;
    var i: usize = 0;
    while (i < 5500) : (i += 1) {
        if (i == 500) warm = maxRssBytes();
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const r = try testQuery(a, try box(a, .{ .string = url }), "select generate_series(1, 20) as n, repeat('x', 200) as s", &.{}, null);
        try testing.expectEqual(@as(usize, 20), r.tuple[1].list.len);
    }
    const grew = maxRssBytes() - warm;
    try testing.expect(grew < 4 * 1024 * 1024);
    try expectSlotsFree();
    drainPool();
}

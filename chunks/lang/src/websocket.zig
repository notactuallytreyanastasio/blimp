//! A WebSocket client that lives on its own thread.
//!
//!     ws = ws_open("wss://jetstream2.us-east.bsky.network/subscribe", %{})
//!     ws_recv(ws)   # [] | ["{...}", {:binary, bytes}, ...] | {:closed, reason}
//!     ws_send(ws, "text")
//!     ws_stats(ws)  # %{received:, dropped:, bytes:, queued:, state:}
//!     ws_close(ws)
//!
//! The program that uses this is a web server answering every request from
//! one thread, polling from its tick. So the connection is a worker thread
//! that owns the socket outright -- it alone reads and it alone writes -- and
//! the program only ever touches a queue under a lock.
//!
//! Why the worker alone writes: `std.crypto.tls.Client` rotates the *write*
//! keys from its *read* path when the server sends a KeyUpdate asking for
//! one. A `ws_send` that wrote from the interpreter thread while the worker
//! sat in a read would race that. So a send is queued, and the worker polls
//! the socket with a short timeout instead of blocking in a read, and writes
//! what is queued between frames.
//!
//! Why the queue drops: the firehose does not wait for anyone. A program
//! that polls slowly, or stops polling, would otherwise hold every frame the
//! server sent since. Past `frames_max` frames or `bytes_max` bytes the
//! oldest frame goes, and `dropped` says how many have.
//!
//! The TLS is Zig's own (`std.http.Client.connect` for the socket, the CA
//! bundle and the handshake). Zig 0.16's std has WebSocket framing only on
//! the server side (`std.http.Server.Request.respondWebSocket`); the client
//! has nothing for an Upgrade, and a `Request` treats what follows the head
//! as an HTTP body. But `Client.connect` hands back a `Connection` whose
//! `reader()` and `writer()` are the decrypted stream, and the Upgrade is a
//! few lines of HTTP, so it is written here by hand on that stream.

const std = @import("std");
const ioenv = @import("ioenv.zig");

pub const slots_max = 8;
pub const frames_max_default = 8192;
pub const bytes_max_default = 16 * 1024 * 1024;
/// One message, after its fragments are joined. Bigger closes with 1009.
pub const message_max = 8 * 1024 * 1024;
/// What `ws_send` may have queued and not yet written.
pub const outbox_max = 8 * 1024 * 1024;
/// How long the worker waits on the socket before it looks at the outbox.
const poll_ms = 20;

pub const State = enum(u8) { free, connecting, open, closed, abandoned };

pub const Frame = struct {
    data: []u8,
    binary: bool,
};

pub const Header = struct { name: []const u8, value: []const u8 };

const SpinLock = struct {
    v: std.atomic.Value(bool) = .init(false),
    fn lock(s: *SpinLock) void {
        while (s.v.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(s: *SpinLock) void {
        s.v.store(false, .release);
    }
};

const Slot = struct {
    lock: SpinLock = .{},
    // Everything below is guarded by `lock`.
    state: State = .free,
    gen: i64 = 0,
    url: []u8 = &.{},
    header_block: []u8 = &.{},
    ring: []Frame = &.{},
    head: usize = 0,
    count: usize = 0,
    queued_bytes: usize = 0,
    bytes_max: usize = bytes_max_default,
    outbox: std.ArrayList([]u8) = .empty,
    outbox_bytes: usize = 0,
    received: u64 = 0,
    dropped: u64 = 0,
    bytes: u64 = 0,
    reason_buf: [200]u8 = undefined,
    reason_len: usize = 0,

    fn reason(s: *const Slot) []const u8 {
        return s.reason_buf[0..s.reason_len];
    }

    fn setReason(s: *Slot, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&s.reason_buf, fmt, args) catch s.reason_buf[0..];
        s.reason_len = out.len;
    }

    /// Frees what the slot holds and marks it free. Caller holds the lock.
    fn release(s: *Slot) void {
        const a = gpa;
        if (s.url.len > 0) a.free(s.url);
        if (s.header_block.len > 0) a.free(s.header_block);
        var i: usize = 0;
        while (i < s.count) : (i += 1) a.free(s.ring[(s.head + i) % s.ring.len].data);
        if (s.ring.len > 0) a.free(s.ring);
        for (s.outbox.items) |m| a.free(m);
        s.outbox.deinit(a);
        const gen = s.gen;
        const lock = s.lock;
        s.* = .{ .gen = gen, .lock = lock };
    }
};

var slots: [slots_max]Slot = [_]Slot{.{}} ** slots_max;

/// The worker's allocator, and the one every slot buffer comes from. Not the
/// interpreter's: that heap is compacted under a running worker.
const gpa = std.heap.smp_allocator;

pub const Error = error{ BadUrl, BadHandle, NoFreeSlot, OutOfMemory, ThreadSpawn };

// ── The program's side ───────────────────────────────────────────────────

/// A handle is `gen * slots_max + index`, so a handle whose connection has
/// been freed and whose slot now holds another is refused, not aliased.
fn slotFor(handle: i64) Error!*Slot {
    if (handle < slots_max) return error.BadHandle;
    const s = &slots[@intCast(@mod(handle, slots_max))];
    s.lock.lock();
    if (s.gen != @divFloor(handle, slots_max) or s.state == .free or s.state == .abandoned) {
        s.lock.unlock();
        return error.BadHandle;
    }
    return s; // locked
}

pub fn open(url: []const u8, headers: []const Header) Error!i64 {
    return openWith(url, headers, frames_max_default, bytes_max_default);
}

pub fn openWith(url: []const u8, headers: []const Header, frames_max: usize, bytes_max: usize) Error!i64 {
    _ = try parseUrl(url);
    for (headers) |h| {
        if (h.name.len == 0 or std.mem.indexOfAny(u8, h.name, ":\r\n") != null or
            std.mem.indexOfAny(u8, h.value, "\r\n") != null) return error.BadUrl;
    }
    for (&slots) |*s| {
        s.lock.lock();
        if (s.state != .free) {
            s.lock.unlock();
            continue;
        }
        defer s.lock.unlock();
        var block: std.ArrayList(u8) = .empty;
        errdefer block.deinit(gpa);
        for (headers) |h| {
            try block.appendSlice(gpa, h.name);
            try block.appendSlice(gpa, ": ");
            try block.appendSlice(gpa, h.value);
            try block.appendSlice(gpa, "\r\n");
        }
        const url_copy = try gpa.dupe(u8, url);
        errdefer gpa.free(url_copy);
        const ring = try gpa.alloc(Frame, frames_max);
        errdefer gpa.free(ring);
        const header_block = try block.toOwnedSlice(gpa);
        s.gen += 1;
        s.state = .connecting;
        s.url = url_copy;
        s.header_block = header_block;
        s.ring = ring;
        s.bytes_max = bytes_max;
        const thread = std.Thread.spawn(.{}, worker, .{s}) catch {
            s.release();
            return error.ThreadSpawn;
        };
        thread.detach();
        const index: i64 = @intCast((@intFromPtr(s) - @intFromPtr(&slots[0])) / @sizeOf(Slot));
        return s.gen * slots_max + index;
    }
    return error.NoFreeSlot;
}

pub const Received = union(enum) {
    /// Owned by the caller: free with `freeFrames`.
    frames: []Frame,
    /// The connection is gone and the handle is free. The slice is only good
    /// until the next `open`; copy it.
    closed: []const u8,
};

/// Everything queued since the last call. Once the connection is gone and
/// the queue is empty, the reason, once, and the handle is freed.
pub fn recv(handle: i64) Error!Received {
    const s = try slotFor(handle);
    defer s.lock.unlock();
    if (s.count == 0 and s.state == .closed) {
        const reason_copy = closed_reason_buf[0..s.reason_len];
        @memcpy(reason_copy, s.reason());
        s.release();
        return .{ .closed = reason_copy };
    }
    const out = try gpa.alloc(Frame, s.count);
    for (out, 0..) |*f, i| f.* = s.ring[(s.head + i) % s.ring.len];
    s.head = 0;
    s.count = 0;
    s.queued_bytes = 0;
    return .{ .frames = out };
}

var closed_reason_buf: [200]u8 = undefined;

pub fn freeFrames(frames: []Frame) void {
    for (frames) |f| gpa.free(f.data);
    gpa.free(frames);
}

pub const SendResult = enum { ok, closed, full };

pub fn send(handle: i64, text: []const u8) Error!SendResult {
    const s = try slotFor(handle);
    defer s.lock.unlock();
    if (s.state == .closed) return .closed;
    if (s.outbox_bytes + text.len > outbox_max) return .full;
    const copy = try gpa.dupe(u8, text);
    errdefer gpa.free(copy);
    try s.outbox.append(gpa, copy);
    s.outbox_bytes += text.len;
    return .ok;
}

/// The handle is dead after this, whatever state the connection is in. An
/// open connection is sent a close frame (1000) by its worker, which then
/// frees the slot; it does not wait for the server's answering close.
pub fn close(handle: i64) Error!void {
    const s = try slotFor(handle);
    defer s.lock.unlock();
    if (s.state == .closed) {
        s.release();
    } else {
        s.state = .abandoned;
    }
}

pub const Stats = struct {
    received: u64,
    dropped: u64,
    bytes: u64,
    queued: usize,
    state: State,
};

pub fn stats(handle: i64) Error!Stats {
    const s = try slotFor(handle);
    defer s.lock.unlock();
    return .{ .received = s.received, .dropped = s.dropped, .bytes = s.bytes, .queued = s.count, .state = s.state };
}

// ── The worker's side ────────────────────────────────────────────────────

const Url = struct {
    tls: bool,
    host: []const u8,
    port: u16,
    /// "host" or "host:port", as the Host header wants it
    authority: []const u8,
    /// path and query, "/" at least
    target: []const u8,
};

pub fn parseUrl(url: []const u8) Error!Url {
    var rest: []const u8 = undefined;
    var tls = false;
    if (std.mem.startsWith(u8, url, "wss://")) {
        tls = true;
        rest = url["wss://".len..];
    } else if (std.mem.startsWith(u8, url, "ws://")) {
        rest = url["ws://".len..];
    } else return error.BadUrl;
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| rest = rest[0..i];
    const auth_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..auth_end];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "@[] \r\n") != null) return error.BadUrl;
    var host = authority;
    var port: u16 = if (tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return error.BadUrl;
        if (host.len == 0) return error.BadUrl;
    }
    const target = if (auth_end == rest.len) "/" else rest[auth_end..];
    if (std.mem.indexOfAny(u8, target, " \r\n") != null) return error.BadUrl;
    return .{ .tls = tls, .host = host, .port = port, .authority = authority, .target = target };
}

fn worker(s: *Slot) void {
    run(s) catch |err| {
        s.lock.lock();
        if (s.reason_len == 0) s.setReason("{s}", .{@errorName(err)});
        s.lock.unlock();
    };
    s.lock.lock();
    defer s.lock.unlock();
    if (s.state == .abandoned) {
        s.release();
    } else {
        if (s.reason_len == 0) s.setReason("closed", .{});
        s.state = .closed;
    }
}

/// Sets the reason (under the lock) and answers the error to leave `run` with.
fn fail(s: *Slot, comptime fmt: []const u8, args: anytype) error{WsClosed} {
    s.lock.lock();
    defer s.lock.unlock();
    s.setReason(fmt, args);
    return error.WsClosed;
}

fn run(s: *Slot) !void {
    const io = ioenv.io;
    // `url` is only freed by `release`, which the worker is the one to call
    // once it is running, so reading it without the lock is safe.
    const url = try parseUrl(s.url);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    if (url.tls) {
        const now = std.Io.Clock.real.now(io);
        client.ca_bundle.rescan(gpa, io, now) catch return fail(s, "CertificateBundleLoadFailure", .{});
        client.now = now;
    }
    const host = std.Io.net.HostName.init(url.host) catch return error.BadUrl;
    const conn = try client.connect(host, url.port, if (url.tls) .tls else .plain);
    defer {
        conn.closing = true;
        client.connection_pool.release(conn, io);
    }

    // -- the Upgrade --
    var key_raw: [16]u8 = undefined;
    io.random(&key_raw);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_raw);
    const w = conn.writer();
    try w.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n{s}\r\n", .{ url.target, url.authority, &key, s.header_block });
    try conn.flush();

    const r = conn.reader();
    const status = try r.takeDelimiterInclusive('\n');
    const status_line = std.mem.trimEnd(u8, status, "\r\n");
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101")) return fail(s, "HandshakeFailed: {s}", .{status_line});
    var upgrade_ok = false;
    var accept_ok = false;
    const expect = acceptKey(&key);
    while (true) {
        const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "upgrade") and std.ascii.eqlIgnoreCase(value, "websocket")) upgrade_ok = true;
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept") and std.mem.eql(u8, value, &expect)) accept_ok = true;
    }
    if (!upgrade_ok) return fail(s, "HandshakeFailed: no Upgrade: websocket", .{});
    if (!accept_ok) return fail(s, "HandshakeFailed: Sec-WebSocket-Accept does not match the key", .{});

    {
        s.lock.lock();
        defer s.lock.unlock();
        if (s.state == .abandoned) return;
        s.state = .open;
    }

    const fd = conn.stream_reader.stream.socket.handle;
    var partial: std.ArrayList(u8) = .empty;
    defer partial.deinit(gpa);
    var partial_binary = false;
    var in_message = false;

    while (true) {
        // What the program asked for: a close, or text to send.
        var outgoing: std.ArrayList([]u8) = .empty;
        defer {
            for (outgoing.items) |m| gpa.free(m);
            outgoing.deinit(gpa);
        }
        {
            s.lock.lock();
            defer s.lock.unlock();
            if (s.state == .abandoned) {
                writeClose(w, 1000, "") catch {};
                conn.flush() catch {};
                return;
            }
            std.mem.swap(std.ArrayList([]u8), &outgoing, &s.outbox);
            s.outbox_bytes = 0;
        }
        for (outgoing.items) |m| try writeFrame(w, .text, m, maskKey(io));
        if (outgoing.items.len > 0) try conn.flush();

        // Wait on the socket only when nothing is already buffered: a TLS
        // record already read off the socket is not something poll can see.
        if (r.bufferedLen() == 0 and conn.stream_reader.interface.bufferedLen() == 0) {
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, poll_ms) == 0) continue;
        }

        const frame = readFrame(r, gpa, message_max) catch |err| switch (err) {
            error.MessageTooLarge => {
                writeClose(w, 1009, "message too big") catch {};
                conn.flush() catch {};
                return fail(s, "MessageTooLarge", .{});
            },
            error.ProtocolError => {
                writeClose(w, 1002, "") catch {};
                conn.flush() catch {};
                return fail(s, "ProtocolError", .{});
            },
            error.ReadFailed => return fail(s, "{s}", .{if (conn.getReadError()) |e| @errorName(e) else "ReadFailed"}),
            error.EndOfStream => return fail(s, "EndOfStream: the server went away without a close frame", .{}),
            error.OutOfMemory => return error.OutOfMemory,
        };
        switch (frame.opcode) {
            .ping => {
                defer gpa.free(frame.payload);
                try writeFrame(w, .pong, frame.payload, maskKey(io));
                try conn.flush();
            },
            .pong => gpa.free(frame.payload),
            .close => {
                defer gpa.free(frame.payload);
                var code: u16 = 1005;
                var why: []const u8 = "";
                if (frame.payload.len >= 2) {
                    code = std.mem.readInt(u16, frame.payload[0..2], .big);
                    why = frame.payload[2..];
                }
                writeClose(w, if (code == 1005) 1000 else code, "") catch {};
                conn.flush() catch {};
                return fail(s, "server closed: {d} {s}", .{ code, why });
            },
            .text, .binary => {
                if (in_message) {
                    gpa.free(frame.payload);
                    return fail(s, "ProtocolError: a new message began inside a fragmented one", .{});
                }
                if (frame.fin) {
                    push(s, .{ .data = frame.payload, .binary = frame.opcode == .binary });
                } else {
                    defer gpa.free(frame.payload);
                    in_message = true;
                    partial_binary = frame.opcode == .binary;
                    partial.clearRetainingCapacity();
                    try partial.appendSlice(gpa, frame.payload);
                }
            },
            .continuation => {
                defer gpa.free(frame.payload);
                if (!in_message) return fail(s, "ProtocolError: continuation with nothing to continue", .{});
                if (partial.items.len + frame.payload.len > message_max) {
                    writeClose(w, 1009, "message too big") catch {};
                    conn.flush() catch {};
                    return fail(s, "MessageTooLarge", .{});
                }
                try partial.appendSlice(gpa, frame.payload);
                if (frame.fin) {
                    in_message = false;
                    push(s, .{ .data = try gpa.dupe(u8, partial.items), .binary = partial_binary });
                    partial.clearRetainingCapacity();
                }
            },
            _ => unreachable, // readFrame refuses the reserved opcodes
        }
    }
}

/// Queue one message for the program, dropping the oldest to make room.
fn push(s: *Slot, frame: Frame) void {
    s.lock.lock();
    defer s.lock.unlock();
    s.received += 1;
    s.bytes += frame.data.len;
    while (s.count > 0 and (s.count == s.ring.len or s.queued_bytes + frame.data.len > s.bytes_max)) {
        const old = s.ring[s.head];
        gpa.free(old.data);
        s.queued_bytes -= old.data.len;
        s.head = (s.head + 1) % s.ring.len;
        s.count -= 1;
        s.dropped += 1;
    }
    s.ring[(s.head + s.count) % s.ring.len] = frame;
    s.count += 1;
    s.queued_bytes += frame.data.len;
}

fn maskKey(io: std.Io) [4]u8 {
    var k: [4]u8 = undefined;
    io.random(&k);
    return k;
}

// ── Framing (RFC 6455 section 5) ─────────────────────────────────────────

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const FrameIn = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
};

pub fn acceptKey(key: []const u8) [28]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    h.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

/// One frame from the server. The payload is allocated with `a`.
pub fn readFrame(r: *std.Io.Reader, a: std.mem.Allocator, max: usize) (std.Io.Reader.Error || error{ OutOfMemory, MessageTooLarge, ProtocolError })!FrameIn {
    const b0 = try r.takeByte();
    const b1 = try r.takeByte();
    // No extension was negotiated, so a reserved bit set is an error, and a
    // server never masks.
    if (b0 & 0x70 != 0 or b1 & 0x80 != 0) return error.ProtocolError;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0)));
    const fin = b0 & 0x80 != 0;
    const len: u64 = switch (b1 & 0x7f) {
        126 => try r.takeInt(u16, .big),
        127 => try r.takeInt(u64, .big),
        else => |n| n,
    };
    switch (opcode) {
        .continuation, .text, .binary => {},
        .close, .ping, .pong => if (!fin or len > 125) return error.ProtocolError,
        _ => return error.ProtocolError,
    }
    if (len > max) return error.MessageTooLarge;
    const payload = try a.alloc(u8, @intCast(len));
    errdefer a.free(payload);
    try r.readSliceAll(payload);
    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

/// One client frame: always FIN, always masked (a server must refuse an
/// unmasked one).
pub fn writeFrame(w: *std.Io.Writer, opcode: Opcode, payload: []const u8, mask: [4]u8) std.Io.Writer.Error!void {
    try w.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));
    if (payload.len < 126) {
        try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(0x80 | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(0x80 | 127);
        try w.writeInt(u64, payload.len, .big);
    }
    try w.writeAll(&mask);
    var chunk: [512]u8 = undefined;
    var i: usize = 0;
    while (i < payload.len) {
        const n = @min(chunk.len, payload.len - i);
        for (chunk[0..n], payload[i .. i + n], i..) |*c, p, j| c.* = p ^ mask[j % 4];
        try w.writeAll(chunk[0..n]);
        i += n;
    }
}

fn writeClose(w: *std.Io.Writer, code: u16, why: []const u8) std.Io.Writer.Error!void {
    var buf: [125]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], code, .big);
    const n = @min(why.len, buf.len - 2);
    @memcpy(buf[2 .. 2 + n], why[0..n]);
    try writeFrame(w, .close, buf[0 .. 2 + n], maskKey(ioenv.io));
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "acceptKey is RFC 6455's worked example" {
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}

test "parseUrl finds host, port and the request target" {
    const u = try parseUrl("wss://bsky-relay.c.theo.io/subscribe?wantedCollections=app.bsky.feed.post#x");
    try testing.expect(u.tls);
    try testing.expectEqualStrings("bsky-relay.c.theo.io", u.host);
    try testing.expectEqual(@as(u16, 443), u.port);
    try testing.expectEqualStrings("/subscribe?wantedCollections=app.bsky.feed.post", u.target);
    const v = try parseUrl("ws://127.0.0.1:9001?a=1");
    try testing.expect(!v.tls);
    try testing.expectEqual(@as(u16, 9001), v.port);
    try testing.expectEqualStrings("127.0.0.1:9001", v.authority);
    try testing.expectEqualStrings("?a=1", v.target);
    try testing.expectError(error.BadUrl, parseUrl("https://example.com/"));
    try testing.expectError(error.BadUrl, parseUrl("ws://:80/"));
    try testing.expectError(error.BadUrl, parseUrl("ws://host:99999/"));
    try testing.expectError(error.BadUrl, parseUrl("ws://user@host/"));
}

test "readFrame: the three length encodings, and what a client must refuse" {
    const a = testing.allocator;
    // "Hello" unmasked, RFC 6455 5.7
    var r1: std.Io.Reader = .fixed(&.{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' });
    const f1 = try readFrame(&r1, a, 1 << 20);
    defer a.free(f1.payload);
    try testing.expect(f1.fin and f1.opcode == .text);
    try testing.expectEqualStrings("Hello", f1.payload);

    var big: [4 + 300]u8 = undefined;
    big[0] = 0x82;
    big[1] = 126;
    std.mem.writeInt(u16, big[2..4], 300, .big);
    @memset(big[4..], 7);
    var r2: std.Io.Reader = .fixed(&big);
    const f2 = try readFrame(&r2, a, 1 << 20);
    defer a.free(f2.payload);
    try testing.expectEqual(@as(usize, 300), f2.payload.len);
    try testing.expect(f2.opcode == .binary);

    var huge = [_]u8{ 0x81, 127, 0, 0, 0, 0, 0, 0x20, 0, 0 };
    var r3: std.Io.Reader = .fixed(&huge);
    try testing.expectError(error.MessageTooLarge, readFrame(&r3, a, 1 << 20));

    // masked from the server
    var r4: std.Io.Reader = .fixed(&.{ 0x81, 0x85, 1, 2, 3, 4, 0, 0, 0, 0, 0 });
    try testing.expectError(error.ProtocolError, readFrame(&r4, a, 1 << 20));
    // a fragmented ping
    var r5: std.Io.Reader = .fixed(&.{ 0x09, 0x00 });
    try testing.expectError(error.ProtocolError, readFrame(&r5, a, 1 << 20));
    // RSV1 without permessage-deflate
    var r6: std.Io.Reader = .fixed(&.{ 0xC1, 0x00 });
    try testing.expectError(error.ProtocolError, readFrame(&r6, a, 1 << 20));
}

test "writeFrame masks, and the mask undoes itself" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFrame(&w, .text, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d });
    // RFC 6455 5.7, "A single-frame masked text message"
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, w.buffered());
}

test "bad handles are refused, not answered" {
    try testing.expectError(error.BadHandle, recv(0));
    try testing.expectError(error.BadHandle, recv(-5));
    try testing.expectError(error.BadHandle, recv(12345));
    try testing.expectError(error.BadHandle, close(12345));
    try testing.expectError(error.BadHandle, stats(12345));
    try testing.expectError(error.BadHandle, send(12345, "x"));
    try testing.expectError(error.BadUrl, open("http://example.com/", &.{}));
    try testing.expectError(error.BadUrl, open("ws://example.com/", &.{.{ .name = "X", .value = "a\r\nInjected: 1" }}));
}

// A WebSocket server in a thread, on loopback, speaking plain ws. It says
// what a server says to a client: text, a fragmented text with a ping in the
// middle of it (which RFC 6455 allows), binary, an echo of what it was sent,
// and then a close.
const TestServer = struct {
    listen_fd: c_int,
    port: u16,
    /// what the client's pong carried, and the client's first text message
    pong: [16]u8 = undefined,
    pong_len: usize = 0,
    saw_header: bool = false,
    burst: usize = 0,
    failed: ?[]const u8 = null,

    fn start() !TestServer {
        const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var addr = std.mem.zeroes(std.posix.sockaddr.in);
        addr.family = std.posix.AF.INET;
        addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.BindFailed;
        if (std.c.listen(fd, 4) < 0) return error.ListenFailed;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        _ = std.c.getsockname(fd, @ptrCast(&addr), &len);
        return .{ .listen_fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
    }

    fn writeAll(fd: c_int, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const n = std.c.write(fd, bytes[i..].ptr, bytes.len - i);
            if (n <= 0) return;
            i += @intCast(n);
        }
    }

    fn readAll(fd: c_int, buf: []u8) bool {
        var i: usize = 0;
        while (i < buf.len) {
            const n = std.c.read(fd, buf[i..].ptr, buf.len - i);
            if (n <= 0) return false;
            i += @intCast(n);
        }
        return true;
    }

    /// A client frame: must be masked. Answers the opcode and the payload.
    fn readClientFrame(self: *TestServer, fd: c_int, out: []u8) ?struct { u8, []u8 } {
        var h: [2]u8 = undefined;
        if (!readAll(fd, &h)) return null;
        if (h[1] & 0x80 == 0) {
            self.failed = "client frame not masked";
            return null;
        }
        const len: usize = h[1] & 0x7f;
        if (len > 125) {
            self.failed = "test server only reads short frames";
            return null;
        }
        var mask: [4]u8 = undefined;
        if (!readAll(fd, &mask)) return null;
        if (!readAll(fd, out[0..len])) return null;
        for (out[0..len], 0..) |*b, i| b.* ^= mask[i % 4];
        return .{ h[0] & 0x0f, out[0..len] };
    }

    fn serve(self: *TestServer) void {
        const fd = std.c.accept(self.listen_fd, null, null);
        defer _ = std.c.close(fd);
        var req: [2048]u8 = undefined;
        var n: usize = 0;
        while (std.mem.indexOf(u8, req[0..n], "\r\n\r\n") == null) {
            const got = std.c.read(fd, req[n..].ptr, req.len - n);
            if (got <= 0) return;
            n += @intCast(got);
        }
        const head = req[0..n];
        self.saw_header = std.mem.indexOf(u8, head, "\r\nX-Test: yes\r\n") != null and
            std.mem.startsWith(u8, head, "GET /feed?x=1 HTTP/1.1\r\n");
        const k0 = std.mem.indexOf(u8, head, "Sec-WebSocket-Key: ").? + "Sec-WebSocket-Key: ".len;
        const k1 = std.mem.indexOfPos(u8, head, k0, "\r\n").?;
        var resp: [256]u8 = undefined;
        writeAll(fd, std.fmt.bufPrint(&resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{acceptKey(head[k0..k1])}) catch unreachable);

        if (self.burst > 0) {
            var i: usize = 0;
            while (i < self.burst) : (i += 1) writeAll(fd, &.{ 0x81, 0x01, '0' + @as(u8, @intCast(i)) });
            writeAll(fd, &.{ 0x88, 0x02, 0x03, 0xe8 });
            return;
        }

        writeAll(fd, &.{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' });
        writeAll(fd, &.{ 0x01, 0x04, 'f', 'r', 'a', 'g' }); // text, not FIN
        writeAll(fd, &.{ 0x89, 0x04, 'p', 'i', 'n', 'g' }); // ping between fragments
        writeAll(fd, &.{ 0x80, 0x04, 'm', 'e', 'n', 't' }); // continuation, FIN
        writeAll(fd, &.{ 0x82, 0x03, 1, 2, 3 });

        var buf: [125]u8 = undefined;
        const pong = self.readClientFrame(fd, &buf) orelse return;
        if (pong[0] != 0xA) {
            self.failed = "expected a pong";
            return;
        }
        @memcpy(self.pong[0..pong[1].len], pong[1]);
        self.pong_len = pong[1].len;
        const msg = self.readClientFrame(fd, &buf) orelse return;
        var echo: [127]u8 = undefined;
        echo[0] = 0x81;
        echo[1] = @intCast(msg[1].len);
        @memcpy(echo[2 .. 2 + msg[1].len], msg[1]);
        writeAll(fd, echo[0 .. 2 + msg[1].len]);
        writeAll(fd, &.{ 0x88, 0x05, 0x03, 0xe8, 'b', 'y', 'e' });
        const closing = self.readClientFrame(fd, &buf) orelse return;
        if (closing[0] != 0x8) self.failed = "expected the client's close";
    }
};

fn napMs(ms: u32) void {
    var req: std.c.timespec = .{ .sec = 0, .nsec = @intCast(@as(u64, ms) * 1_000_000) };
    _ = std.c.nanosleep(&req, null);
}

/// Poll `recv` until `want` messages have come, or two seconds pass.
fn collect(h: i64, into: *std.ArrayList(Frame), want: usize) !void {
    var tries: usize = 0;
    while (into.items.len < want and tries < 400) : (tries += 1) {
        switch (try recv(h)) {
            .frames => |fs| {
                defer gpa.free(fs);
                try into.appendSlice(testing.allocator, fs);
            },
            .closed => |why| {
                std.debug.print("closed early: {s}\n", .{why});
                return error.ClosedEarly;
            },
        }
        if (into.items.len < want) napMs(5);
    }
}

test "a loopback server: text, fragments around a ping, binary, an echo, and the server's close" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;

    var server = try TestServer.start();
    defer _ = std.c.close(server.listen_fd);
    const t = try std.Thread.spawn(.{}, TestServer.serve, .{&server});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/feed?x=1", .{server.port});
    const h = try open(url, &.{.{ .name = "X-Test", .value = "yes" }});

    var got: std.ArrayList(Frame) = .empty;
    defer {
        for (got.items) |f| gpa.free(f.data);
        got.deinit(testing.allocator);
    }
    try collect(h, &got, 3);
    try testing.expectEqual(@as(usize, 3), got.items.len);
    try testing.expectEqualStrings("hello", got.items[0].data);
    try testing.expectEqualStrings("fragment", got.items[1].data);
    try testing.expect(!got.items[1].binary);
    try testing.expect(got.items[2].binary);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, got.items[2].data);

    try testing.expectEqual(SendResult.ok, try send(h, "echo me"));
    try collect(h, &got, 4);
    try testing.expectEqualStrings("echo me", got.items[3].data);

    // then the server closes; the reason comes once and the handle dies
    var reason: ?[]const u8 = null;
    var tries: usize = 0;
    while (reason == null and tries < 400) : (tries += 1) {
        switch (try recv(h)) {
            .frames => |fs| {
                try testing.expectEqual(@as(usize, 0), fs.len);
                freeFrames(fs);
                napMs(5);
            },
            .closed => |why| reason = why,
        }
    }
    try testing.expectEqualStrings("server closed: 1000 bye", reason.?);
    try testing.expectError(error.BadHandle, recv(h));

    t.join();
    if (server.failed) |why| {
        std.debug.print("test server: {s}\n", .{why});
        return error.TestServerFailed;
    }
    try testing.expect(server.saw_header);
    try testing.expectEqualStrings("ping", server.pong[0..server.pong_len]);
}

test "a program that does not poll loses the oldest frames, and is told how many" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;

    var server = try TestServer.start();
    defer _ = std.c.close(server.listen_fd);
    server.burst = 10;
    const t = try std.Thread.spawn(.{}, TestServer.serve, .{&server});
    defer t.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/", .{server.port});
    const h = try openWith(url, &.{}, 4, bytes_max_default);

    var st = try stats(h);
    var tries: usize = 0;
    while (st.state != .closed and tries < 400) : (tries += 1) {
        napMs(5);
        st = try stats(h);
    }
    try testing.expectEqual(State.closed, st.state);
    try testing.expectEqual(@as(u64, 10), st.received);
    try testing.expectEqual(@as(u64, 6), st.dropped);
    try testing.expectEqual(@as(usize, 4), st.queued);

    const fs = (try recv(h)).frames;
    defer freeFrames(fs);
    try testing.expectEqual(@as(usize, 4), fs.len);
    try testing.expectEqualStrings("6", fs[0].data);
    try testing.expectEqualStrings("9", fs[3].data);
    try testing.expectEqualStrings("server closed: 1000 ", (try recv(h)).closed);
    try testing.expectError(error.BadHandle, stats(h));
}

test "ws_close on a live connection frees the handle at once" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;

    var server = try TestServer.start();
    defer _ = std.c.close(server.listen_fd);
    const t = try std.Thread.spawn(.{}, TestServer.serve, .{&server});

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/feed?x=1", .{server.port});
    const h = try open(url, &.{.{ .name = "X-Test", .value = "yes" }});
    try close(h);
    try testing.expectError(error.BadHandle, recv(h));
    try testing.expectError(error.BadHandle, close(h));
    // The server is left waiting for a pong the client will never send; its
    // read ends when the worker closes the socket.
    t.join();
    // and the slot comes back once the worker has gone
    var tries: usize = 0;
    const idx: usize = @intCast(@mod(h, slots_max));
    while (tries < 400) : (tries += 1) {
        slots[idx].lock.lock();
        const st = slots[idx].state;
        slots[idx].lock.unlock();
        if (st == .free) break;
        napMs(5);
    }
    try testing.expectEqual(State.free, slots[idx].state);
}

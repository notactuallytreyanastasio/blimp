const std = @import("std");
const ioenv = @import("ioenv.zig");
// Zig 0.16's std.http.Client, pointed at a TLS client that also speaks
// TLS 1.2 with ECDSA certificates. See src/vendor/zig_std/tls_client.zig.
const HttpClient = @import("vendor/zig_std/http_client.zig");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const interned = @import("value.zig").interned;
const unicode_builtins = @import("unicode_builtins.zig");
const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const EvalError = error{
    UndefinedVariable,
    TypeError,
    UnsupportedOperation,
    DivisionByZero,
    NotSupported,
    OutOfMemory,
    Bubble, // Actor failure propagation
    RecursionTooDeep,
};

pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value;

// Assertion failure detail (for structured test reports, e.g. in-browser tutorial).
// Each assertion writes its expected/actual into this buffer on failure.
// The test runner reads it after a failing test and resets it between tests.
pub var last_assertion_detail: [512]u8 = undefined;
pub var last_assertion_detail_len: u32 = 0;

fn recordAssertionDetail(comptime fmt: []const u8, args: anytype) void {
    var fbs = std.Io.Writer.fixed(&last_assertion_detail);
    fbs.print(fmt, args) catch {};
    last_assertion_detail_len = @intCast(fbs.buffered().len);
}

// Why the last builtin failed, in words, when a bare EvalError would leave
// the reader guessing which argument was wrong: "p256_ecdh: peer_public must
// be 65 bytes (got 33)". A builtin sets it with `failArg` and returns the
// error; the evaluator takes it (`takeFailure`) and puts it in the report.
// One slot, not per-thread: builtins run on the interpreter thread.
var failure_buf: [256]u8 = undefined;
var failure_len: ?usize = null;

/// Record why the call failed and answer TypeError, which is what a caller
/// passing the wrong thing gets from every other builtin.
fn failArg(comptime fmt: []const u8, args: anytype) EvalError {
    const msg = std.fmt.bufPrint(&failure_buf, fmt, args) catch failure_buf[0..];
    failure_len = msg.len;
    return error.TypeError;
}

/// The message the last failing builtin left, once; null when it left none.
pub fn takeFailure() ?[]const u8 {
    const len = failure_len orelse return null;
    failure_len = null;
    return failure_buf[0..len];
}

/// Registry entry for a built-in function.
const BuiltinEntry = struct {
    name: []const u8,
    func: BuiltinFn,
};

/// Registry of built-in functions.
/// Uses a simple array list with linear search (same pattern as checker.zig).
pub const BuiltinRegistry = struct {
    entries: std.ArrayList(BuiltinEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BuiltinRegistry {
        var reg = BuiltinRegistry{
            .entries = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
        reg.register("length", &builtinLength);
        reg.register("max", &builtinMax);
        reg.register("min", &builtinMin);
        reg.register("append", &builtinAppend);
        reg.register("reverse", &builtinReverse);
        reg.register("lookup", &builtinLookup);
        reg.register("put", &builtinPut);
        reg.register("keys", &builtinKeys);
        reg.register("now", &builtinNow);
        reg.register("now_ms", &builtinNowMs);
        reg.register("utc_offset", &builtinUtcOffset);
        reg.register("process_stats", &builtinProcessStats);
        reg.register("format_time", &builtinFormatTime);
        reg.register("concat", &builtinConcat);
        reg.register("split", &builtinSplit);
        reg.register("join", &builtinJoin);
        reg.register("contains", &builtinContains);
        reg.register("index_of", &builtinIndexOf);
        reg.register("replace", &builtinReplace);
        reg.register("to_string", &builtinToString);
        reg.register("to_int", &builtinToInt);
        reg.register("char_at", &builtinCharAt);
        reg.register("char_code", &builtinCharCode);
        reg.register("from_char_code", &builtinFromCharCode);
        reg.register("slice", &builtinSlice);
        reg.register("upcase", &builtinUpcase);
        reg.register("downcase", &builtinDowncase);
        // Character-aware counterparts of the byte builtins above (unicode_builtins.zig)
        reg.register("utf8_valid", &unicode_builtins.utf8Valid);
        reg.register("utf8_scrub", &unicode_builtins.utf8Scrub);
        reg.register("utf8_length", &unicode_builtins.utf8Length);
        reg.register("utf8_slice", &unicode_builtins.utf8Slice);
        reg.register("utf8_upcase", &unicode_builtins.utf8Upcase);
        reg.register("utf8_downcase", &unicode_builtins.utf8Downcase);
        reg.register("graphemes", &unicode_builtins.graphemes);
        reg.register("grapheme_length", &unicode_builtins.graphemeLength);
        reg.register("grapheme_slice", &unicode_builtins.graphemeSlice);
        reg.register("grapheme_take", &unicode_builtins.graphemeTake);
        reg.register("range", &builtinRange);
        reg.register("head", &builtinHead);
        reg.register("tail", &builtinTail);
        reg.register("sort", &builtinSort);
        reg.register("sort_by_keys", &builtinSortByKeys);
        reg.register("merge", &builtinMerge);
        reg.register("values", &builtinValues);
        reg.register("type_of", &builtinTypeOf);
        reg.register("print", &builtinPrint);
        reg.register("puts", &builtinPuts);
        // Test assertions
        reg.register("assert", &builtinAssert);
        // Generators for property-based testing
        reg.register("gen_integer", &builtinGenInteger);
        reg.register("gen_string", &builtinGenString);
        reg.register("gen_boolean", &builtinGenBoolean);
        reg.register("gen_list", &builtinGenList);
        reg.register("gen_one_of", &builtinGenOneOf);
        reg.register("assert_eq", &builtinAssertEq);
        reg.register("assert_ne", &builtinAssertNe);
        reg.register("refute", &builtinRefute);
        reg.register("rem", &builtinRem);
        reg.register("abs", &builtinAbs);
        reg.register("nil?", &builtinIsNil);
        reg.register("elem", &builtinElem);
        reg.register("floor", &builtinFloor);
        reg.register("ceil", &builtinCeil);
        reg.register("round", &builtinRound);
        inline for (float_fns) |entry| reg.register(entry[0], unaryFloat(entry[1]));
        reg.register("pow", &builtinPow);
        reg.register("atan2", &builtinAtan2);
        reg.register("not", &builtinNot);
        reg.register("random", &builtinRandom);
        reg.register("seed", &builtinSeed);
        reg.register("size", &builtinSize);
        reg.register("empty?", &builtinIsEmpty);
        reg.register("flat", &builtinFlat);
        reg.register("zip", &builtinZip);
        reg.register("uniq", &builtinUniq);
        reg.register("sum", &builtinSum);
        reg.register("set_at", &builtinSetAt);
        reg.register("json_encode", &builtinJsonEncode);
        reg.register("json_decode", &builtinJsonDecode);
        reg.register("sha256", &builtinSha256);
        reg.register("hmac_sha256", &builtinHmacSha256);
        reg.register("hex_encode", &builtinHexEncode);
        reg.register("hex_decode", &builtinHexDecode);
        reg.register("xor_bytes", &builtinXorBytes);
        reg.register("base64_encode", &builtinBase64Encode);
        reg.register("base64_decode", &builtinBase64Decode);
        reg.register("base64url_encode", &builtinBase64UrlEncode);
        reg.register("base64url_decode", &builtinBase64UrlDecode);
        // View primitives
        reg.register("stack", &viewStack);
        reg.register("row", &viewRow);
        reg.register("grid", &viewGrid);
        reg.register("text", &viewText);
        reg.register("heading", &viewHeading);
        reg.register("bold", &viewBold);
        reg.register("italic", &viewItalic);
        reg.register("code", &viewCode);
        reg.register("code_block", &viewCodeBlock);
        reg.register("blockquote", &viewBlockquote);
        reg.register("divider", &viewDivider);
        reg.register("list", &viewList);
        reg.register("link", &viewLink);
        reg.register("image", &viewImage);
        reg.register("video", &viewVideo);
        reg.register("canvas", &viewCanvas);
        reg.register("draw", &viewDraw);
        reg.register("el", &viewEl);
        reg.register("button", &viewButton);
        reg.register("timer", &viewTimer);
        reg.register("fetch", &viewFetch);
        reg.register("location_query", &viewLocationQuery);
        reg.register("stored", &viewStored);
        reg.register("store", &viewStore);
        reg.register("key", &viewKey);
        reg.register("input", &viewInput);
        reg.register("textarea", &viewTextarea);
        reg.register("select", &viewSelect);
        reg.register("option", &viewOption);
        reg.register("form", &viewForm);
        reg.register("mount_root", &viewMountRoot);
        // Actor introspection
        reg.register("actor_name", &builtinActorName);
        reg.register("to_atom", &builtinToAtom);
        reg.register("write_bytes", &builtinWriteBytes);
        reg.register("read_file", &builtinReadFile);
        reg.register("write_file", &builtinWriteFile);
        reg.register("list_dir", &builtinListDir);
        reg.register("file_exists?", &builtinFileExists);
        reg.register("file_size", &builtinFileSize);
        // Native-only builtins (TCP, process, WebSocket -- stubbed on WASM)
        reg.register("to_html", &builtinToHtml_impl);
        reg.register("tcp_listen", &builtinTcpListen_impl);
        reg.register("tcp_connect", &builtinTcpConnectNative);
        reg.register("http_start", &builtinHttpStart);
        reg.register("http_result", &builtinHttpResult);
        reg.register("ws_open", &builtinWsOpen_impl);
        reg.register("ws_recv", &builtinWsRecv_impl);
        reg.register("ws_send", &builtinWsSend_impl);
        reg.register("ws_close", &builtinWsClose_impl);
        reg.register("ws_stats", &builtinWsStats_impl);
        reg.register("tcp_accept", &builtinTcpAccept_impl);
        reg.register("tcp_read", &builtinTcpRead_impl);
        reg.register("tcp_write", &builtinTcpWrite_impl);
        reg.register("tcp_close", &builtinTcpClose_impl);
        reg.register("ws_accept_key", &builtinWsAcceptKey_impl);
        reg.register("ws_read_frame", &builtinWsReadFrame_impl);
        reg.register("ws_write_frame", &builtinWsWriteFrame_impl);
        reg.register("view_diff", &builtinViewDiff_impl);
        reg.register("fork", &builtinFork_impl);
        reg.register("waitpid", &builtinWaitpid_impl);
        reg.register("exit", &builtinExit_impl);
        reg.register("tcp_set_nonblocking", &builtinTcpSetNonblocking_impl);
        reg.register("tcp_poll", &builtinTcpPoll_impl);
        reg.register("tcp_write_some", &builtinTcpWriteSome_impl);
        reg.register("tcp_poll_write", &builtinTcpPollWrite_impl);
        reg.register("sleep_ms", &builtinSleepMs_impl);
        reg.register("read_line", &builtinReadLine_impl);
        reg.register("random_bytes", &builtinRandomBytes_impl);
        reg.register("random_token", &builtinRandomToken_impl);
        reg.register("getenv", &builtinGetenv_impl);
        reg.register("argv", &builtinArgv_impl);
        // P-256 and AES-128-GCM, for Web Push (RFC 8291 / RFC 8292)
        reg.register("p256_keypair", &builtinP256Keypair_impl);
        reg.register("p256_public_key", &builtinP256PublicKey);
        reg.register("p256_ecdh", &builtinP256Ecdh);
        reg.register("ecdsa_p256_sign", &builtinEcdsaP256Sign);
        reg.register("ecdsa_p256_verify", &builtinEcdsaP256Verify);
        reg.register("aes128gcm_encrypt", &builtinAes128GcmEncrypt);
        reg.register("aes128gcm_decrypt", &builtinAes128GcmDecrypt);
        return reg;
    }

    fn register(self: *BuiltinRegistry, name: []const u8, func: BuiltinFn) void {
        self.entries.append(self.allocator, .{ .name = name, .func = func }) catch {};
    }

    pub fn get(self: *const BuiltinRegistry, name: []const u8) ?BuiltinFn {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.func;
        }
        return null;
    }
};

// ============================================================
// Built-in function implementations
// ============================================================

/// Hand back a value, sharing the small immutable ones (see `value.interned`).
/// Builtins allocate from the same never-reclaimed heap as the evaluator, so a
/// `length` or `abs` in a loop is a value retained per iteration.
fn make(allocator: std.mem.Allocator, v: Value) EvalError!*const Value {
    if (interned.get(v)) |shared| return shared;
    const p = allocator.create(Value) catch return error.OutOfMemory;
    p.* = v;
    return p;
}

fn builtinLength(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const arg = args[0];
    switch (arg.*) {
        .list => |items| {
            return make(allocator, .{ .integer = @intCast(items.len) });
        },
        .string => |s| {
            return make(allocator, .{ .integer = @intCast(s.len) });
        },
        .map => |entries| {
            return make(allocator, .{ .integer = @intCast(entries.len) });
        },
        else => return error.TypeError,
    }
}

fn builtinMax(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    switch (args[0].*) {
        .integer => |a| switch (args[1].*) {
            .integer => |b| {
                return make(allocator, .{ .integer = @max(a, b) });
            },
            else => return error.TypeError,
        },
        else => return error.TypeError,
    }
}

fn builtinMin(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    switch (args[0].*) {
        .integer => |a| switch (args[1].*) {
            .integer => |b| {
                return make(allocator, .{ .integer = @min(a, b) });
            },
            else => return error.TypeError,
        },
        else => return error.TypeError,
    }
}

fn builtinAppend(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    switch (args[0].*) {
        .list => |items| {
            const new_items = allocator.alloc(*const Value, items.len + 1) catch return error.OutOfMemory;
            @memcpy(new_items[0..items.len], items);
            new_items[items.len] = args[1];
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .list = new_items };
            return result;
        },
        else => return error.TypeError,
    }
}

fn builtinReverse(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    switch (args[0].*) {
        .list => |items| {
            const new_items = allocator.alloc(*const Value, items.len) catch return error.OutOfMemory;
            for (items, 0..) |item, i| {
                new_items[items.len - 1 - i] = item;
            }
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .list = new_items };
            return result;
        },
        else => return error.TypeError,
    }
}

fn builtinLookup(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    switch (args[0].*) {
        .map => |entries| {
            const key_name = switch (args[1].*) {
                .string => |s| s,
                .atom => |s| s,
                else => return error.TypeError,
            };
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, key_name)) {
                    return entry.val;
                }
            }
            // Key not found, return nil
            return make(allocator, .nil);
        },
        else => return error.TypeError,
    }
}

fn builtinPut(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return error.TypeError;
    switch (args[0].*) {
        .map => |entries| {
            const key_name = switch (args[1].*) {
                .string => |s| s,
                .atom => |s| s,
                else => return error.TypeError,
            };
            // Check if key exists -- if so, replace; else append
            var found = false;
            var new_entries = allocator.alloc(Value.MapEntry, entries.len + 1) catch return error.OutOfMemory;
            var count: usize = 0;
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, key_name)) {
                    new_entries[count] = .{ .key = entry.key, .val = args[2] };
                    found = true;
                } else {
                    new_entries[count] = entry;
                }
                count += 1;
            }
            if (!found) {
                new_entries[count] = .{ .key = key_name, .val = args[2] };
                count += 1;
            }
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .map = new_entries[0..count] };
            return result;
        },
        else => return error.TypeError,
    }
}

fn builtinKeys(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    switch (args[0].*) {
        .map => |entries| {
            const key_vals = allocator.alloc(*const Value, entries.len) catch return error.OutOfMemory;
            for (entries, 0..) |entry, i| {
                const kv = allocator.create(Value) catch return error.OutOfMemory;
                kv.* = Value{ .string = entry.key };
                key_vals[i] = kv;
            }
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .list = key_vals };
            return result;
        },
        else => return error.TypeError,
    }
}

/// The browser's clock. WebAssembly has none of its own, so the page hands
/// it in (blimp_set_clock in wasm_api.zig) before every eval and send: the
/// wall clock and a monotonic one in milliseconds, and the local zone's
/// offset from UTC in seconds. A host that never sets it reads zeros.
pub var wasm_clock: struct { epoch_ms: f64 = 0, mono_ms: f64 = 0, utc_offset_s: i64 = 0 } = .{};

fn builtinNow(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    // zig 0.16 removed `std.time.timestamp`; libc still has the call it was.
    const timestamp: i64 = if (is_wasm)
        @intFromFloat(@floor(wasm_clock.epoch_ms / 1000))
    else
        blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.REALTIME, &ts);
            break :blk @intCast(ts.sec);
        };
    return make(allocator, .{ .integer = timestamp });
}

/// now_ms() -> milliseconds on a clock that only goes forwards.
///
/// `now()` answers whole seconds of wall time, which cannot express a 200ms
/// game tick and jumps if the system clock is set. This is MONOTONIC, so it is
/// good for measuring an interval and useless for telling the time; the two
/// are different questions and this answers the second one.
fn builtinNowMs(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    const ms: i64 = if (is_wasm)
        @intFromFloat(@floor(wasm_clock.mono_ms))
    else
        blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            break :blk @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
        };
    return make(allocator, .{ .integer = ms });
}

/// The C library's struct tm, as macOS, glibc and musl all lay it out:
/// nine ints, then the offset east of UTC and the zone's name.
const CTm = extern struct {
    sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int,
    wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8,
};
const libc_tz = struct {
    extern "c" fn time(t: ?*c_long) c_long;
    extern "c" fn localtime_r(t: *const c_long, out: *CTm) ?*CTm;
};

/// utc_offset() -- seconds the local time zone is ahead of UTC, now
/// (-14400 in New York in summer), so format_time(now() + utc_offset(), ..)
/// is the local time. In a browser it is the page's zone; on a server,
/// the process's (TZ), which in a container is usually UTC: 0.
fn builtinUtcOffset(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    const offset: i64 = if (is_wasm)
        wasm_clock.utc_offset_s
    else blk: {
        const t = libc_tz.time(null);
        var tm: CTm = undefined;
        if (libc_tz.localtime_r(&t, &tm) == null) break :blk 0;
        break :blk @intCast(tm.gmtoff);
    };
    return make(allocator, .{ .integer = offset });
}

/// process_stats() -> %{cpu_ms: Int, rss_bytes: Int, heap_bytes: Int, cores: Int}
///
/// What this process has cost so far, for a program that wants to watch
/// itself (bobbby.online graphs its own server).
///   cpu_ms      user plus system CPU time since the process started, in ms
///               (getrusage). CPU use over an interval is the difference
///               of two readings over the wall time between them.
///   rss_bytes   resident memory now: /proc/self/statm on Linux, the Mach
///               task's resident_size on macOS, 0 where neither exists.
///   heap_bytes  what Blimp's heap holds now, the number `:stats` calls
///               heap: garbage included until the next compaction.
///   cores       CPUs the machine has, so cpu_ms can be read as a share.
/// In the browser there is no process to ask: it answers nil.
fn builtinProcessStats(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    if (is_wasm) return make(allocator, .nil);
    var ru: std.c.rusage = undefined;
    const cpu_ms: i64 = if (std.c.getrusage(0, &ru) == 0)
        @as(i64, @intCast(ru.utime.sec + ru.stime.sec)) * 1000 +
            @divTrunc(@as(i64, @intCast(ru.utime.usec + ru.stime.usec)), 1000)
    else
        0;
    const heap: i64 = if (@import("heap_limit.zig").current) |h| @intCast(h.used) else 0;
    const cores: i64 = @intCast(std.Thread.getCpuCount() catch 1);
    const entries = allocator.alloc(Value.MapEntry, 4) catch return error.OutOfMemory;
    entries[0] = .{ .key = "cpu_ms", .val = try make(allocator, .{ .integer = cpu_ms }) };
    entries[1] = .{ .key = "rss_bytes", .val = try make(allocator, .{ .integer = residentBytes() }) };
    entries[2] = .{ .key = "heap_bytes", .val = try make(allocator, .{ .integer = heap }) };
    entries[3] = .{ .key = "cores", .val = try make(allocator, .{ .integer = cores }) };
    return make(allocator, .{ .map = entries });
}

fn residentBytes() i64 {
    switch (builtin.os.tag) {
        .linux => {
            // statm: size resident shared text lib data dt, in pages.
            const fd = std.c.open("/proc/self/statm", .{}, @as(std.c.mode_t, 0));
            if (fd < 0) return 0;
            defer _ = std.c.close(fd);
            var buf: [128]u8 = undefined;
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) return 0;
            var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(n)], ' ');
            _ = it.next() orelse return 0;
            const pages = std.fmt.parseInt(i64, it.next() orelse return 0, 10) catch return 0;
            return pages * @as(i64, @intCast(std.heap.pageSize()));
        },
        .macos => {
            var info: std.c.mach_task_basic_info = undefined;
            var count: std.c.mach_msg_type_number_t = std.c.MACH.TASK.BASIC.INFO_COUNT;
            const kr = std.c.task_info(std.c.mach_task_self(), std.c.MACH.TASK.BASIC.INFO, @ptrCast(&info), &count);
            if (kr != 0) return 0;
            return @intCast(info.resident_size);
        },
        else => return 0,
    }
}

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// A moment in UTC, broken into the fields strftime prints.
const CivilTime = struct {
    year: i64,
    month: u8, // 1..12
    day: u8, // 1..31
    yday: u16, // 1..366
    wday: u8, // 0 = Sunday
    hour: u8,
    minute: u8,
    second: u8,

    /// Howard Hinnant's civil_from_days, on signed days, so it is right on
    /// both sides of 1970 and through the Gregorian 100/400-year rules.
    /// std.time.epoch would do the positive half; `-1` is 1969-12-31 and a
    /// date format has no business refusing it.
    fn fromEpoch(t: i64) CivilTime {
        const days = @divFloor(t, 86400);
        const secs: u32 = @intCast(@mod(t, 86400));
        const z = days + 719468;
        const era = @divFloor(z, 146097);
        const doe: i64 = z - era * 146097; // [0, 146096]
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365], March-based
        const mp = @divFloor(5 * doy + 2, 153); // [0, 11], March = 0
        const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
        const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
        const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);

        const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
        const before = [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
        const yday = before[month - 1] + day + @as(u16, if (leap and month > 2) 1 else 0);

        return .{
            .year = year,
            .month = month,
            .day = day,
            .yday = yday,
            .wday = @intCast(@mod(days + 4, 7)), // 1970-01-01 was a Thursday
            .hour = @intCast(secs / 3600),
            .minute = @intCast(secs / 60 % 60),
            .second = @intCast(secs % 60),
        };
    }
};

/// format_time(epoch_seconds, pattern) -> String, in UTC.
///
///   %Y year        %m month 01-12   %d day 01-31    %j day of year 001-366
///   %H hour 00-23  %I hour 01-12    %p AM/PM        %M minute    %S second
///   %B September   %b Sep           %A Tuesday      %a Tue
///   %Z "UTC"       %% a literal %
///
/// `-` between the % and a numeric directive (d m j H I M S) drops its zero
/// padding: "%B %-d" is "January 1", which is how a blog writes a date.
///
/// UTC only: there is no time zone database behind this, so %Z is always
/// "UTC" rather than a guess at the reader's zone. Raises TypeError for an
/// epoch that is not an Int (now() answers Ints), a pattern that is not a
/// String, a directive not listed above, and a lone % at the end -- strftime
/// would print those as they are, and a typo in a date format should not
/// ship.
fn builtinFormatTime(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .integer or args[1].* != .string) return error.TypeError;
    const t = CivilTime.fromEpoch(args[0].integer);
    const pattern = args[1].string;
    var out: std.ArrayList(u8) = .empty;
    const oom = error.OutOfMemory;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c != '%') {
            out.append(allocator, c) catch return oom;
            continue;
        }
        i += 1;
        if (i >= pattern.len) return error.TypeError;
        const no_pad = pattern[i] == '-';
        if (no_pad) {
            i += 1;
            if (i >= pattern.len) return error.TypeError;
        }
        const d = pattern[i];
        const num: ?i64 = switch (d) {
            'd' => t.day,
            'm' => t.month,
            'j' => t.yday,
            'H' => t.hour,
            'I' => if (t.hour % 12 == 0) 12 else t.hour % 12,
            'M' => t.minute,
            'S' => t.second,
            else => null,
        };
        if (num) |n| {
            const width: usize = if (no_pad) 1 else if (d == 'j') 3 else 2;
            out.print(allocator, "{d:0>[1]}", .{ @as(u64, @intCast(n)), width }) catch return oom;
            continue;
        }
        if (no_pad) return error.TypeError;
        switch (d) {
            'Y' => if (t.year >= 0)
                out.print(allocator, "{d:0>4}", .{@as(u64, @intCast(t.year))}) catch return oom
            else
                out.print(allocator, "{d}", .{t.year}) catch return oom,
            'p' => out.appendSlice(allocator, if (t.hour < 12) "AM" else "PM") catch return oom,
            'B' => out.appendSlice(allocator, month_names[t.month - 1]) catch return oom,
            'b' => out.appendSlice(allocator, month_names[t.month - 1][0..3]) catch return oom,
            'A' => out.appendSlice(allocator, day_names[t.wday]) catch return oom,
            'a' => out.appendSlice(allocator, day_names[t.wday][0..3]) catch return oom,
            'Z' => out.appendSlice(allocator, "UTC") catch return oom,
            '%' => out.append(allocator, '%') catch return oom,
            else => return error.TypeError,
        }
    }
    return make(allocator, .{ .string = out.toOwnedSlice(allocator) catch return oom });
}

// ── String builtins ─────────────────────────────────────

/// concat("hello", " ", "world") => "hello world"
fn builtinConcat(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 2) return error.TypeError;
    var total_len: usize = 0;
    for (args) |arg| {
        switch (arg.*) {
            .string => |s| total_len += s.len,
            .integer => |n| {
                total_len += @intCast(std.fmt.count("{d}", .{n}));
            },
            .atom => |a| total_len += a.len + 1,
            else => return error.TypeError,
        }
    }
    var buf = allocator.alloc(u8, total_len) catch return error.OutOfMemory;
    var pos: usize = 0;
    for (args) |arg| {
        switch (arg.*) {
            .string => |s| {
                @memcpy(buf[pos .. pos + s.len], s);
                pos += s.len;
            },
            .integer => |n| {
                const written = std.fmt.bufPrint(buf[pos..], "{d}", .{n}) catch "";
                pos += written.len;
            },
            .atom => |a| {
                buf[pos] = ':';
                pos += 1;
                @memcpy(buf[pos .. pos + a.len], a);
                pos += a.len;
            },
            else => {},
        }
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf[0..pos] };
    return result;
}

/// split("a,b,c", ",") => ["a", "b", "c"]
fn builtinSplit(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const str = args[0].string;
    const sep = args[1].string;

    var parts: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
    var start: usize = 0;
    var i: usize = 0;
    // No continue-expression: after a match `i` must land exactly on the byte
    // following the separator, or a separator that starts there is skipped
    // and "a,,b" splits into two fields instead of three. An empty separator
    // matches at every byte, so it still has to step one to make progress.
    while (i + sep.len <= str.len) {
        if (std.mem.eql(u8, str[i .. i + sep.len], sep)) {
            const part = allocator.create(Value) catch return error.OutOfMemory;
            part.* = Value{ .string = str[start..i] };
            parts.append(allocator, part) catch return error.OutOfMemory;
            i += sep.len;
            start = i;
            if (sep.len == 0) i += 1;
        } else {
            i += 1;
        }
    }
    // Last segment
    const last = allocator.create(Value) catch return error.OutOfMemory;
    last.* = Value{ .string = str[start..] };
    parts.append(allocator, last) catch return error.OutOfMemory;

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = parts.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

/// join(["a", "b"], ", ") => "a, b"
/// The inverse of split. It sizes the result once and copies each part once;
/// building the same string with `concat` in a loop copies everything built
/// so far on every step, and the evaluator frees none of those copies.
fn builtinJoin(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .list or args[1].* != .string) return error.TypeError;
    const parts = args[0].list;
    const sep = args[1].string;

    var total: usize = 0;
    for (parts, 0..) |part, i| {
        if (part.* != .string) return error.TypeError;
        total += part.string.len;
        if (i > 0) total += sep.len;
    }

    const buf = allocator.alloc(u8, total) catch return error.OutOfMemory;
    var pos: usize = 0;
    for (parts, 0..) |part, i| {
        if (i > 0) {
            @memcpy(buf[pos .. pos + sep.len], sep);
            pos += sep.len;
        }
        @memcpy(buf[pos .. pos + part.string.len], part.string);
        pos += part.string.len;
    }

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf };
    return result;
}

/// contains("hello world", "world") => true
fn builtinContains(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const found = std.mem.indexOf(u8, args[0].string, args[1].string) != null;
    return make(allocator, .{ .boolean = found });
}

/// index_of("hello world", "world") => 6, or -1 when it is not there.
///
/// A byte offset, so it can go straight to `slice`. An empty needle is found
/// at 0, as in every other language's indexOf. Strings only: TypeError for
/// a list or an atom, rather than searching its formatted text.
///
/// A program's own `def index_of` still wins; user defs shadow builtins.
fn builtinIndexOf(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .string) return error.TypeError;
    const at: i64 = if (std.mem.indexOf(u8, args[0].string, args[1].string)) |i| @intCast(i) else -1;
    return make(allocator, .{ .integer = at });
}

/// replace(s, find, with) => s with every occurrence of find replaced,
/// scanning left to right without overlap ("aaa", "aa", "b" => "ba") and
/// never rescanning what it inserted, so replacing "a" with "aa" terminates.
///
/// TypeError for an empty find -- it matches between every pair of bytes and
/// there is no one answer to what replacing it means -- and for non-Strings.
/// A string with no match comes back as the same value, not a copy.
fn builtinReplace(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3 or args[0].* != .string or args[1].* != .string or args[2].* != .string) return error.TypeError;
    const s = args[0].string;
    const find = args[1].string;
    const with = args[2].string;
    if (find.len == 0) return error.TypeError;
    const count = std.mem.count(u8, s, find);
    if (count == 0) return args[0];
    const out = allocator.alloc(u8, s.len - count * find.len + count * with.len) catch return error.OutOfMemory;
    _ = std.mem.replace(u8, s, find, with, out);
    return make(allocator, .{ .string = out });
}

/// to_string(42) => "42", to_string(:ok) => "ok"
fn builtinToString(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .string => return args[0],
        .integer => |n| {
            result.* = Value{ .string = std.fmt.allocPrint(allocator, "{d}", .{n}) catch return error.OutOfMemory };
        },
        .float => |f| {
            result.* = Value{ .string = std.fmt.allocPrint(allocator, "{d}", .{f}) catch return error.OutOfMemory };
        },
        .atom => |a| {
            result.* = Value{ .string = a };
        },
        .boolean => |b| {
            result.* = Value{ .string = if (b) "true" else "false" };
        },
        .nil => {
            result.* = Value{ .string = "nil" };
        },
        else => return error.TypeError,
    }
    return result;
}

/// to_atom("hello") => :hello — converts a string to an atom
fn builtinToAtom(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    switch (args[0].*) {
        .string => |s| {
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .atom = s };
            return result;
        },
        .atom => return args[0],
        else => return error.TypeError,
    }
}

/// to_int("42") => 42
fn builtinToInt(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .integer => return args[0],
        .string => |s| {
            const n = std.fmt.parseInt(i64, s, 10) catch return error.TypeError;
            result.* = Value{ .integer = n };
        },
        .float => |f| {
            result.* = Value{ .integer = @intFromFloat(f) };
        },
        .boolean => |b| {
            result.* = Value{ .integer = if (b) 1 else 0 };
        },
        else => return error.TypeError,
    }
    return result;
}

/// char_at("hello", 1) => "e" -- single character at index
fn builtinCharAt(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .integer) return error.TypeError;
    const s = args[0].string;
    const idx: usize = @intCast(@max(0, args[1].integer));
    if (idx >= s.len) {
        return make(allocator, .nil);
    }
    const ch = allocator.alloc(u8, 1) catch return error.OutOfMemory;
    ch[0] = s[idx];
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = ch };
    return result;
}

/// char_code("A", 0) => 65 -- ASCII/byte value at index
/// char_code("A") => 65 -- first char if no index
fn builtinCharCode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    // Return nil for nil input (char_at past end returns nil)
    if (args[0].* == .nil) {
        return make(allocator, .nil);
    }
    if (args[0].* != .string) return error.TypeError;
    const s = args[0].string;
    const idx: usize = if (args.len == 2 and args[1].* == .integer)
        @intCast(@max(0, args[1].integer))
    else
        0;
    if (s.len == 0 or idx >= s.len) {
        return make(allocator, .nil);
    }
    return make(allocator, .{ .integer = @intCast(s[idx]) });
}

/// from_char_code(65) => "A" -- integer to single-byte string
fn builtinFromCharCode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const code: u8 = @intCast(@max(0, @min(255, args[0].integer)));
    const ch = allocator.alloc(u8, 1) catch return error.OutOfMemory;
    ch[0] = code;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = ch };
    return result;
}

/// slice("hello", 1, 3) => "ell" -- start index, length
fn builtinSlice(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return error.TypeError;
    if (args[0].* != .string or args[1].* != .integer or args[2].* != .integer) return error.TypeError;
    const str = args[0].string;
    const start: usize = @intCast(@max(args[1].integer, 0));
    const len: usize = @intCast(@max(args[2].integer, 0));
    const end = @min(start + len, str.len);
    if (start >= str.len or start >= end) {
        const result = allocator.create(Value) catch return error.OutOfMemory;
        result.* = Value{ .string = "" };
        return result;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = str[start..end] };
    return result;
}

/// upcase("hello") => "HELLO"
fn builtinUpcase(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const src = args[0].string;
    var buf = allocator.alloc(u8, src.len) catch return error.OutOfMemory;
    for (src, 0..) |c, i| {
        buf[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf };
    return result;
}

/// downcase("HELLO") => "hello"
fn builtinDowncase(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const src = args[0].string;
    var buf = allocator.alloc(u8, src.len) catch return error.OutOfMemory;
    for (src, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf };
    return result;
}

// ── Collection builtins ─────────────────────────────────

/// range(1, 5) => [1, 2, 3, 4, 5]
fn builtinRange(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .integer) return error.TypeError;
    const start = args[0].integer;
    const end_val = args[1].integer;
    const len: usize = if (end_val >= start) @intCast(end_val - start + 1) else 0;

    var items = allocator.alloc(*const Value, len) catch return error.OutOfMemory;
    var i: usize = 0;
    var n = start;
    while (n <= end_val) : (n += 1) {
        const v = allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .integer = n };
        items[i] = v;
        i += 1;
    }

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

/// head([1, 2, 3]) => 1
fn builtinHead(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    if (args[0].list.len == 0) {
        return make(allocator, .nil);
    }
    return args[0].list[0];
}

/// tail([1, 2, 3]) => [2, 3]
fn builtinTail(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    if (args[0].list.len <= 1) {
        result.* = Value{ .list = &.{} };
    } else {
        result.* = Value{ .list = args[0].list[1..] };
    }
    return result;
}

/// sort([3, 1, 2]) => [1, 2, 3]
///
/// Numbers sort numerically (Ints and Floats together) and strings by their
/// bytes. Anything else, a list that mixes the two, or a NaN is a TypeError.
///
/// pdqsort, so O(n log n) and not stable: 1 and 1.0 may come out in either
/// order. It was insertion sort, and 100k descending Ints took 18 s.
fn builtinSort(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    const src = args[0].list;
    try checkSortKeys(src);
    const items = allocator.alloc(*const Value, src.len) catch return error.OutOfMemory;
    @memcpy(items, src);
    std.sort.pdq(*const Value, items, {}, sortLessThan);
    return make(allocator, .{ .list = items });
}

/// The rule sort and sort_by_keys share: all numbers or all strings.
///
/// This used to read every non-integer as 0 and hand back a list of strings
/// exactly as it came in. NaN is refused too: it is neither less than nor
/// greater than anything, which breaks the ordering a sort relies on, and
/// [1.0, NaN, 0.5] came back from the old sort unsorted and unremarked.
fn checkSortKeys(keys: []const *const Value) EvalError!void {
    const all_numbers = for (keys) |k| {
        switch (k.*) {
            .integer => {},
            .float => |f| if (std.math.isNan(f)) return error.TypeError,
            else => break false,
        }
    } else true;
    const all_strings = for (keys) |k| {
        if (k.* != .string) break false;
    } else true;
    if (!all_numbers and !all_strings) return error.TypeError;
}

/// sort_by_keys(items, keys) -> items reordered so their keys ascend.
///
/// keys[i] is the key of items[i]; the two lists must be the same length.
/// Keys follow sort's rules (all numbers or all strings, no NaN), anything
/// else is a TypeError. Stable: items with equal keys keep their order, so
/// sorting by a second key and then a first gives a two-key sort.
///
/// It exists because a builtin cannot call a closure -- only the evaluator
/// can, which is why map and filter live there -- so `sort_by(list, f)` is
/// spelled `sort_by_keys(list, map(list, f))` for now. That also calls f once
/// per item rather than twice per comparison.
fn builtinSortByKeys(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .list or args[1].* != .list) return error.TypeError;
    return sortByKeys(allocator, args[0].list, args[1].list);
}

/// The body of sort_by_keys, public so that an evaluator-side
/// `sort_by(list, f)` can compute the keys with the closure and hand them
/// here.
pub fn sortByKeys(allocator: std.mem.Allocator, items: []const *const Value, keys: []const *const Value) EvalError!*const Value {
    if (items.len != keys.len) return error.TypeError;
    try checkSortKeys(keys);
    const order = allocator.alloc(usize, items.len) catch return error.OutOfMemory;
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    // Block sort is the stable one in std; pdq is not.
    std.sort.block(usize, order, keys, struct {
        fn lt(ks: []const *const Value, a: usize, b: usize) bool {
            return sortLessThan({}, ks[a], ks[b]);
        }
    }.lt);
    const out = allocator.alloc(*const Value, items.len) catch return error.OutOfMemory;
    for (order, 0..) |o, i| out[i] = items[o];
    return make(allocator, .{ .list = out });
}

fn sortLessThan(_: void, a: *const Value, b: *const Value) bool {
    if (a.* == .string) return std.mem.lessThan(u8, a.string, b.string);
    const x: f64 = if (a.* == .integer) @floatFromInt(a.integer) else a.float;
    const y: f64 = if (b.* == .integer) @floatFromInt(b.integer) else b.float;
    return x < y;
}

// ── Map and utility builtins ────────────────────────────

/// merge(%{a: 1}, %{b: 2}) => %{a: 1, b: 2}
fn builtinMerge(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .map or args[1].* != .map) return error.TypeError;
    const a = args[0].map;
    const b = args[1].map;

    // Start with all entries from a, then add/overwrite from b
    var entries: std.ArrayList(Value.MapEntry) = .{ .items = &.{}, .capacity = 0 };
    for (a) |entry| {
        entries.append(allocator, entry) catch return error.OutOfMemory;
    }
    for (b) |new_entry| {
        var found = false;
        for (entries.items) |*existing| {
            if (std.mem.eql(u8, existing.key, new_entry.key)) {
                existing.val = new_entry.val;
                found = true;
                break;
            }
        }
        if (!found) {
            entries.append(allocator, new_entry) catch return error.OutOfMemory;
        }
    }

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .map = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

/// values(%{a: 1, b: 2}) => [1, 2]
fn builtinValues(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .map) return error.TypeError;
    const entries = args[0].map;
    var items = allocator.alloc(*const Value, entries.len) catch return error.OutOfMemory;
    for (entries, 0..) |entry, i| {
        items[i] = entry.val;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

/// type_of(42) => :integer, type_of("hi") => :string, etc.
fn builtinTypeOf(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    const type_name: []const u8 = switch (args[0].*) {
        .integer => "integer",
        .float => "float",
        .string => "string",
        .atom => "atom",
        .boolean => "boolean",
        .nil => "nil",
        .hole => "hole",
        .list => "list",
        .tuple => "tuple",
        .map => "map",
        .actor_ref => "actor_ref",
        .closure => "closure",
        .view_node => "view_node",
    };
    result.* = Value{ .atom = type_name };
    return result;
}

/// actor_name(actor_ref) -> String: returns the type name of an actor reference
fn builtinActorName(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    switch (args[0].*) {
        .actor_ref => |ref| {
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .string = ref.type_name };
            return result;
        },
        else => return error.TypeError,
    }
}

// ── JSON ────────────────────────────────────────────────

/// How deep an array or object may nest, in either direction. Both walks
/// below recurse on the native stack, and a request body of 100k `[` is a
/// few hundred bytes; past this depth json_decode answers an error tuple and
/// json_encode raises.
const json_max_depth = 512;

/// {tag, payload} -- the shape json_decode answers in.
fn tagged(allocator: std.mem.Allocator, tag: []const u8, payload: *const Value) EvalError!*const Value {
    const items = allocator.alloc(*const Value, 2) catch return error.OutOfMemory;
    items[0] = try make(allocator, .{ .atom = tag });
    items[1] = payload;
    return make(allocator, .{ .tuple = items });
}

/// json_encode(value) -> String, compact (no whitespace).
///
/// Int and Float are numbers, String and Atom are strings, true/false/nil are
/// true/false/null, List and Tuple are arrays, Map is an object in the map's
/// own key order.
///
/// A Float always keeps a `.` or an exponent, so 2.0 encodes as `2.0` and
/// decodes back as a Float; `{d}` alone writes `2`, which comes back as Int 2
/// and compares unequal to what went in. Magnitudes at or past 1e21, or under
/// 1e-6, use an exponent, as JavaScript does, instead of 300 digits.
///
/// Raises TypeError for: NaN and infinity (JSON has no spelling for them),
/// a string or atom that is not valid UTF-8 (JSON text is UTF-8), closures,
/// actor refs, view nodes and holes, and nesting deeper than json_max_depth.
fn builtinJsonEncode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    var out: std.ArrayList(u8) = .empty;
    try jsonWrite(allocator, &out, args[0], 0);
    return make(allocator, .{ .string = out.toOwnedSlice(allocator) catch return error.OutOfMemory });
}

fn jsonWrite(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: *const Value, depth: usize) EvalError!void {
    if (depth > json_max_depth) return error.TypeError;
    const oom = error.OutOfMemory;
    switch (v.*) {
        .integer => |n| out.print(allocator, "{d}", .{n}) catch return oom,
        .float => |f| {
            if (!std.math.isFinite(f)) return error.TypeError;
            const mag = @abs(f);
            if (mag != 0 and (mag >= 1e21 or mag < 1e-6)) {
                out.print(allocator, "{e}", .{f}) catch return oom;
            } else {
                const start = out.items.len;
                out.print(allocator, "{d}", .{f}) catch return oom;
                if (std.mem.indexOfAny(u8, out.items[start..], ".e") == null)
                    out.appendSlice(allocator, ".0") catch return oom;
            }
        },
        .string => |s| try jsonWriteString(allocator, out, s),
        .atom => |a| try jsonWriteString(allocator, out, a),
        .boolean => |b| out.appendSlice(allocator, if (b) "true" else "false") catch return oom,
        .nil => out.appendSlice(allocator, "null") catch return oom,
        .list, .tuple => |items| {
            out.append(allocator, '[') catch return oom;
            for (items, 0..) |item, i| {
                if (i > 0) out.append(allocator, ',') catch return oom;
                try jsonWrite(allocator, out, item, depth + 1);
            }
            out.append(allocator, ']') catch return oom;
        },
        .map => |entries| {
            out.append(allocator, '{') catch return oom;
            for (entries, 0..) |entry, i| {
                if (i > 0) out.append(allocator, ',') catch return oom;
                try jsonWriteString(allocator, out, entry.key);
                out.append(allocator, ':') catch return oom;
                try jsonWrite(allocator, out, entry.val, depth + 1);
            }
            out.append(allocator, '}') catch return oom;
        },
        .hole, .actor_ref, .closure, .view_node => return error.TypeError,
    }
}

/// A JSON string per RFC 8259 section 7: `"` and `\` escaped, control
/// characters below 0x20 escaped (the short forms where JSON has one), and
/// everything else -- `/`, DEL, multi-byte UTF-8 -- written as it is.
fn jsonWriteString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) EvalError!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.TypeError;
    const oom = error.OutOfMemory;
    out.append(allocator, '"') catch return oom;
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice(allocator, "\\\"") catch return oom,
            '\\' => out.appendSlice(allocator, "\\\\") catch return oom,
            '\n' => out.appendSlice(allocator, "\\n") catch return oom,
            '\r' => out.appendSlice(allocator, "\\r") catch return oom,
            '\t' => out.appendSlice(allocator, "\\t") catch return oom,
            0x08 => out.appendSlice(allocator, "\\b") catch return oom,
            0x0c => out.appendSlice(allocator, "\\f") catch return oom,
            0...0x07, 0x0b, 0x0e...0x1f => out.print(allocator, "\\u{x:0>4}", .{c}) catch return oom,
            else => out.append(allocator, c) catch return oom,
        }
    }
    out.append(allocator, '"') catch return oom;
}

/// json_decode(text) -> {:ok, value} or {:error, reason}.
///
/// Objects become maps with String keys in document order (a repeated key
/// keeps its last value, as JSON.parse does), arrays become lists, null is
/// nil. A number written as an integer that fits an i64 is an Int; any other
/// number is a Float, so 9223372036854775808 and 1e2 are both Floats.
///
/// An error tuple rather than a raise, unlike every other builtin here: JSON
/// arrives from outside -- a request body, a file someone edited -- and Blimp
/// has no rescue, so a raise would let any client stop the handler reading
/// it. The reason names the error and where it was found, e.g.
/// "SyntaxError at line 2, column 3". A number too large for a Float and
/// nesting deeper than json_max_depth are errors too.
///
/// Raises TypeError only when handed something that is not a String.
fn builtinJsonDecode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    // The parse tree (hash maps, array lists, unescaped strings) is thrown
    // away as soon as it is converted, so it lives in its own arena and not in
    // the evaluator's heap, which would keep it for the rest of the run.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var scanner = std.json.Scanner.initCompleteInput(sa, args[0].string);
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    const tree = std.json.parseFromTokenSourceLeaky(std.json.Value, sa, &scanner, .{
        .duplicate_field_behavior = .use_last,
        .parse_numbers = true,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const msg = std.fmt.allocPrint(allocator, "{s} at line {d}, column {d}", .{
            @errorName(err), diag.getLine(), diag.getColumn(),
        }) catch return error.OutOfMemory;
        return tagged(allocator, "error", try make(allocator, .{ .string = msg }));
    };
    const v = jsonToValue(allocator, tree, 0) catch |err| {
        const msg: []const u8 = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooDeep => std.fmt.comptimePrint("nested deeper than {d} levels", .{json_max_depth}),
            error.NumberOutOfRange => "number out of range for a Float",
        };
        return tagged(allocator, "error", try make(allocator, .{ .string = msg }));
    };
    return tagged(allocator, "ok", v);
}

fn jsonToValue(allocator: std.mem.Allocator, j: std.json.Value, depth: usize) error{ OutOfMemory, TooDeep, NumberOutOfRange }!*const Value {
    if (depth > json_max_depth) return error.TooDeep;
    switch (j) {
        .null => return make(allocator, .nil) catch error.OutOfMemory,
        .bool => |b| return make(allocator, .{ .boolean = b }) catch error.OutOfMemory,
        .integer => |n| return make(allocator, .{ .integer = n }) catch error.OutOfMemory,
        .float => |f| return make(allocator, .{ .float = f }) catch error.OutOfMemory,
        // An integer past i64, or a float past f64 (1e400).
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch return error.NumberOutOfRange;
            if (!std.math.isFinite(f)) return error.NumberOutOfRange;
            return make(allocator, .{ .float = f }) catch error.OutOfMemory;
        },
        .string => |s| {
            const owned = try allocator.dupe(u8, s);
            return make(allocator, .{ .string = owned }) catch error.OutOfMemory;
        },
        .array => |arr| {
            const items = try allocator.alloc(*const Value, arr.items.len);
            for (arr.items, 0..) |item, i| items[i] = try jsonToValue(allocator, item, depth + 1);
            return make(allocator, .{ .list = items }) catch error.OutOfMemory;
        },
        .object => |obj| {
            const entries = try allocator.alloc(Value.MapEntry, obj.count());
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |kv| : (i += 1) {
                entries[i] = .{
                    .key = try allocator.dupe(u8, kv.key_ptr.*),
                    .val = try jsonToValue(allocator, kv.value_ptr.*, depth + 1),
                };
            }
            return make(allocator, .{ .map = entries }) catch error.OutOfMemory;
        },
    }
}

// ── Hashing and encoding ────────────────────────────────
//
// A Blimp String is a byte string, so these take and answer Strings of
// arbitrary bytes: sha256 of a UTF-8 string hashes its UTF-8 bytes, and
// base64_decode can answer bytes that are not text at all.

fn stringArg(v: *const Value) EvalError![]const u8 {
    return if (v.* == .string) v.string else error.TypeError;
}

fn hexLower(allocator: std.mem.Allocator, bytes: []const u8) EvalError!*const Value {
    const digits = "0123456789abcdef";
    const out = allocator.alloc(u8, bytes.len * 2) catch return error.OutOfMemory;
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0x0f];
    }
    return make(allocator, .{ .string = out });
}

/// sha256(s) -> the SHA-256 digest of s's bytes, as 64 lowercase hex digits.
/// Raises TypeError for anything but a String; an atom is not hashed as its
/// name.
fn builtinSha256(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try stringArg(args[0]), &digest, .{});
    return hexLower(allocator, &digest);
}

/// hmac_sha256(key, message) -> HMAC-SHA256 as 64 lowercase hex digits
/// (RFC 2104). A key longer than the 64-byte block is hashed first, as the
/// RFC says. Raises TypeError unless both are Strings.
fn builtinHmacSha256(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, try stringArg(args[1]), try stringArg(args[0]));
    return hexLower(allocator, &mac);
}

/// hex_encode(bytes) -> two lowercase hex digits per byte. TypeError unless
/// a String.
fn builtinHexEncode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    return hexLower(allocator, try stringArg(args[0]));
}

/// hex_decode(hex) -> the bytes two hex digits each stand for, either case:
/// hex_decode(sha256(s)) is the raw digest. Raises TypeError for an odd
/// length or a character that is not a hex digit, as base64_decode does.
fn builtinHexDecode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const hex = try stringArg(args[0]);
    if (hex.len % 2 != 0) return error.TypeError;
    const out = allocator.alloc(u8, hex.len / 2) catch return error.OutOfMemory;
    _ = std.fmt.hexToBytes(out, hex) catch return error.TypeError;
    return make(allocator, .{ .string = out });
}

/// xor_bytes(a, b) -> a String of a's bytes each XORed with b's at the same
/// place. The language has no bitwise operators, and SCRAM authentication
/// (Postgres) folds 4,096 HMACs together with XOR. Raises TypeError unless
/// the two are the same length: XOR of unequal strings has no one answer.
fn builtinXorBytes(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const a = try stringArg(args[0]);
    const b = try stringArg(args[1]);
    if (a.len != b.len) return error.TypeError;
    const out = allocator.alloc(u8, a.len) catch return error.OutOfMemory;
    for (out, a, b) |*o, x, y| o.* = x ^ y;
    return make(allocator, .{ .string = out });
}

fn base64Encode(allocator: std.mem.Allocator, codecs: std.base64.Codecs, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const src = try stringArg(args[0]);
    const out = allocator.alloc(u8, codecs.Encoder.calcSize(src.len)) catch return error.OutOfMemory;
    _ = codecs.Encoder.encode(out, src);
    return make(allocator, .{ .string = out });
}

fn base64Decode(allocator: std.mem.Allocator, codecs: std.base64.Codecs, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const src = try stringArg(args[0]);
    const len = codecs.Decoder.calcSizeForSlice(src) catch return error.TypeError;
    const out = allocator.alloc(u8, len) catch return error.OutOfMemory;
    codecs.Decoder.decode(out, src) catch return error.TypeError;
    return make(allocator, .{ .string = out });
}

/// base64_encode(bytes) -> RFC 4648 base64, `+` and `/`, padded with `=`.
fn builtinBase64Encode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return base64Encode(allocator, std.base64.standard, args);
}

/// base64_decode(text) -> the bytes. Strict: the length must be a multiple
/// of 4 with its `=` padding, only the standard alphabet, no whitespace, and
/// no stray bits in the last character. Anything else is a TypeError, not a
/// best guess at what was meant.
fn builtinBase64Decode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return base64Decode(allocator, std.base64.standard, args);
}

/// base64url_encode(bytes) -> RFC 4648 section 5: `-` and `_`, no padding.
/// The form JWTs, cookies and URLs want.
fn builtinBase64UrlEncode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return base64Encode(allocator, std.base64.url_safe_no_pad, args);
}

/// base64url_decode(text) -> the bytes. As strict as base64_decode: `=`
/// padding, `+` or `/`, or a length that leaves one dangling character is a
/// TypeError.
fn builtinBase64UrlDecode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return base64Decode(allocator, std.base64.url_safe_no_pad, args);
}

/// Write to stdout, ignoring a failure, because a builtin has nowhere to put
/// one: `print` answers its argument and `puts` answers nil.
fn outWrite(bytes: []const u8) void {
    if (is_wasm) return;
    std.Io.File.stdout().writeStreamingAll(ioenv.io, bytes) catch {};
}

/// Same for stderr, which is where a failed assertion goes.
fn errWrite(bytes: []const u8) void {
    if (is_wasm) return;
    std.Io.File.stderr().writeStreamingAll(ioenv.io, bytes) catch {};
}

/// print(value) => prints to stdout, returns the value (identity)
fn builtinPrint(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    // Write to a buffer and print
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    args[0].format(&fbs);
    if (!is_wasm) {
                outWrite(fbs.buffered());
        outWrite("\n");
    }
    return args[0]; // return the value (identity)
}

/// puts(value) -- write to stdout raw, then a newline.
///
/// Unlike `print`, a string is written as its own bytes rather than through
/// `Value.format`, so it arrives unquoted and unescaped, and there is no fixed
/// buffer to truncate it. Non-string values still format the usual way, but
/// stream straight out instead of landing in a 4096-byte buffer first.
fn builtinPuts(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (is_wasm) return args[0];

        switch (args[0].*) {
        .string => |text| outWrite(text),
        else => {
            var buf: [4096]u8 = undefined;
            var fbs = std.Io.Writer.fixed(&buf);
            args[0].format(&fbs);
            outWrite(fbs.buffered());
        },
    }
    outWrite("\n");
    return args[0]; // return the value (identity), like print
}

// ── Test assertion builtins ─────────────────────────────

/// assert(expr) -- fails if expr is falsy (nil, false)
fn builtinAssert(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (!args[0].truthy()) {
                errWrite("\x1b[31mAssertion failed: value is falsy\x1b[0m\n");
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        args[0].format(&fbs);
        errWrite("  got: ");
        errWrite(fbs.buffered());
        errWrite("\n");
        recordAssertionDetail("expected truthy, got {s}", .{fbs.buffered()});
        return error.TypeError; // assertion failure
    }
    return args[0];
}

/// assert_eq(a, b) -- fails if a != b
fn builtinAssertEq(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (!args[0].eql(args[1].*)) {
                errWrite("\x1b[31mAssertion failed: values not equal\x1b[0m\n");
        var left_buf: [256]u8 = undefined;
        var left_fbs = std.Io.Writer.fixed(&left_buf);
        args[0].format(&left_fbs);
        errWrite("  left:  ");
        errWrite(left_fbs.buffered());
        errWrite("\n");
        var right_buf: [256]u8 = undefined;
        var right_fbs = std.Io.Writer.fixed(&right_buf);
        args[1].format(&right_fbs);
        errWrite("  right: ");
        errWrite(right_fbs.buffered());
        errWrite("\n");
        recordAssertionDetail("expected {s}, got {s}", .{ right_fbs.buffered(), left_fbs.buffered() });
        return error.TypeError; // assertion failure
    }
    return args[0];
}

/// assert_ne(a, b) -- fails if a == b
fn builtinAssertNe(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].eql(args[1].*)) {
                errWrite("\x1b[31mAssertion failed: values should not be equal\x1b[0m\n");
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        args[0].format(&fbs);
        errWrite("  both: ");
        errWrite(fbs.buffered());
        errWrite("\n");
        recordAssertionDetail("both sides equal to {s}", .{fbs.buffered()});
        return error.TypeError; // assertion failure
    }
    return args[0];
}

/// refute(expr) -- fails if expr is truthy
fn builtinRefute(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (args[0].truthy()) {
                errWrite("\x1b[31mRefute failed: value is truthy\x1b[0m\n");
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        args[0].format(&fbs);
        errWrite("  got: ");
        errWrite(fbs.buffered());
        errWrite("\n");
        recordAssertionDetail("expected falsy, got {s}", .{fbs.buffered()});
        return error.TypeError; // assertion failure
    }
    return args[0];
}

// ── Math and utility builtins ───────────────────────────

/// rem(10, 3) => 1 (integer remainder)
fn builtinRem(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .integer) return error.TypeError;
    if (args[1].integer == 0) return error.DivisionByZero;
    return make(allocator, .{ .integer = @rem(args[0].integer, args[1].integer) });
}

/// abs(-5) => 5
fn builtinAbs(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        // abs(minInt) has no i64 answer; wrap to minInt, as the operators do.
        .integer => |n| result.* = Value{ .integer = if (n < 0) 0 -% n else n },
        .float => |f| result.* = Value{ .float = if (f < 0) -f else f },
        else => return error.TypeError,
    }
    return result;
}

/// nil?(nil) => true, nil?(42) => false
fn builtinIsNil(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    return make(allocator, .{ .boolean = args[0].* == .nil });
}

/// elem({10, 20, 30}, 1) => 20 (0-indexed tuple access)
fn builtinElem(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[1].* != .integer) return error.TypeError;
    const idx: usize = @intCast(@max(args[1].integer, 0));
    switch (args[0].*) {
        .tuple => |items| {
            if (idx >= items.len) {
                return make(allocator, .nil);
            }
            return items[idx];
        },
        .list => |items| {
            if (idx >= items.len) {
                return make(allocator, .nil);
            }
            return items[idx];
        },
        else => return error.TypeError,
    }
}

// ── Float maths ──────────────────────────────────────

/// The float functions Blimp did not have.
///
/// The numeric builtins stopped at floor, ceil, round and abs, so anything
/// that wanted a square root had to fake one. temper-core, the Temper
/// backend's runtime, spelled `**` as repeated multiplication and gave up on a
/// fractional exponent: `4.0 ** -0.5` raised instead of answering 0.5.
///
/// Each takes a Float or an Int -- an Int answer would be wrong for all of
/// them anyway -- and returns a Float.
fn floatArg(v: *const Value) EvalError!f64 {
    return switch (v.*) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => error.TypeError,
    };
}

fn unaryFloat(comptime f: fn (f64) f64) BuiltinFn {
    return &struct {
        fn call(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
            if (args.len != 1) return error.TypeError;
            return make(allocator, .{ .float = f(try floatArg(args[0])) });
        }
    }.call;
}

const float_fns = .{
    .{ "sqrt", struct {
        fn f(x: f64) f64 {
            return @sqrt(x);
        }
    }.f },
    .{ "exp", struct {
        fn f(x: f64) f64 {
            return @exp(x);
        }
    }.f },
    .{ "expm1", struct {
        fn f(x: f64) f64 {
            return std.math.expm1(x);
        }
    }.f },
    .{ "log", struct {
        fn f(x: f64) f64 {
            return @log(x);
        }
    }.f },
    .{ "log1p", struct {
        fn f(x: f64) f64 {
            return std.math.log1p(x);
        }
    }.f },
    .{ "log2", struct {
        fn f(x: f64) f64 {
            return @log2(x);
        }
    }.f },
    .{ "log10", struct {
        fn f(x: f64) f64 {
            return @log10(x);
        }
    }.f },
    .{ "sin", struct {
        fn f(x: f64) f64 {
            return @sin(x);
        }
    }.f },
    .{ "cos", struct {
        fn f(x: f64) f64 {
            return @cos(x);
        }
    }.f },
    .{ "tan", struct {
        fn f(x: f64) f64 {
            return @tan(x);
        }
    }.f },
    .{ "asin", struct {
        fn f(x: f64) f64 {
            return std.math.asin(x);
        }
    }.f },
    .{ "acos", struct {
        fn f(x: f64) f64 {
            return std.math.acos(x);
        }
    }.f },
    .{ "atan", struct {
        fn f(x: f64) f64 {
            return std.math.atan(x);
        }
    }.f },
    .{ "sinh", struct {
        fn f(x: f64) f64 {
            return std.math.sinh(x);
        }
    }.f },
    .{ "cosh", struct {
        fn f(x: f64) f64 {
            return std.math.cosh(x);
        }
    }.f },
    .{ "tanh", struct {
        fn f(x: f64) f64 {
            return std.math.tanh(x);
        }
    }.f },
};

/// pow(2.0, 10.0) => 1024.0.  Whole or fractional, positive or negative.
fn builtinPow(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const base = try floatArg(args[0]);
    const exponent = try floatArg(args[1]);
    return make(allocator, .{ .float = std.math.pow(f64, base, exponent) });
}

/// atan2(y, x), the angle of the point (x, y) with the sign of both.
fn builtinAtan2(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const y = try floatArg(args[0]);
    const x = try floatArg(args[1]);
    return make(allocator, .{ .float = std.math.atan2(y, x) });
}

/// floor(3.7) => 3
fn builtinFloor(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .float => |f| result.* = Value{ .integer = @intFromFloat(@floor(f)) },
        .integer => return args[0],
        else => return error.TypeError,
    }
    return result;
}

/// ceil(3.2) => 4
fn builtinCeil(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .float => |f| result.* = Value{ .integer = @intFromFloat(@ceil(f)) },
        .integer => return args[0],
        else => return error.TypeError,
    }
    return result;
}

/// round(3.5) => 4
fn builtinRound(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .float => |f| result.* = Value{ .integer = @intFromFloat(@round(f)) },
        .integer => return args[0],
        else => return error.TypeError,
    }
    return result;
}

// ── Logic and collection builtins ───────────────────────

/// not(true) => false
fn builtinNot(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    return make(allocator, .{ .boolean = !args[0].truthy() });
}

/// size(collection) => length (alias for length)
fn builtinSize(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return builtinLength(allocator, args);
}

/// empty?([]) => true, empty?([1]) => false
fn builtinIsEmpty(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .boolean = switch (args[0].*) {
        .list => |items| items.len == 0,
        .map => |entries| entries.len == 0,
        .string => |s| s.len == 0,
        .nil => true,
        else => false,
    } };
    return result;
}

/// flat([[1,2],[3,4]]) => [1,2,3,4]
fn builtinFlat(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    var items: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
    for (args[0].list) |item| {
        if (item.* == .list) {
            for (item.list) |inner| {
                items.append(allocator, inner) catch return error.OutOfMemory;
            }
        } else {
            items.append(allocator, item) catch return error.OutOfMemory;
        }
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

/// zip([1,2,3], [:a,:b,:c]) => [{1,:a},{2,:b},{3,:c}]
fn builtinZip(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .list or args[1].* != .list) return error.TypeError;
    const a = args[0].list;
    const b = args[1].list;
    const len = @min(a.len, b.len);
    var items = allocator.alloc(*const Value, len) catch return error.OutOfMemory;
    for (0..len) |i| {
        const pair = allocator.alloc(*const Value, 2) catch return error.OutOfMemory;
        pair[0] = a[i];
        pair[1] = b[i];
        const tuple_val = allocator.create(Value) catch return error.OutOfMemory;
        tuple_val.* = Value{ .tuple = pair };
        items[i] = tuple_val;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

/// uniq([1,2,1,3,2]) => [1,2,3]
fn builtinUniq(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    var items: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
    for (args[0].list) |item| {
        var found = false;
        for (items.items) |existing| {
            if (existing.eql(item.*)) {
                found = true;
                break;
            }
        }
        if (!found) items.append(allocator, item) catch return error.OutOfMemory;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

/// set_at(list, index, value) => new list with element at index replaced
fn builtinSetAt(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3 or args[0].* != .list or args[1].* != .integer) return error.TypeError;
    const items = args[0].list;
    const idx: usize = @intCast(@max(args[1].integer, 0));
    if (idx >= items.len) return error.TypeError;
    const new_items = allocator.dupe(*const Value, items) catch return error.OutOfMemory;
    new_items[idx] = args[2];
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = new_items };
    return result;
}

/// sum([1,2,3]) => 6
fn builtinSum(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    var total: i64 = 0;
    for (args[0].list) |item| {
        if (item.* == .integer) total +%= item.integer;
    }
    return make(allocator, .{ .integer = total });
}

/// random(min, max) => random integer in [min, max] inclusive
var random_state: u64 = 0x853c49e6748fea9b;

fn builtinRandom(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .integer) return error.TypeError;
    const min_val = args[0].integer;
    const max_val = args[1].integer;
    if (max_val < min_val) return error.TypeError;

    // xorshift64
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;

    const range: u64 = @intCast(max_val - min_val + 1);
    const val = min_val + @as(i64, @intCast(random_state % range));

    return make(allocator, .{ .integer = val });
}

/// seed(n: Int) -> :ok
/// Reseeds the xorshift generator behind random/2. The same seed replays the
/// same sequence, which is what tests want; hosts that want a fresh game
/// every load pass the clock in (tetris.html does seed(Date.now())).
fn builtinSeed(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (args[0].* != .integer) return error.TypeError;
    // xorshift is stuck at zero forever, so mix the seed with a nonzero
    // constant (splitmix-style) instead of storing it raw.
    const raw: u64 = @bitCast(args[0].integer);
    var z = raw +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    z ^= z >> 31;
    random_state = if (z == 0) 0x853c49e6748fea9b else z;

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = "ok" };
    return result;
}

test "seed makes random reproducible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lo = try alloc.create(Value);
    lo.* = Value{ .integer = 1 };
    const hi = try alloc.create(Value);
    hi.* = Value{ .integer = 1_000_000 };
    const range_args = try alloc.alloc(*const Value, 2);
    range_args[0] = lo;
    range_args[1] = hi;

    const n = try alloc.create(Value);
    n.* = Value{ .integer = 42 };
    const seed_args = try alloc.alloc(*const Value, 1);
    seed_args[0] = n;

    const ok = try builtinSeed(alloc, seed_args);
    try std.testing.expect(ok.eql(Value{ .atom = "ok" }));
    const a1 = (try builtinRandom(alloc, range_args)).integer;
    const a2 = (try builtinRandom(alloc, range_args)).integer;
    _ = try builtinSeed(alloc, seed_args);
    const b1 = (try builtinRandom(alloc, range_args)).integer;
    const b2 = (try builtinRandom(alloc, range_args)).integer;
    try std.testing.expectEqual(a1, b1);
    try std.testing.expectEqual(a2, b2);

    // a different seed gives a different first draw
    n.* = Value{ .integer = 43 };
    _ = try builtinSeed(alloc, seed_args);
    const c1 = (try builtinRandom(alloc, range_args)).integer;
    try std.testing.expect(c1 != a1);
}

test "seed zero does not wedge xorshift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = try alloc.create(Value);
    n.* = Value{ .integer = 0 };
    const seed_args = try alloc.alloc(*const Value, 1);
    seed_args[0] = n;
    _ = try builtinSeed(alloc, seed_args);

    const lo = try alloc.create(Value);
    lo.* = Value{ .integer = 0 };
    const hi = try alloc.create(Value);
    hi.* = Value{ .integer = 1_000_000 };
    const range_args = try alloc.alloc(*const Value, 2);
    range_args[0] = lo;
    range_args[1] = hi;
    var saw_nonzero = false;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if ((try builtinRandom(alloc, range_args)).integer != 0) saw_nonzero = true;
    }
    try std.testing.expect(saw_nonzero);
}

test "seed rejects bad args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const s = try alloc.create(Value);
    s.* = Value{ .string = "42" };
    const one = try alloc.alloc(*const Value, 1);
    one[0] = s;
    try std.testing.expectError(error.TypeError, builtinSeed(alloc, one));
    const none = try alloc.alloc(*const Value, 0);
    try std.testing.expectError(error.TypeError, builtinSeed(alloc, none));
}

// ============================================================
// File I/O builtins
// ============================================================

/// write_bytes(path: String, bytes: List of Int) -> :ok
/// Writes a list of byte values (0-255) to a file.
fn builtinWriteBytes(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .list) return error.TypeError;
    const path = args[0].string;
    const byte_list = args[1].list;

    // Convert list of integers to byte array
    const buf = allocator.alloc(u8, byte_list.len) catch return error.OutOfMemory;
    for (byte_list, 0..) |val, i| {
        if (val.* != .integer) return error.TypeError;
        buf[i] = @intCast(@max(0, @min(255, val.integer)));
    }

    // Write to file
    if (is_wasm) {
        return error.NotSupported;
    }
    const file = std.Io.Dir.cwd().createFile(ioenv.io, path, .{}) catch return error.NotSupported;
    defer file.close(ioenv.io);
    file.writeStreamingAll(ioenv.io, buf) catch return error.NotSupported;

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = "ok" };
    return result;
}

/// write_file("out.txt", "text") => true, or false if it could not be written.
///
/// `read_file` has been here on its own, and `write_bytes` wants a list of
/// integers, so writing a string meant converting it a character at a time.
///
/// The three file builtins have three answers for failure: this one is false,
/// `read_file` is nil, and `write_bytes` raises. Matching one of them would
/// have meant mismatching the others.
fn builtinWriteFile(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .string) return error.TypeError;
    if (is_wasm) return error.NotSupported;
    const file = std.Io.Dir.cwd().createFile(ioenv.io, args[0].string, .{}) catch {
        return make(allocator, .{ .boolean = false });
    };
    defer file.close(ioenv.io);
    file.writeStreamingAll(ioenv.io, args[1].string) catch {
        return make(allocator, .{ .boolean = false });
    };
    return make(allocator, .{ .boolean = true });
}

/// The largest file read_file will hold in memory.
const read_file_limit = 64 * 1024 * 1024;

/// read_file(path: String) -> String, or nil when it cannot be read.
///
/// A file larger than read_file_limit (64 MiB) raises NotSupported instead.
/// The limit was 1 MiB and a file past it answered nil, the same nil as a
/// missing file, so a 1.1 MiB image or JSON dump looked like it was not
/// there at all.
fn builtinReadFile(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    if (is_wasm) return error.NotSupported;
    const path = args[0].string;
    const content = std.Io.Dir.cwd().readFileAlloc(ioenv.io, path, allocator, .limited(read_file_limit)) catch |err| {
        if (err == error.StreamTooLong) return error.NotSupported;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return make(allocator, .nil);
    };
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = content };
    return result;
}

/// list_dir(path) -> the names in a directory, sorted by their bytes, without
/// "." and "..", or nil when it cannot be opened (missing, not a directory,
/// no permission) -- the same nil read_file answers.
///
/// Sorted because the OS order is whatever the file system keeps: APFS and
/// ext4 answer the same directory in different orders, and a site that
/// builds its post list from list_dir would reorder itself between laptop
/// and server. Names only, not paths; kinds are not reported.
fn builtinListDir(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    if (is_wasm) return error.NotSupported;
    var dir = std.Io.Dir.cwd().openDir(ioenv.io, args[0].string, .{ .iterate = true }) catch {
        return make(allocator, .nil);
    };
    defer dir.close(ioenv.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(ioenv.io) catch return make(allocator, .nil)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        // `entry.name` points into the iterator's buffer and is gone at the
        // next call, so it is copied before the loop moves on.
        const owned = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
        names.append(allocator, owned) catch return error.OutOfMemory;
    }
    std.sort.pdq([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const items = allocator.alloc(*const Value, names.items.len) catch return error.OutOfMemory;
    for (names.items, 0..) |name, i| items[i] = try make(allocator, .{ .string = name });
    return make(allocator, .{ .list = items });
}

/// file_exists?(path) -> true when something is there to stat: a file, a
/// directory, or a symlink that resolves. A dangling symlink, or a path the
/// process may not look into, is false.
fn builtinFileExists(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    if (is_wasm) return error.NotSupported;
    _ = std.Io.Dir.cwd().statFile(ioenv.io, args[0].string, .{}) catch {
        return make(allocator, .{ .boolean = false });
    };
    return make(allocator, .{ .boolean = true });
}

/// file_size(path) -> the size in bytes of the regular file at path
/// (following symlinks), or nil when there is none. A directory is nil too:
/// its "size" is a file-system detail, not the size of anything a program
/// could read.
fn builtinFileSize(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    if (is_wasm) return error.NotSupported;
    const st = std.Io.Dir.cwd().statFile(ioenv.io, args[0].string, .{}) catch {
        return make(allocator, .nil);
    };
    if (st.kind != .file) return make(allocator, .nil);
    return make(allocator, .{ .integer = @intCast(st.size) });
}

// ============================================================
// Property-based testing generators
// ============================================================

fn nextRandom() u64 {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;
    return random_state;
}

/// gen_integer(min, max) -> random Int in [min, max]
fn builtinGenInteger(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .integer or args[1].* != .integer) return error.TypeError;
    const lo = args[0].integer;
    const hi = args[1].integer;
    const range: u64 = @intCast(@max(hi - lo + 1, 1));
    const val = lo + @as(i64, @intCast(nextRandom() % range));
    return make(allocator, .{ .integer = val });
}

/// gen_string(max_len) -> random String of printable ASCII
fn builtinGenString(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const max_len: usize = @intCast(@max(0, args[0].integer));
    const len: usize = @intCast(nextRandom() % (max_len + 1));
    const buf = allocator.alloc(u8, len) catch return error.OutOfMemory;
    for (buf) |*c| {
        c.* = @intCast(32 + nextRandom() % 95); // printable ASCII 32-126
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf };
    return result;
}

/// gen_boolean() -> random true or false
fn builtinGenBoolean(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    return make(allocator, .{ .boolean = nextRandom() % 2 == 0 });
}

/// gen_list(gen_fn_name_not_used, max_len) -> random list of integers
/// For now generates lists of random integers. Full generator composition later.
fn builtinGenList(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    // gen_list(max_len) or gen_list(max_len, min_val, max_val)
    if (args.len < 1 or args[0].* != .integer) return error.TypeError;
    const max_len: usize = @intCast(@max(0, args[0].integer));
    const min_val: i64 = if (args.len >= 2 and args[1].* == .integer) args[1].integer else -100;
    const max_val: i64 = if (args.len >= 3 and args[2].* == .integer) args[2].integer else 100;
    const len: usize = @intCast(nextRandom() % (max_len + 1));
    const items = allocator.alloc(*const Value, len) catch return error.OutOfMemory;
    const range: u64 = @intCast(@max(max_val - min_val + 1, 1));
    for (items) |*item| {
        const v = allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .integer = min_val + @as(i64, @intCast(nextRandom() % range)) };
        item.* = v;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

/// gen_one_of([a, b, c]) -> random element from the list
fn builtinGenOneOf(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    const items = args[0].list;
    if (items.len == 0) {
        return make(allocator, .nil);
    }
    const idx: usize = @intCast(nextRandom() % items.len);
    return items[idx];
}

// ============================================================
// View primitive helpers
// ============================================================

const ViewAttr = Value.ViewNode.ViewAttr;

/// Build a view_node with the given tag, attrs, and variadic children.
/// If any child is a list, its elements are flattened into the children array.
/// This allows `stack(map(items, fn(x) do text(x) end))` to work naturally.
fn makeViewNode(allocator: std.mem.Allocator, tag: []const u8, attrs: []const ViewAttr, children: []const *const Value) EvalError!*const Value {
    const node_attrs = allocator.dupe(ViewAttr, attrs) catch return error.OutOfMemory;
    // Count total children after flattening lists
    var total: usize = 0;
    for (children) |child| {
        switch (child.*) {
            .list => |items| {
                total += items.len;
            },
            else => {
                total += 1;
            },
        }
    }
    // Build flattened children array
    const node_children = allocator.alloc(*const Value, total) catch return error.OutOfMemory;
    var idx: usize = 0;
    for (children) |child| {
        switch (child.*) {
            .list => |items| {
                for (items) |item| {
                    node_children[idx] = item;
                    idx += 1;
                }
            },
            else => {
                node_children[idx] = child;
                idx += 1;
            },
        }
    }
    const node = allocator.create(Value.ViewNode) catch return error.OutOfMemory;
    node.* = .{ .tag = tag, .attrs = node_attrs, .children = node_children };
    return make(allocator, .{ .view_node = node });
}

/// stack(child, child, ...) — vertical flex container, variadic children
fn viewStack(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "stack", &.{}, args);
}

/// row(child, child, ...) — horizontal flex container, variadic children
fn viewRow(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "row", &.{}, args);
}

/// grid(child, child, ...) — grid container, variadic children
fn viewGrid(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "grid", &.{}, args);
}

/// text("content") — inline text node
fn viewText(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "text", &.{}, args[0..1]);
}

/// heading("content", level) — h1-h6. Level defaults to 1 if omitted.
fn viewHeading(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    const level: i64 = if (args.len == 2 and args[1].* == .integer) args[1].integer else 1;
    const level_val = allocator.create(Value) catch return error.OutOfMemory;
    level_val.* = Value{ .integer = level };
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "level", .val = level_val };
    return makeViewNode(allocator, "heading", attrs, args[0..1]);
}

/// bold("content") — bold/strong text
fn viewBold(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "bold", &.{}, args[0..1]);
}

/// italic("content") — italic/em text
fn viewItalic(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "italic", &.{}, args[0..1]);
}

/// code("content") — inline code span
fn viewCode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "code", &.{}, args[0..1]);
}

/// code_block("content") — fenced code block, optional lang atom
fn viewCodeBlock(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    if (args.len == 2) {
        if (args[1].* != .atom) return error.TypeError;
        const attrs = try allocator.alloc(ViewAttr, 1);
        attrs[0] = .{ .key = "lang", .val = args[1] };
        return makeViewNode(allocator, "code_block", attrs, args[0..1]);
    }
    return makeViewNode(allocator, "code_block", &.{}, args[0..1]);
}

/// blockquote("content") — block quote
fn viewBlockquote(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "blockquote", &.{}, args[0..1]);
}

/// divider() — horizontal rule
fn viewDivider(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    return makeViewNode(allocator, "divider", &.{}, &.{});
}

/// list(item, item, ...) — unordered list with variadic items
fn viewList(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "list", &.{}, args);
}

/// link("label", "url") — anchor link
fn viewLink(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "href", .val = args[1] };
    return makeViewNode(allocator, "link", attrs, args[0..1]);
}

/// image("src", "alt") — img embed, alt optional
fn viewImage(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    if (args.len == 2) {
        if (args[1].* != .string) return error.TypeError;
        const attrs = try allocator.alloc(ViewAttr, 2);
        attrs[0] = .{ .key = "src", .val = args[0] };
        attrs[1] = .{ .key = "alt", .val = args[1] };
        return makeViewNode(allocator, "image", attrs, &.{});
    }
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "src", .val = args[0] };
    return makeViewNode(allocator, "image", attrs, &.{});
}

/// video("src") — video embed
fn viewVideo(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "src", .val = args[0] };
    return makeViewNode(allocator, "video", attrs, &.{});
}

/// canvas("id") — canvas element for 2D drawing
fn viewCanvas(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "id", .val = args[0] };
    return makeViewNode(allocator, "canvas", attrs, &.{});
}

/// draw(width, height, ops) — a canvas the host paints from `ops`, a display
/// list with one shape per line:
///
///     rect x y w h fill              circle x y r fill
///     line x1 y1 x2 y2 stroke width  text x y size fill align words...
///     alpha a                        shadow blur color   (both apply to
///                                                         the lines after)
///
/// A fill is a CSS color, or `v:#c1,#c2,...` / `h:#c1,#c2,...` for a
/// vertical or horizontal gradient across the shape. The view is a value,
/// so a game draws a frame by returning it; the host keeps one canvas and
/// repaints it, and fails, naming the line, on a shape it does not know.
fn viewDraw(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .integer or args[2].* != .string) return error.TypeError;
    if (args[0].integer <= 0 or args[1].integer <= 0) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 3);
    attrs[0] = .{ .key = "width", .val = args[0] };
    attrs[1] = .{ .key = "height", .val = args[1] };
    attrs[2] = .{ .key = "ops", .val = args[2] };
    return makeViewNode(allocator, "draw", attrs, &.{});
}

/// The elements el() may make. Nothing that loads or runs a document of its
/// own (script, iframe, object, embed, style, link, meta, base).
const el_tags = [_][]const u8{
    "div",    "span",   "p",      "a",       "button",  "h1",     "h2",       "h3",         "h4",      "h5",
    "h6",     "ul",     "ol",     "li",      "img",     "table",  "thead",    "tbody",      "tfoot",   "tr",
    "td",     "th",     "input",  "textarea", "select", "option", "form",     "label",      "section", "header",
    "footer", "nav",    "main",   "article", "aside",   "strong", "em",       "b",          "i",       "u",
    "s",      "small",  "code",   "pre",     "blockquote", "hr",  "br",       "figure",     "figcaption", "details",
    "summary", "kbd",   "sup",    "sub",     "dl",      "dt",     "dd",       "time",       "mark",    "abbr",
    "canvas", "video",  "audio",  "source",  "svg",     "g",      "path",     "circle",     "rect",    "line",
    "polyline", "polygon", "text", "tspan",  "defs",    "linearGradient", "radialGradient", "stop", "ellipse", "title",
};

/// Attr keys el() takes as instructions for the host, not as HTML.
const el_event_keys = [_][]const u8{ "click", "with", "input", "change", "submit", "swipe", "select", "selection", "debounce", "shortcut", "shortcut_keys", "paste_image", "inner_html" };

fn isElEventKey(key: []const u8) bool {
    for (el_event_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

fn isUrlAttr(key: []const u8) bool {
    return std.mem.eql(u8, key, "href") or std.mem.eql(u8, key, "src") or std.mem.eql(u8, key, "action") or
        std.mem.eql(u8, key, "formaction") or std.mem.eql(u8, key, "xlink:href") or std.mem.eql(u8, key, "poster");
}

/// "javascript:" however it is spelled: leading spaces and control
/// characters skipped, any case, as a browser reads it.
fn isScriptUrl(v: []const u8) bool {
    var i: usize = 0;
    while (i < v.len and v[i] <= ' ') i += 1;
    const rest = v[i..];
    return rest.len >= 11 and std.ascii.eqlIgnoreCase(rest[0..11], "javascript:");
}

/// A value as Blimp source, for `with:`: the host sends it back as the
/// message's argument, `app <- :set_size(8)`.
fn blimpSource(allocator: std.mem.Allocator, v: *const Value) EvalError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    switch (v.*) {
        .integer => |n| out.print(allocator, "{d}", .{n}) catch return error.OutOfMemory,
        .float => |f| out.print(allocator, "{d}", .{f}) catch return error.OutOfMemory,
        .boolean => |b| out.appendSlice(allocator, if (b) "true" else "false") catch return error.OutOfMemory,
        .nil => out.appendSlice(allocator, "nil") catch return error.OutOfMemory,
        .atom => |a| {
            out.append(allocator, ':') catch return error.OutOfMemory;
            out.appendSlice(allocator, a) catch return error.OutOfMemory;
        },
        .string => |str| {
            out.append(allocator, '"') catch return error.OutOfMemory;
            var i: usize = 0;
            while (i < str.len) : (i += 1) {
                const c = str[i];
                switch (c) {
                    '"' => out.appendSlice(allocator, "\\\"") catch return error.OutOfMemory,
                    '\\' => out.appendSlice(allocator, "\\\\") catch return error.OutOfMemory,
                    '\n' => out.appendSlice(allocator, "\\n") catch return error.OutOfMemory,
                    '\t' => out.appendSlice(allocator, "\\t") catch return error.OutOfMemory,
                    '#' => out.appendSlice(allocator, if (i + 1 < str.len and str[i + 1] == '{') "\\#" else "#") catch return error.OutOfMemory,
                    else => out.append(allocator, c) catch return error.OutOfMemory,
                }
            }
            out.append(allocator, '"') catch return error.OutOfMemory;
        },
        else => return error.TypeError,
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// el("div", %{class: "board", click: :new_game}, child, child, ...)
///
/// A real HTML (or SVG) element, so a page keeps its own markup and CSS.
/// Attrs are HTML attributes, except five the host acts on:
///
///     click: :msg        a click sends the actor :msg
///     with: value        ... as :msg(value)  (Int, Float, Bool, Atom, String)
///     input: :msg        every keystroke sends :msg(the field's value)
///     change: :msg       :msg(value), or :msg(checked) for a checkbox
///     submit: :msg       :msg(the form's fields as a JSON string)
///     swipe: :msg        a finger moved 12px one way: :msg(:left), :right, :up
///                        or :down, and the page does not scroll
///     debounce: ms       input: waits until typing pauses this long
///     select: :msg       a field's selection moved: :msg(start, end), in
///                        bytes of its value, as Blimp's strings count
///     selection: "s,e"   put the field's selection there (bytes), when this
///                        attr changes, and focus it
///     shortcut: :msg     Ctrl or Cmd plus one of shortcut_keys ("bik")
///                        sends :msg("b"); other shortcuts are left alone
///     paste_image: :msg  an image pasted or dropped: :msg(its data: URL)
///     inner_html: html   the element's content, as markup (a rendered
///                        preview); not escaped, so only for HTML the program
///                        made itself
///
/// An attr whose value is nil or false is left off; true is written bare.
/// Refused with TypeError: a tag not in el_tags, an on* attr, and a URL
/// attr that is a javascript: URL. Children are variadic, lists flattened.
fn viewEl(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 2 or args[0].* != .string) return error.TypeError;
    const tag = args[0].string;
    var known = false;
    for (el_tags) |t| if (std.mem.eql(u8, t, tag)) {
        known = true;
    };
    if (!known) return error.TypeError;
    const entries: []const Value.MapEntry = switch (args[1].*) {
        .map => |m| m,
        .nil => &.{},
        else => return error.TypeError,
    };
    const attrs = allocator.alloc(ViewAttr, entries.len + 1) catch return error.OutOfMemory;
    attrs[0] = .{ .key = "@tag", .val = args[0] };
    for (entries, 0..) |e, i| {
        if (e.key.len >= 2 and std.ascii.eqlIgnoreCase(e.key[0..2], "on")) return error.TypeError;
        if (e.key.len == 0 or e.key[0] == '@') return error.TypeError;
        switch (e.val.*) {
            .string => |v| if (isUrlAttr(e.key) and isScriptUrl(v)) return error.TypeError,
            .integer, .float, .boolean, .nil, .atom => {},
            else => return error.TypeError,
        }
        if (std.mem.eql(u8, e.key, "with")) {
            const src = try allocator.create(Value);
            src.* = .{ .string = try blimpSource(allocator, e.val) };
            attrs[i + 1] = .{ .key = e.key, .val = src };
        } else {
            attrs[i + 1] = .{ .key = e.key, .val = e.val };
        }
    }
    return makeViewNode(allocator, "el", attrs, args[2..]);
}

/// button("label", sends_atom) — clickable button that sends a message to the actor
fn viewButton(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    if (args.len == 2) {
        if (args[1].* != .atom) return error.TypeError;
        const attrs = try allocator.alloc(ViewAttr, 1);
        attrs[0] = .{ .key = "sends", .val = args[1] };
        return makeViewNode(allocator, "button", attrs, args[0..1]);
    }
    return makeViewNode(allocator, "button", &.{}, args[0..1]);
}

/// fetch(url, :msg) — effect node: the host GETs `url` (same origin, a path)
/// once while this node is in the view, and sends :msg(status, body), body
/// as a String; status 0 if the request failed. A view that stops asking and
/// asks again gets it again. How a program in the browser reads data from
/// its server: the view says what it needs.
fn viewFetch(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .atom) return error.TypeError;
    const url = args[0].string;
    // a path on the page's own server: not another origin, not a scheme
    if (url.len == 0 or url[0] != '/' or (url.len > 1 and url[1] == '/')) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 2);
    attrs[0] = .{ .key = "url", .val = args[0] };
    attrs[1] = .{ .key = "sends", .val = args[1] };
    return makeViewNode(allocator, "fetch", attrs, &.{});
}

/// stored("aim.name", :msg) — effect node: the host reads `key` from the
/// browser's storage (localStorage) once while this node is in the view
/// and sends :msg(value), "" if nothing is stored. How a page remembers
/// something between visits; store() writes it.
fn viewStored(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .atom or args[0].string.len == 0) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 2);
    attrs[0] = .{ .key = "key", .val = args[0] };
    attrs[1] = .{ .key = "sends", .val = args[1] };
    return makeViewNode(allocator, "stored", attrs, &.{});
}

/// store("aim.name", "alice") — effect node: the browser's storage holds
/// `value` under `key` for as long as the view says so; "" removes it.
/// Written when it differs from what is there, so rendering it every time
/// costs nothing.
fn viewStore(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .string or args[0].string.len == 0) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 2);
    attrs[0] = .{ .key = "key", .val = args[0] };
    attrs[1] = .{ .key = "value", .val = args[1] };
    return makeViewNode(allocator, "store", attrs, &.{});
}

/// location_query("year=2023&song=Tweezer") — effect node: the page's URL
/// carries this query string (replaced, not pushed: no history entry per
/// click), so the page can be linked to in the state it is in.
fn viewLocationQuery(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "query", .val = args[0] };
    return makeViewNode(allocator, "location_query", attrs, &.{});
}

/// timer(ms, sends_atom) — effect node: while mounted, the host sends the atom every ms milliseconds
fn viewTimer(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .atom) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 2);
    attrs[0] = .{ .key = "ms", .val = args[0] };
    attrs[1] = .{ .key = "sends", .val = args[1] };
    return makeViewNode(allocator, "timer", attrs, &.{});
}

/// key("ArrowLeft", sends_atom) — effect node: while mounted, that KeyboardEvent.key sends the atom
/// key("*", :msg) — every key the page gets, as :msg("a"), :msg("Enter"), ...
/// key("ArrowUp", :down_atom, :up_atom) — a key that is held: the first atom
/// when it goes down (the keyboard's auto-repeat is not sent again), the
/// second when it comes up. A paddle moves while the key is held.
fn viewKey(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 and args.len != 3) return error.TypeError;
    if (args[0].* != .string or args[1].* != .atom) return error.TypeError;
    if (args.len == 3 and args[2].* != .atom) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, args.len);
    attrs[0] = .{ .key = "code", .val = args[0] };
    attrs[1] = .{ .key = "sends", .val = args[1] };
    if (args.len == 3) attrs[2] = .{ .key = "up", .val = args[2] };
    return makeViewNode(allocator, "key", attrs, &.{});
}

/// input("name", "placeholder") — text input field
/// input("name", "placeholder", :type) — typed input (e.g. :password, :email, :number)
fn viewInput(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 2 or args.len > 3) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    var attr_count: usize = 2;
    if (args.len == 3) {
        if (args[2].* != .atom) return error.TypeError;
        attr_count = 3;
    }
    const attrs = try allocator.alloc(ViewAttr, attr_count);
    attrs[0] = .{ .key = "name", .val = args[0] };
    attrs[1] = .{ .key = "placeholder", .val = args[1] };
    if (args.len == 3) {
        attrs[2] = .{ .key = "type", .val = args[2] };
    }
    return makeViewNode(allocator, "input", attrs, &.{});
}

/// textarea("name", "placeholder") — multi-line text input
fn viewTextarea(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 2);
    attrs[0] = .{ .key = "name", .val = args[0] };
    attrs[1] = .{ .key = "placeholder", .val = args[1] };
    return makeViewNode(allocator, "textarea", attrs, &.{});
}

/// select("name", option1, option2, ...) — dropdown select with option children
fn viewSelect(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "name", .val = args[0] };
    // remaining args are option children
    const children = if (args.len > 1) args[1..] else &[_]*const Value{};
    return makeViewNode(allocator, "select", attrs, children);
}

/// option("label", "value") — option inside a select
fn viewOption(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "value", .val = args[1] };
    return makeViewNode(allocator, "option_elem", attrs, args[0..1]);
}

/// form(children...) — form wrapper that collects inputs on submit
fn viewForm(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "form", &.{}, args);
}

/// mount_root("ActorName", view_node) — wraps a child actor's view in a mount boundary
fn viewMountRoot(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    if (args[1].* != .view_node) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "data-actor", .val = args[0] };
    return makeViewNode(allocator, "mount", attrs, args[1..2]);
}

// ============================================================
// Tests
// ============================================================

test "builtin length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v1 = try alloc.create(Value);
    v1.* = Value{ .integer = 10 };
    const v2 = try alloc.create(Value);
    v2.* = Value{ .integer = 20 };
    const items = try alloc.alloc(*const Value, 2);
    items[0] = v1;
    items[1] = v2;
    const list_val = try alloc.create(Value);
    list_val.* = Value{ .list = items };

    const args = try alloc.alloc(*const Value, 1);
    args[0] = list_val;
    const result = try builtinLength(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 2 }));
}

test "builtin max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try alloc.create(Value);
    a.* = Value{ .integer = 5 };
    const b = try alloc.create(Value);
    b.* = Value{ .integer = 10 };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = a;
    args[1] = b;
    const result = try builtinMax(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 10 }));
}

test "builtin min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try alloc.create(Value);
    a.* = Value{ .integer = 5 };
    const b = try alloc.create(Value);
    b.* = Value{ .integer = 10 };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = a;
    args[1] = b;
    const result = try builtinMin(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 5 }));
}

test "builtin append" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v1 = try alloc.create(Value);
    v1.* = Value{ .integer = 1 };
    const items = try alloc.alloc(*const Value, 1);
    items[0] = v1;
    const list_val = try alloc.create(Value);
    list_val.* = Value{ .list = items };

    const v2 = try alloc.create(Value);
    v2.* = Value{ .integer = 2 };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = list_val;
    args[1] = v2;
    const result = try builtinAppend(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expectEqual(@as(usize, 2), result.list.len);
}

test "builtin reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v1 = try alloc.create(Value);
    v1.* = Value{ .integer = 1 };
    const v2 = try alloc.create(Value);
    v2.* = Value{ .integer = 2 };
    const v3 = try alloc.create(Value);
    v3.* = Value{ .integer = 3 };
    const items = try alloc.alloc(*const Value, 3);
    items[0] = v1;
    items[1] = v2;
    items[2] = v3;
    const list_val = try alloc.create(Value);
    list_val.* = Value{ .list = items };

    const args = try alloc.alloc(*const Value, 1);
    args[0] = list_val;
    const result = try builtinReverse(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expect(result.list[0].eql(Value{ .integer = 3 }));
    try std.testing.expect(result.list[1].eql(Value{ .integer = 2 }));
    try std.testing.expect(result.list[2].eql(Value{ .integer = 1 }));
}

test "builtin lookup found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try alloc.create(Value);
    val.* = Value{ .integer = 42 };
    const entries = try alloc.alloc(Value.MapEntry, 1);
    entries[0] = .{ .key = "x", .val = val };
    const map_val = try alloc.create(Value);
    map_val.* = Value{ .map = entries };

    const key_val = try alloc.create(Value);
    key_val.* = Value{ .string = "x" };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = map_val;
    args[1] = key_val;
    const result = try builtinLookup(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 42 }));
}

test "builtin lookup not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const map_val = try alloc.create(Value);
    map_val.* = Value{ .map = &.{} };

    const key_val = try alloc.create(Value);
    key_val.* = Value{ .string = "missing" };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = map_val;
    args[1] = key_val;
    const result = try builtinLookup(alloc, args);
    try std.testing.expect(result.eql(.nil));
}

test "builtin keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val1 = try alloc.create(Value);
    val1.* = Value{ .integer = 1 };
    const val2 = try alloc.create(Value);
    val2.* = Value{ .integer = 2 };
    const entries = try alloc.alloc(Value.MapEntry, 2);
    entries[0] = .{ .key = "a", .val = val1 };
    entries[1] = .{ .key = "b", .val = val2 };
    const map_val = try alloc.create(Value);
    map_val.* = Value{ .map = entries };

    const args = try alloc.alloc(*const Value, 1);
    args[0] = map_val;
    const result = try builtinKeys(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expectEqual(@as(usize, 2), result.list.len);
    try std.testing.expect(result.list[0].eql(Value{ .string = "a" }));
    try std.testing.expect(result.list[1].eql(Value{ .string = "b" }));
}

test "builtin put new key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const map_val = try alloc.create(Value);
    map_val.* = Value{ .map = &.{} };

    const key_val = try alloc.create(Value);
    key_val.* = Value{ .string = "x" };
    const new_val = try alloc.create(Value);
    new_val.* = Value{ .integer = 99 };

    const args = try alloc.alloc(*const Value, 3);
    args[0] = map_val;
    args[1] = key_val;
    args[2] = new_val;
    const result = try builtinPut(alloc, args);
    try std.testing.expect(result.* == .map);
    try std.testing.expectEqual(@as(usize, 1), result.map.len);
    try std.testing.expect(std.mem.eql(u8, result.map[0].key, "x"));
    try std.testing.expect(result.map[0].val.eql(Value{ .integer = 99 }));
}

test "builtin now returns integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try alloc.alloc(*const Value, 0);
    const result = try builtinNow(alloc, args);
    try std.testing.expect(result.* == .integer);
}

test "view text produces view_node with tag text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const str = try alloc.create(Value);
    str.* = Value{ .string = "hello" };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = str;
    const result = try viewText(alloc, args);
    try std.testing.expect(result.* == .view_node);
    try std.testing.expectEqualStrings("text", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 1), result.view_node.children.len);
    try std.testing.expect(result.view_node.children[0].eql(Value{ .string = "hello" }));
}

test "view heading defaults to level 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const str = try alloc.create(Value);
    str.* = Value{ .string = "Title" };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = str;
    const result = try viewHeading(alloc, args);
    try std.testing.expect(result.* == .view_node);
    try std.testing.expectEqualStrings("heading", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 1), result.view_node.attrs.len);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .integer = 1 }));
}

test "view heading with explicit level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const str = try alloc.create(Value);
    str.* = Value{ .string = "Sub" };
    const lvl = try alloc.create(Value);
    lvl.* = Value{ .integer = 3 };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = str;
    args[1] = lvl;
    const result = try viewHeading(alloc, args);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .integer = 3 }));
}

test "view stack variadic children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const c1 = try alloc.create(Value);
    const c1_str = try alloc.create(Value);
    c1_str.* = Value{ .string = "a" };
    const c1_view = try alloc.create(Value.ViewNode);
    c1_view.* = .{ .tag = "text", .attrs = &.{}, .children = &.{c1_str} };
    c1.* = Value{ .view_node = c1_view };
    const c2 = try alloc.create(Value);
    const c2_str = try alloc.create(Value);
    c2_str.* = Value{ .string = "b" };
    const c2_view = try alloc.create(Value.ViewNode);
    c2_view.* = .{ .tag = "text", .attrs = &.{}, .children = &.{c2_str} };
    c2.* = Value{ .view_node = c2_view };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = c1;
    args[1] = c2;
    const result = try viewStack(alloc, args);
    try std.testing.expectEqualStrings("stack", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 2), result.view_node.children.len);
}

test "view button with sends atom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const label = try alloc.create(Value);
    label.* = Value{ .string = "Click me" };
    const msg = try alloc.create(Value);
    msg.* = Value{ .atom = "checkout" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = label;
    args[1] = msg;
    const result = try viewButton(alloc, args);
    try std.testing.expectEqualStrings("button", result.view_node.tag);
    try std.testing.expectEqualStrings("sends", result.view_node.attrs[0].key);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .atom = "checkout" }));
}

test "view image with src and alt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try alloc.create(Value);
    src.* = Value{ .string = "/img/logo.png" };
    const alt = try alloc.create(Value);
    alt.* = Value{ .string = "Logo" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = src;
    args[1] = alt;
    const result = try viewImage(alloc, args);
    try std.testing.expectEqualStrings("image", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 2), result.view_node.attrs.len);
    try std.testing.expectEqualStrings("src", result.view_node.attrs[0].key);
    try std.testing.expectEqualStrings("alt", result.view_node.attrs[1].key);
}

test "view canvas with id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const id = try alloc.create(Value);
    id.* = Value{ .string = "main-canvas" };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = id;
    const result = try viewCanvas(alloc, args);
    try std.testing.expectEqualStrings("canvas", result.view_node.tag);
    try std.testing.expectEqualStrings("id", result.view_node.attrs[0].key);
}

test "view draw carries its size and display list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const w = try alloc.create(Value);
    w.* = Value{ .integer = 800 };
    const h = try alloc.create(Value);
    h.* = Value{ .integer = 600 };
    const ops = try alloc.create(Value);
    ops.* = Value{ .string = "rect 0 0 800 600 #111\ncircle 400 300 10 v:#f0f,#0ff" };
    const result = try viewDraw(alloc, &.{ w, h, ops });
    try std.testing.expectEqualStrings("draw", result.view_node.tag);
    try std.testing.expectEqualStrings("ops", result.view_node.attrs[2].key);
    try std.testing.expectEqualStrings(ops.string, result.view_node.attrs[2].val.string);
    const zero = try alloc.create(Value);
    zero.* = Value{ .integer = 0 };
    try std.testing.expectError(error.TypeError, viewDraw(alloc, &.{ zero, h, ops }));
    try std.testing.expectError(error.TypeError, viewDraw(alloc, &.{ w, h, w }));
}

test "view key: two atoms is a held key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const code = try alloc.create(Value);
    code.* = Value{ .string = "ArrowUp" };
    const down = try alloc.create(Value);
    down.* = Value{ .atom = "up_pressed" };
    const up = try alloc.create(Value);
    up.* = Value{ .atom = "up_released" };
    const tap = try viewKey(alloc, &.{ code, down });
    try std.testing.expectEqual(@as(usize, 2), tap.view_node.attrs.len);
    const held = try viewKey(alloc, &.{ code, down, up });
    try std.testing.expectEqualStrings("up", held.view_node.attrs[2].key);
    try std.testing.expectEqualStrings("up_released", held.view_node.attrs[2].val.atom);
    try std.testing.expectError(error.TypeError, viewKey(alloc, &.{ code, down, code }));
}

test "view timer with ms and sends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ms = try alloc.create(Value);
    ms.* = Value{ .integer = 500 };
    const msg = try alloc.create(Value);
    msg.* = Value{ .atom = "tick" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = ms;
    args[1] = msg;
    const result = try viewTimer(alloc, args);
    try std.testing.expectEqualStrings("timer", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 2), result.view_node.attrs.len);
    try std.testing.expectEqualStrings("ms", result.view_node.attrs[0].key);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .integer = 500 }));
    try std.testing.expectEqualStrings("sends", result.view_node.attrs[1].key);
    try std.testing.expect(result.view_node.attrs[1].val.eql(Value{ .atom = "tick" }));
    try std.testing.expectEqual(@as(usize, 0), result.view_node.children.len);

    // wrong arg types raise TypeError
    args[0] = msg;
    try std.testing.expectError(error.TypeError, viewTimer(alloc, args));
}

test "view key with code and sends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const code = try alloc.create(Value);
    code.* = Value{ .string = "ArrowLeft" };
    const msg = try alloc.create(Value);
    msg.* = Value{ .atom = "left" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = code;
    args[1] = msg;
    const result = try viewKey(alloc, args);
    try std.testing.expectEqualStrings("key", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 2), result.view_node.attrs.len);
    try std.testing.expectEqualStrings("code", result.view_node.attrs[0].key);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .string = "ArrowLeft" }));
    try std.testing.expectEqualStrings("sends", result.view_node.attrs[1].key);
    try std.testing.expect(result.view_node.attrs[1].val.eql(Value{ .atom = "left" }));
    try std.testing.expectEqual(@as(usize, 0), result.view_node.children.len);

    // wrong arg types raise TypeError
    args[1] = code;
    try std.testing.expectError(error.TypeError, viewKey(alloc, args));
}

test "view divider takes no args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try alloc.alloc(*const Value, 0);
    const result = try viewDivider(alloc, args);
    try std.testing.expectEqualStrings("divider", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 0), result.view_node.children.len);
}

test "view link with href" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const label = try alloc.create(Value);
    label.* = Value{ .string = "Click here" };
    const href = try alloc.create(Value);
    href.* = Value{ .string = "https://example.com" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = label;
    args[1] = href;
    const result = try viewLink(alloc, args);
    try std.testing.expectEqualStrings("link", result.view_node.tag);
    try std.testing.expectEqualStrings("href", result.view_node.attrs[0].key);
}

test "view code_block with lang" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = try alloc.create(Value);
    content.* = Value{ .string = "x = 42" };
    const lang = try alloc.create(Value);
    lang.* = Value{ .atom = "blimp" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = content;
    args[1] = lang;
    const result = try viewCodeBlock(alloc, args);
    try std.testing.expectEqualStrings("code_block", result.view_node.tag);
    try std.testing.expectEqualStrings("lang", result.view_node.attrs[0].key);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .atom = "blimp" }));
}

// ============================================================
// HTTP / TCP builtins
// ============================================================

// ============================================================
// Native-only stub: on WASM, these functions return error.NotSupported
// so the compiler doesn't try to resolve std.posix symbols.
// ============================================================

const native_stub = if (is_wasm) struct {
    fn stub(_: std.mem.Allocator, _: []const *const Value) EvalError!*const Value {
        return error.NotSupported;
    }
} else struct {};

const builtinToHtml_impl = if (is_wasm) native_stub.stub else builtinToHtmlNative;
const builtinTcpListen_impl = if (is_wasm) native_stub.stub else builtinTcpListenNative;
const builtinTcpAccept_impl = if (is_wasm) native_stub.stub else builtinTcpAcceptNative;
const builtinTcpRead_impl = if (is_wasm) native_stub.stub else builtinTcpReadNative;
const builtinTcpWrite_impl = if (is_wasm) native_stub.stub else builtinTcpWriteNative;
const builtinTcpClose_impl = if (is_wasm) native_stub.stub else builtinTcpCloseNative;
const builtinWsAcceptKey_impl = if (is_wasm) native_stub.stub else builtinWsAcceptKeyNative;
const builtinWsReadFrame_impl = if (is_wasm) native_stub.stub else builtinWsReadFrameNative;
const builtinWsWriteFrame_impl = if (is_wasm) native_stub.stub else builtinWsWriteFrameNative;
const builtinViewDiff_impl = if (is_wasm) native_stub.stub else builtinViewDiffNative;
const builtinFork_impl = if (is_wasm) native_stub.stub else builtinForkNative;
const builtinWaitpid_impl = if (is_wasm) native_stub.stub else builtinWaitpidNative;
const builtinExit_impl = if (is_wasm) native_stub.stub else builtinExitNative;
const builtinTcpSetNonblocking_impl = if (is_wasm) native_stub.stub else builtinTcpSetNonblockingNative;
const builtinTcpPoll_impl = if (is_wasm) native_stub.stub else builtinTcpPollNative;
const builtinTcpWriteSome_impl = if (is_wasm) native_stub.stub else builtinTcpWriteSomeNative;
const builtinTcpPollWrite_impl = if (is_wasm) native_stub.stub else builtinTcpPollWriteNative;
const builtinSleepMs_impl = if (is_wasm) native_stub.stub else builtinSleepMsNative;
const builtinReadLine_impl = if (is_wasm) native_stub.stub else builtinReadLineNative;
const builtinRandomBytes_impl = if (is_wasm) native_stub.stub else builtinRandomBytesNative;
const builtinRandomToken_impl = if (is_wasm) native_stub.stub else builtinRandomTokenNative;
const builtinGetenv_impl = if (is_wasm) native_stub.stub else builtinGetenvNative;
const builtinArgv_impl = if (is_wasm) native_stub.stub else builtinArgvNative;

/// getenv(name) -> the variable's value as a String, or nil when it is not
/// set. A set-but-empty variable is "", not nil.
///
/// Raises TypeError for a non-String name, and for a name with a NUL byte in
/// it: C would read the name only up to the NUL and answer for a different
/// variable than the one asked about.
fn builtinGetenvNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const name = args[0].string;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.TypeError;
    const z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    const val = std.c.getenv(z) orelse return make(allocator, .nil);
    const owned = allocator.dupe(u8, std.mem.span(val)) catch return error.OutOfMemory;
    return make(allocator, .{ .string = owned });
}

/// argv() -> the whole command line as a List of Strings, exactly as the
/// process got it: argv()[0] is the blimp binary, argv()[1] the script, and
/// anything after that is the script's (including flags blimp itself read,
/// like --test).
///
/// `main` takes its arguments as a zig 0.16 capability and does not publish
/// them, so this asks the OS for them instead: _NSGetArgv on macOS,
/// /proc/self/cmdline on Linux. Anywhere else it is NotSupported.
fn builtinArgvNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    var list: std.ArrayList(*const Value) = .empty;
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            const darwin = struct {
                extern "c" fn _NSGetArgc() *c_int;
                extern "c" fn _NSGetArgv() *[*][*:0]u8;
            };
            const argc: usize = @intCast(darwin._NSGetArgc().*);
            const argv = darwin._NSGetArgv().*;
            for (argv[0..argc]) |arg| {
                const owned = allocator.dupe(u8, std.mem.span(arg)) catch return error.OutOfMemory;
                list.append(allocator, try make(allocator, .{ .string = owned })) catch return error.OutOfMemory;
            }
        },
        .linux => {
            const raw = std.Io.Dir.cwd().readFileAlloc(ioenv.io, "/proc/self/cmdline", allocator, .limited(1024 * 1024)) catch {
                return error.NotSupported;
            };
            // NUL-terminated arguments laid end to end; the last NUL ends the
            // last argument rather than starting an empty one.
            const body = if (raw.len > 0 and raw[raw.len - 1] == 0) raw[0 .. raw.len - 1] else raw;
            var parts = std.mem.splitScalar(u8, body, 0);
            while (parts.next()) |arg| {
                list.append(allocator, try make(allocator, .{ .string = arg })) catch return error.OutOfMemory;
            }
        },
        else => return error.NotSupported,
    }
    return make(allocator, .{ .list = list.toOwnedSlice(allocator) catch return error.OutOfMemory });
}

/// n bytes from the operating system's CSPRNG (getentropy/getrandom through
/// `Io.randomSecure`), or TypeError for a count that is not a non-negative
/// Int. NotSupported if the OS will not give entropy -- there is no fallback
/// to something weaker.
fn secureBytes(allocator: std.mem.Allocator, args: []const *const Value) EvalError![]u8 {
    if (args.len != 1 or args[0].* != .integer or args[0].integer < 0) return error.TypeError;
    const buf = allocator.alloc(u8, @intCast(args[0].integer)) catch return error.OutOfMemory;
    ioenv.io.randomSecure(buf) catch return error.NotSupported;
    return buf;
}

/// random_bytes(n) -> a String of n bytes from the OS CSPRNG.
///
/// Not `random`: that is xorshift with a fixed seed, which is what a test or
/// a game replay wants and exactly what a session id must not be. This one
/// leaves the xorshift state alone, so a seeded sequence is not disturbed by
/// a token minted in the middle of it. Native only; NotSupported on WASM.
fn builtinRandomBytesNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return make(allocator, .{ .string = try secureBytes(allocator, args) });
}

/// random_token(n) -> base64url (no padding) of n CSPRNG bytes: 32 bytes is
/// a 43-character token that can go in a cookie or a URL unescaped.
fn builtinRandomTokenNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    const raw = try secureBytes(allocator, args);
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = allocator.alloc(u8, enc.calcSize(raw.len)) catch return error.OutOfMemory;
    _ = enc.encode(out, raw);
    return make(allocator, .{ .string = out });
}

/// sleep_ms(n: Int) -> :ok
///
/// A game loop needs to do three things: read input, change state, and wait.
/// Blimp could do the middle one. `now()` reports seconds, so a busy-wait on
/// it cannot express 200ms and would burn a core besides.
///
/// `nanosleep` rather than `sleep` because the unit that matters here is
/// milliseconds, and it restarts on a signal so a stray SIGWINCH from a
/// resized terminal does not cut the wait short.
fn builtinSleepMsNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const ms = args[0].integer;
    if (ms > 0) {
        var req: std.c.timespec = .{
            .sec = @intCast(@divTrunc(ms, 1000)),
            .nsec = @intCast(@rem(ms, 1000) * 1_000_000),
        };
        var rem: std.c.timespec = undefined;
        while (std.c.nanosleep(&req, &rem) != 0) {
            req = rem;
        }
    }
    return make(allocator, .{ .atom = "ok" });
}

/// read_line() -> String without its newline, or nil at end of input.
///
/// nil rather than "" for end of input: a blank line a user typed is a real
/// empty string, and a caller that cannot tell the two apart loops forever on
/// a closed stdin.
fn builtinReadLineNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    var line = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer line.deinit(allocator);
    var ch: [1]u8 = undefined;
    while (true) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &ch) catch return error.NotSupported;
        if (n == 0) {
            // End of input with nothing buffered is the end. With something
            // buffered it is a last line that had no newline on it.
            if (line.items.len == 0) return make(allocator, .nil);
            break;
        }
        if (ch[0] == '\n') break;
        line.append(allocator, ch[0]) catch return error.OutOfMemory;
    }
    // A terminal that sends CRLF would otherwise put the CR in the string,
    // where it compares unequal to every key the caller is looking for.
    var end = line.items.len;
    if (end > 0 and line.items[end - 1] == '\r') end -= 1;
    const owned = allocator.dupe(u8, line.items[0..end]) catch return error.OutOfMemory;
    return make(allocator, .{ .string = owned });
}

/// to_html(view_node) -> String
/// Renders a view_node tree to an HTML string.
fn builtinToHtmlNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    renderHtml(allocator, args[0], &buf) catch return error.OutOfMemory;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

fn appendAttrEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try buf.appendSlice(allocator, "&lt;"),
        '>' => try buf.appendSlice(allocator, "&gt;"),
        '&' => try buf.appendSlice(allocator, "&amp;"),
        '"' => try buf.appendSlice(allocator, "&quot;"),
        else => try buf.append(allocator, c),
    };
}

/// An el() node as the markup it stands for, every attribute value escaped.
/// The host instructions (click, with, input, change, submit) are not
/// markup and are left out: to_html is a page without its program.
fn renderElHtml(allocator: std.mem.Allocator, node: *const Value.ViewNode, buf: *std.ArrayListUnmanaged(u8)) std.mem.Allocator.Error!void {
    const tag = node.attrs[0].val.string;
    try buf.append(allocator, '<');
    try buf.appendSlice(allocator, tag);
    for (node.attrs[1..]) |attr| {
        if (isElEventKey(attr.key)) continue;
        switch (attr.val.*) {
            .nil => continue,
            .boolean => |b| {
                if (!b) continue;
                try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, attr.key);
                continue;
            },
            else => {},
        }
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, attr.key);
        try buf.appendSlice(allocator, "=\"");
        switch (attr.val.*) {
            .string => |v| try appendAttrEscaped(allocator, buf, v),
            .atom => |a| try appendAttrEscaped(allocator, buf, a),
            .integer => |n| try buf.print(allocator, "{d}", .{n}),
            .float => |f| try buf.print(allocator, "{d}", .{f}),
            else => {},
        }
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, '>');
    const void_tags = [_][]const u8{ "img", "input", "hr", "br", "source" };
    for (void_tags) |v| if (std.mem.eql(u8, v, tag)) return;
    var raw: ?[]const u8 = null;
    for (node.attrs[1..]) |attr| {
        if (std.mem.eql(u8, attr.key, "inner_html") and attr.val.* == .string) raw = attr.val.string;
    }
    if (raw) |markup| try buf.appendSlice(allocator, markup) else for (node.children) |child| try renderHtml(allocator, child, buf);
    try buf.appendSlice(allocator, "</");
    try buf.appendSlice(allocator, tag);
    try buf.append(allocator, '>');
}

fn renderHtml(allocator: std.mem.Allocator, val: *const Value, buf: *std.ArrayListUnmanaged(u8)) std.mem.Allocator.Error!void {
    switch (val.*) {
        .view_node => |node| {
            // Effect nodes (timer, key) are host instructions, not markup.
            if (std.mem.eql(u8, node.tag, "timer") or std.mem.eql(u8, node.tag, "key") or
                std.mem.eql(u8, node.tag, "fetch") or std.mem.eql(u8, node.tag, "location_query") or
                std.mem.eql(u8, node.tag, "stored") or std.mem.eql(u8, node.tag, "store")) return;
            if (std.mem.eql(u8, node.tag, "el")) return renderElHtml(allocator, node, buf);
            const tag = blimpTagToHtml(node.tag);
            try buf.appendSlice(allocator, "<");
            try buf.appendSlice(allocator, tag);
            if (std.mem.eql(u8, node.tag, "row")) {
                try buf.appendSlice(allocator, " data-row");
            }
            if (std.mem.eql(u8, node.tag, "form")) {
                try buf.appendSlice(allocator, " method=\"POST\" action=\"\" onsubmit=\"blimpSubmit(event)\"");
            }
            for (node.attrs) |attr| {
                if (std.mem.eql(u8, attr.key, "href")) {
                    var val_buf: [512]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const href = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " href=\"");
                    try buf.appendSlice(allocator, href);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "src")) {
                    var val_buf: [512]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const src = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " src=\"");
                    try buf.appendSlice(allocator, src);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "sends")) {
                    var val_buf: [256]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const msg = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                    try buf.appendSlice(allocator, " data-sends=\"");
                    try buf.appendSlice(allocator, msg);
                    try buf.appendSlice(allocator, "\" onclick=\"blimpSend(this)\"");
                } else if (std.mem.eql(u8, attr.key, "level")) {
                    // heading level - handled in tag mapping
                } else if (std.mem.eql(u8, attr.key, "lang")) {
                    var val_buf: [64]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const lang = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                    try buf.appendSlice(allocator, " data-lang=\"");
                    try buf.appendSlice(allocator, lang);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "data-actor")) {
                    var val_buf: [256]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const name = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " data-actor=\"");
                    try buf.appendSlice(allocator, name);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "name") or
                    std.mem.eql(u8, attr.key, "placeholder") or
                    std.mem.eql(u8, attr.key, "value"))
                {
                    var val_buf: [512]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const clean = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " ");
                    try buf.appendSlice(allocator, attr.key);
                    try buf.appendSlice(allocator, "=\"");
                    try buf.appendSlice(allocator, clean);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "type")) {
                    var val_buf: [64]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const type_name = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                    try buf.appendSlice(allocator, " type=\"");
                    try buf.appendSlice(allocator, type_name);
                    try buf.appendSlice(allocator, "\"");
                }
            }
            if (std.mem.eql(u8, node.tag, "divider") or std.mem.eql(u8, node.tag, "image") or std.mem.eql(u8, node.tag, "input")) {
                try buf.appendSlice(allocator, " />");
                return;
            }
            try buf.appendSlice(allocator, ">");
            for (node.children) |child| {
                try renderHtml(allocator, child, buf);
            }
            try buf.appendSlice(allocator, "</");
            try buf.appendSlice(allocator, tag);
            try buf.appendSlice(allocator, ">");
        },
        .string => |s| {
            for (s) |c| {
                switch (c) {
                    '<' => try buf.appendSlice(allocator, "&lt;"),
                    '>' => try buf.appendSlice(allocator, "&gt;"),
                    '&' => try buf.appendSlice(allocator, "&amp;"),
                    '"' => try buf.appendSlice(allocator, "&quot;"),
                    else => try buf.append(allocator, c),
                }
            }
        },
        .integer => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch return;
            try buf.appendSlice(allocator, s);
        },
        .boolean => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .nil => {},
        else => {
            var tmp: [256]u8 = undefined;
            var fbs = std.Io.Writer.fixed(&tmp);
            val.format(&fbs);
            try buf.appendSlice(allocator, fbs.buffered());
        },
    }
}

fn blimpTagToHtml(tag: []const u8) []const u8 {
    if (std.mem.eql(u8, tag, "stack")) return "div";
    if (std.mem.eql(u8, tag, "row")) return "div"; // gets data-row attr below
    if (std.mem.eql(u8, tag, "grid")) return "div";
    if (std.mem.eql(u8, tag, "text")) return "span";
    if (std.mem.eql(u8, tag, "heading")) return "h1";
    if (std.mem.eql(u8, tag, "bold")) return "strong";
    if (std.mem.eql(u8, tag, "italic")) return "em";
    if (std.mem.eql(u8, tag, "code")) return "code";
    if (std.mem.eql(u8, tag, "code_block")) return "pre";
    if (std.mem.eql(u8, tag, "blockquote")) return "blockquote";
    if (std.mem.eql(u8, tag, "divider")) return "hr";
    if (std.mem.eql(u8, tag, "list")) return "ul";
    if (std.mem.eql(u8, tag, "link")) return "a";
    if (std.mem.eql(u8, tag, "image")) return "img";
    if (std.mem.eql(u8, tag, "video")) return "video";
    if (std.mem.eql(u8, tag, "canvas")) return "canvas";
    if (std.mem.eql(u8, tag, "draw")) return "canvas";
    if (std.mem.eql(u8, tag, "button")) return "button";
    if (std.mem.eql(u8, tag, "mount")) return "div";
    if (std.mem.eql(u8, tag, "input")) return "input";
    if (std.mem.eql(u8, tag, "textarea")) return "textarea";
    if (std.mem.eql(u8, tag, "select")) return "select";
    if (std.mem.eql(u8, tag, "option_elem")) return "option";
    if (std.mem.eql(u8, tag, "form")) return "form";
    return "div";
}

/// tcp_listen(port: Int) -> Int  (server socket fd)
fn builtinTcpListenNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    // Not clamped. `tcp_connect` stopped clamping and this did not, so
    // `tcp_listen(99999)` still bound 65535 -- a program that asked for a port
    // that does not exist got a working listener on a different one, and
    // nothing said which.
    if (args[0].integer < 0 or args[0].integer > 65535) return make(allocator, .nil);
    const port: u16 = @intCast(args[0].integer);

    // zig 0.16 took the thin syscall wrappers out of `std.posix`; libc still
    // has them, and a `-1` with errno is the whole of their error handling.
    const sock_fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (sock_fd < 0) return error.NotSupported;
    const sock: std.posix.socket_t = sock_fd;
    // Allow port reuse so we can restart quickly
    const one: c_int = 1;
    _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};
    // `std.net` moved under `std.Io`, and all this ever wanted was
    // 0.0.0.0:port, which is a sockaddr.in written out. Port is network order.
    var addr = std.mem.zeroes(std.posix.sockaddr.in);
    addr.family = std.posix.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = 0;
    // A port that is taken used to fail as a bare "NotSupported", which is
    // what a missing feature looks like. Say which port and why.
    if (std.c.bind(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0 or std.c.listen(sock, 128) < 0) {
        const e: std.posix.E = @enumFromInt(std.c._errno().*);
        std.debug.print("tcp_listen({d}): {s}\n", .{ port, if (e == .ADDRINUSE) "the port is already in use" else @tagName(e) });
        _ = std.c.close(sock);
        return error.NotSupported;
    }

    return make(allocator, .{ .integer = @intCast(sock) });
}

/// tcp_connect(host: String, port: Int) -> Int | nil  (connected socket fd)
///
/// Blimp could listen and accept but not dial, so nothing written in it could
/// be an HTTP client. `getaddrinfo` does the resolving, which is what makes
/// "localhost" and a dotted quad the same amount of work here.
// ── HTTPS, without stopping the program ──────────────────────────────────
//
// http_start(method, url, headers, body) -> handle
// http_start(method, url, headers, body, %{timeout_ms: Int, max_redirects: Int}) -> handle
// http_result(handle) -> nil (still going) | {:ok, status, body} | {:error, reason}
//
// A program that serves a website from one process cannot wait on a remote
// server: while it waits, nobody else gets an answer. So the request runs on
// a thread of its own -- Zig's HTTP client (vendored), TLS and all, with the runtime's
// Io -- and the program asks, from its own loop, whether it is done. The
// answer is given once; the handle is free after it. Bodies are capped at
// 8 MiB, and 32 requests may be in flight. The WebAssembly build has no
// threads and no sockets, and refuses both.
//
// Nothing the remote end does may stop the process: this is one thread of a
// server that answers everyone. Every failure in the worker is an
// {:error, reason}. A header named User-Agent, Host, Authorization,
// Connection, Accept-Encoding or Content-Type (any case) replaces the one
// the client would send, rather than going out as a second copy of it; a
// header name or value that would split the request (CR, LF, a ':' in the
// name, an empty name) is refused by http_start.
//
// Every request has a deadline: `timeout_ms` from http_start, 15s unless the
// options say otherwise, for the whole of it -- DNS, connect, TLS, redirects
// and body. Without one, a server that accepted and never answered held its
// slot for as long as the process lived, and 32 of them stopped every
// outbound request the site makes. At the deadline http_result answers
// {:error, "timeout"} and the handle is free for the next http_start at
// once, whether or not the worker has finished unwinding: the request lives
// in a job the worker frees, not in the slot. The worker cancels the fetch
// through the Io (std.Io.Threaded interrupts the blocked syscall with
// SIGIO), so the socket is closed and the thread ends, not leaked.
//
// Redirects: GET-like requests (no body) follow up to `max_redirects`, 5
// unless the options say otherwise (std's default is 3, which is what made a
// 4-hop chain TooManyHttpRedirects). `max_redirects: 0` follows none and
// answers the 3xx itself as {:ok, 302, body}; the result carries no headers,
// so where it pointed is not in it. A request with a body never follows a
// redirect, as before: std will not resend a body.

const http_slots_max = 32;
const http_body_max = 8 * 1024 * 1024;
const http_timeout_default_ms: i64 = 15_000;
const http_timeout_max_ms: i64 = 600_000;
const http_redirects_default: u16 = 5;
const http_redirects_max: i64 = 20;

/// One request, owned by its worker thread from start to finish. The slot
/// points at it; when the program stops waiting (the deadline passed), the
/// slot lets go and the worker frees it when it is done.
const HttpJob = struct {
    // 1 running, 2 done, 3 failed, 4 abandoned by the program. The worker
    // moves 1 -> 2|3, http_result moves 1 -> 4; whoever loses the race to
    // move it off 1 knows the other side owns the job now.
    state: std.atomic.Value(u8) = .init(1),
    // set by the fetch task when client.fetch has returned, whatever it said
    fetched: std.atomic.Value(u8) = .init(0),
    method: std.http.Method = .GET,
    url: []u8 = &.{},
    body_in: []u8 = &.{},
    headers: []std.http.Header = &.{},
    // what was allocated for `headers`, which may be fewer
    headers_all: []std.http.Header = &.{},
    header_bytes: []u8 = &.{},
    // the standard headers the program named, which replace the client's own
    std_headers: HttpClient.Request.Headers = .{},
    timeout_ms: i64 = http_timeout_default_ms,
    max_redirects: u16 = http_redirects_default,
    status: u16 = 0,
    body: []u8 = &.{},
    reason: []const u8 = "",
    reason_buf: [96]u8 = undefined,
};

const HttpSlot = struct {
    job: ?*HttpJob = null,
    deadline: i64 = 0,
};

// touched only by the interpreter's thread
var http_slots: [http_slots_max]HttpSlot = [_]HttpSlot{.{}} ** http_slots_max;

fn httpFetch(job: *HttpJob) void {
    defer job.fetched.store(1, .release);
    const pa = std.heap.page_allocator;
    var client: HttpClient = .{ .allocator = pa, .io = ioenv.io };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(pa);
    defer out.deinit();
    const redirects: ?HttpClient.Request.RedirectBehavior = if (job.body_in.len > 0)
        null // std's own choice for a request with a body: never follow
    else if (job.max_redirects == 0)
        .unhandled
    else
        .init(job.max_redirects);
    const result = client.fetch(.{
        .location = .{ .url = job.url },
        .method = job.method,
        .payload = if (job.body_in.len > 0) job.body_in else null,
        .headers = job.std_headers,
        .extra_headers = job.headers,
        .response_writer = &out.writer,
        .response_limit = http_body_max,
        .keep_alive = false,
        .redirect_behavior = redirects,
    }) catch |err| {
        job.reason = switch (err) {
            // which handshake failure: an expired certificate and a server
            // with no cipher suite in common are both TlsInitializationFailed
            error.TlsInitializationFailed => if (client.tls_init_error) |why|
                std.fmt.bufPrint(&job.reason_buf, "TlsInitializationFailed: {s}", .{@errorName(why)}) catch @errorName(err)
            else
                @errorName(err),
            else => @errorName(err),
        };
        return;
    };
    const got = out.written();
    job.body = pa.dupe(u8, got) catch {
        job.reason = "OutOfMemory";
        return;
    };
    job.status = @intFromEnum(result.status);
}

fn httpWorker(job: *HttpJob) void {
    const io = ioenv.io;
    const deadline = monoMs() + job.timeout_ms;
    var timed_out = false;
    if (io.concurrent(httpFetch, .{job})) |fut| {
        var f = fut;
        while (job.fetched.load(.acquire) == 0 and monoMs() < deadline) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
        if (job.fetched.load(.acquire) == 0) {
            timed_out = true;
            f.cancel(io);
        } else f.await(io);
    } else |_| {
        // An Io that cannot run the fetch concurrently cannot time it out.
        // Say so rather than run it without a deadline.
        job.reason = "NoConcurrency";
    }
    if (timed_out) {
        if (job.body.len > 0) std.heap.page_allocator.free(job.body);
        job.body = &.{};
        job.reason = "timeout";
    }
    const final: u8 = if (!timed_out and job.reason.len == 0) 2 else 3;
    if (job.state.cmpxchgStrong(1, final, .acq_rel, .acquire) != null) {
        httpJobFree(job); // the program stopped waiting; nobody else will
    }
}

fn httpJobFree(job: *HttpJob) void {
    const pa = std.heap.page_allocator;
    if (job.url.len > 0) pa.free(job.url);
    if (job.body_in.len > 0) pa.free(job.body_in);
    if (job.headers_all.len > 0) pa.free(job.headers_all);
    if (job.header_bytes.len > 0) pa.free(job.header_bytes);
    if (job.body.len > 0) pa.free(job.body);
    pa.destroy(job);
}

/// Reads http_start's options map. Anything it does not know, or a value out
/// of range, is a TypeError: a misspelt `timeout` that silently meant 15s is
/// the kind of wrong that hides.
fn httpOptions(job: *HttpJob, v: *const Value) EvalError!void {
    const entries: []const Value.MapEntry = switch (v.*) {
        .map => |m| m,
        .nil => return,
        else => return error.TypeError,
    };
    for (entries) |e| {
        if (e.val.* != .integer) return error.TypeError;
        const n = e.val.integer;
        if (std.mem.eql(u8, e.key, "timeout_ms")) {
            if (n < 1 or n > http_timeout_max_ms) return error.TypeError;
            job.timeout_ms = n;
        } else if (std.mem.eql(u8, e.key, "max_redirects")) {
            if (n < 0 or n > http_redirects_max) return error.TypeError;
            job.max_redirects = @intCast(n);
        } else return error.TypeError;
    }
}

/// std's client asserts these (a panic in a safe build); a program passing
/// a user-supplied header through should get a TypeError instead, and a
/// value with a CRLF in it must never reach the wire.
fn httpHeaderOk(name: []const u8, value: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (c == ':' or c == '\r' or c == '\n') return false;
    for (value) |c| if (c == '\r' or c == '\n') return false;
    return true;
}

/// The client writes these six itself; a program's own goes in their place
/// (`.override`) rather than beside them as a second copy.
fn httpStdHeader(h: *HttpClient.Request.Headers, name: []const u8) ?*HttpClient.Request.Headers.Value {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "user-agent")) return &h.user_agent;
    if (eq(name, "host")) return &h.host;
    if (eq(name, "authorization")) return &h.authorization;
    if (eq(name, "connection")) return &h.connection;
    if (eq(name, "accept-encoding")) return &h.accept_encoding;
    if (eq(name, "content-type")) return &h.content_type;
    return null;
}

fn builtinHttpStart(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (is_wasm) return error.NotSupported;
    if (args.len != 4 and args.len != 5) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string or args[3].* != .string) return error.TypeError;
    const entries: []const Value.MapEntry = switch (args[2].*) {
        .map => |m| m,
        .nil => &.{},
        else => return error.TypeError,
    };
    const method = std.meta.stringToEnum(std.http.Method, args[0].string) orelse return error.TypeError;
    const url = args[1].string;
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.TypeError;
    var opts: HttpJob = .{};
    if (args.len == 5) try httpOptions(&opts, args[4]);
    for (entries) |e| {
        if (e.val.* != .string) return error.TypeError;
        if (!httpHeaderOk(e.key, e.val.string)) return error.TypeError;
    }
    var free_i: ?usize = null;
    for (&http_slots, 0..) |*slot, i| {
        if (slot.job == null) {
            free_i = i;
            break;
        }
    }
    const i = free_i orelse return make(allocator, .{ .integer = -1 });
    const pa = std.heap.page_allocator;
    // the worker owns copies: the interpreter's heap is compacted under it
    var total: usize = 0;
    for (entries) |e| total += e.key.len + e.val.string.len;
    const bytes = pa.alloc(u8, total) catch return error.OutOfMemory;
    const headers = pa.alloc(std.http.Header, entries.len) catch return error.OutOfMemory;
    var std_headers: HttpClient.Request.Headers = .{};
    var at: usize = 0;
    var n_extra: usize = 0;
    for (entries) |e| {
        @memcpy(bytes[at .. at + e.key.len], e.key);
        const name = bytes[at .. at + e.key.len];
        at += e.key.len;
        @memcpy(bytes[at .. at + e.val.string.len], e.val.string);
        const value = bytes[at .. at + e.val.string.len];
        at += e.val.string.len;
        if (httpStdHeader(&std_headers, name)) |field| {
            field.* = .{ .override = value };
        } else {
            headers[n_extra] = .{ .name = name, .value = value };
            n_extra += 1;
        }
    }
    const job = pa.create(HttpJob) catch return error.OutOfMemory;
    job.* = .{
        .method = method,
        .url = pa.dupe(u8, url) catch return error.OutOfMemory,
        .body_in = pa.dupe(u8, args[3].string) catch return error.OutOfMemory,
        .headers = headers[0..n_extra],
        .headers_all = headers,
        .header_bytes = bytes,
        .std_headers = std_headers,
        .timeout_ms = opts.timeout_ms,
        .max_redirects = opts.max_redirects,
    };
    const thread = std.Thread.spawn(.{}, httpWorker, .{job}) catch {
        httpJobFree(job);
        return error.NotSupported;
    };
    thread.detach();
    http_slots[i] = .{ .job = job, .deadline = monoMs() + job.timeout_ms };
    return make(allocator, .{ .integer = @intCast(i) });
}

fn builtinHttpResult(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (is_wasm) return error.NotSupported;
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    if (args[0].integer < 0 or args[0].integer >= http_slots_max) return error.TypeError;
    const slot = &http_slots[@intCast(args[0].integer)];
    const job = slot.job orelse return error.TypeError; // not a request in flight
    if (job.state.load(.acquire) == 1) {
        if (monoMs() < slot.deadline) return make(allocator, .nil);
        // Past the deadline and the worker has not finished: stop waiting.
        // If the worker finishes in between, the exchange fails and its
        // answer is the one given.
        if (job.state.cmpxchgStrong(1, 4, .acq_rel, .acquire) == null) {
            slot.* = .{};
            const items = try allocator.alloc(*const Value, 2);
            items[0] = try make(allocator, .{ .atom = "error" });
            items[1] = try make(allocator, .{ .string = "timeout" });
            return make(allocator, .{ .tuple = items });
        }
    }
    const items = try allocator.alloc(*const Value, 3);
    if (job.state.load(.acquire) == 2) {
        items[0] = try make(allocator, .{ .atom = "ok" });
        items[1] = try make(allocator, .{ .integer = job.status });
        items[2] = try make(allocator, .{ .string = allocator.dupe(u8, job.body) catch return error.OutOfMemory });
    } else {
        items[0] = try make(allocator, .{ .atom = "error" });
        items[1] = try make(allocator, .{ .string = allocator.dupe(u8, job.reason) catch return error.OutOfMemory });
        items[2] = try make(allocator, .nil);
    }
    httpJobFree(job);
    slot.* = .{};
    if (items[0].atom[0] == 'e') return make(allocator, .{ .tuple = items[0..2] });
    return make(allocator, .{ .tuple = items });
}

// ============================================================
// http_start deadline and redirect tests
// ============================================================

/// A loopback HTTP/1.1 server, one thread per connection. `/hang` reads the
/// request and never answers, and counts the connection once the client has
/// closed it; `/r/N` redirects to `/r/N-1`; `/r/0` and everything else is a
/// 200.
const HttpTestServer = struct {
    listen_fd: c_int,
    port: u16,
    hangs_closed: std.atomic.Value(u32) = .init(0),

    fn start() !*HttpTestServer {
        const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var addr = std.mem.zeroes(std.posix.sockaddr.in);
        addr.family = std.posix.AF.INET;
        addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.BindFailed;
        if (std.c.listen(fd, 64) < 0) return error.ListenFailed;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        _ = std.c.getsockname(fd, @ptrCast(&addr), &len);
        const s = try std.heap.page_allocator.create(HttpTestServer);
        s.* = .{ .listen_fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
        const t = try std.Thread.spawn(.{}, acceptLoop, .{s});
        t.detach();
        return s;
    }

    fn acceptLoop(s: *HttpTestServer) void {
        while (true) {
            const c = std.c.accept(s.listen_fd, null, null);
            if (c < 0) return; // the test closed the listener
            const t = std.Thread.spawn(.{}, serveOne, .{ s, c }) catch {
                _ = std.c.close(c);
                continue;
            };
            t.detach();
        }
    }

    fn serveOne(s: *HttpTestServer, c: c_int) void {
        defer _ = std.c.close(c);
        var buf: [4096]u8 = undefined;
        var got: usize = 0;
        while (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") == null) {
            const n = std.c.read(c, buf[got..].ptr, buf.len - got);
            if (n <= 0) return;
            got += @intCast(n);
        }
        const line_end = std.mem.indexOf(u8, buf[0..got], "\r\n").?;
        var parts = std.mem.splitScalar(u8, buf[0..line_end], ' ');
        _ = parts.next();
        const path = parts.next() orelse "/";
        if (std.mem.eql(u8, path, "/hang")) {
            while (std.c.read(c, &buf, buf.len) > 0) {}
            _ = s.hangs_closed.fetchAdd(1, .release);
            return;
        }
        var out: [256]u8 = undefined;
        const answer = if (std.mem.startsWith(u8, path, "/r/") and !std.mem.eql(u8, path, "/r/0")) blk: {
            const n = std.fmt.parseInt(u32, path[3..], 10) catch 0;
            break :blk std.fmt.bufPrint(&out, "HTTP/1.1 302 Found\r\nLocation: /r/{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{n - 1}) catch return;
        } else "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\narrived";
        _ = std.c.write(c, answer.ptr, answer.len);
    }
};

fn httpTestNap(ms: u32) void {
    var ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

/// http_start then http_result until it answers, or 20s.
fn httpTestFetch(a: std.mem.Allocator, url: []const u8, opts: ?*const Value) !*const Value {
    var args: [5]*const Value = .{
        try make(a, .{ .string = "GET" }),
        try make(a, .{ .string = url }),
        try make(a, .nil),
        try make(a, .{ .string = "" }),
        undefined,
    };
    if (opts) |o| args[4] = o;
    const h = try builtinHttpStart(a, args[0..if (opts == null) 4 else 5]);
    try std.testing.expect(h.integer >= 0);
    var tries: usize = 0;
    while (tries < 4000) : (tries += 1) {
        const r = try builtinHttpResult(a, &.{h});
        if (r.* != .nil) return r;
        httpTestNap(5);
    }
    return error.NeverAnswered;
}

fn httpTestOpts(a: std.mem.Allocator, key: []const u8, n: i64) !*const Value {
    const entries = try a.alloc(Value.MapEntry, 1);
    entries[0] = .{ .key = key, .val = try make(a, .{ .integer = n }) };
    return make(a, .{ .map = entries });
}

test "http_start: a server that never answers is {:error, \"timeout\"} at the deadline, and the slot and socket come back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;
    const srv = try HttpTestServer.start();

    var url_buf: [64]u8 = undefined;
    const hang = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hang", .{srv.port});
    const t0 = monoMs();
    const r = try httpTestFetch(a, hang, try httpTestOpts(a, "timeout_ms", 300));
    const took = monoMs() - t0;
    try std.testing.expectEqualStrings("error", r.tuple[0].atom);
    try std.testing.expectEqualStrings("timeout", r.tuple[1].string);
    try std.testing.expect(took >= 300);
    try std.testing.expect(took < 1500);

    // The worker cancelled the fetch: the server sees the connection closed,
    // rather than a thread left blocked in a read for the life of the process.
    var tries: usize = 0;
    while (srv.hangs_closed.load(.acquire) < 1 and tries < 400) : (tries += 1) httpTestNap(5);
    try std.testing.expectEqual(@as(u32, 1), srv.hangs_closed.load(.acquire));

    // Every slot held by a hanging request, then all of them freed at once.
    var hs: [http_slots_max]*const Value = undefined;
    for (&hs) |*h| {
        h.* = try builtinHttpStart(a, &.{ try make(a, .{ .string = "GET" }), try make(a, .{ .string = hang }), try make(a, .nil), try make(a, .{ .string = "" }), try httpTestOpts(a, "timeout_ms", 200) });
        try std.testing.expect(h.*.integer >= 0);
    }
    const full = try builtinHttpStart(a, &.{ try make(a, .{ .string = "GET" }), try make(a, .{ .string = hang }), try make(a, .nil), try make(a, .{ .string = "" }) });
    try std.testing.expectEqual(@as(i64, -1), full.integer);
    httpTestNap(250);
    for (hs) |h| {
        const got = try builtinHttpResult(a, &.{h});
        try std.testing.expectEqualStrings("timeout", got.tuple[1].string);
    }
    const ok_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{srv.port});
    const ok = try httpTestFetch(a, ok_url, null);
    try std.testing.expectEqualStrings("ok", ok.tuple[0].atom);
    try std.testing.expectEqual(@as(i64, 200), ok.tuple[1].integer);
    tries = 0;
    while (srv.hangs_closed.load(.acquire) < 1 + http_slots_max and tries < 400) : (tries += 1) httpTestNap(5);
    try std.testing.expectEqual(@as(u32, 1 + http_slots_max), srv.hangs_closed.load(.acquire));
}

test "http_start follows 5 redirects by default, as many as max_redirects says, and none at 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;
    const srv = try HttpTestServer.start();
    var url_buf: [64]u8 = undefined;

    const five = try httpTestFetch(a, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/r/5", .{srv.port}), null);
    try std.testing.expectEqualStrings("ok", five.tuple[0].atom);
    try std.testing.expectEqualStrings("arrived", five.tuple[2].string);

    const six = try httpTestFetch(a, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/r/6", .{srv.port}), null);
    try std.testing.expectEqualStrings("TooManyHttpRedirects", six.tuple[1].string);

    const six_ok = try httpTestFetch(a, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/r/6", .{srv.port}), try httpTestOpts(a, "max_redirects", 6));
    try std.testing.expectEqualStrings("arrived", six_ok.tuple[2].string);

    const none = try httpTestFetch(a, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/r/2", .{srv.port}), try httpTestOpts(a, "max_redirects", 0));
    try std.testing.expectEqualStrings("ok", none.tuple[0].atom);
    try std.testing.expectEqual(@as(i64, 302), none.tuple[1].integer);
}

test "http_start refuses options it does not know or cannot honour" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_]*const Value{ try make(a, .{ .string = "GET" }), try make(a, .{ .string = "http://127.0.0.1:9/" }), try make(a, .nil), try make(a, .{ .string = "" }) };
    const bad = [_]*const Value{
        try httpTestOpts(a, "timeout", 1000),
        try httpTestOpts(a, "timeout_ms", 0),
        try httpTestOpts(a, "timeout_ms", http_timeout_max_ms + 1),
        try httpTestOpts(a, "max_redirects", -1),
        try httpTestOpts(a, "max_redirects", http_redirects_max + 1),
        try make(a, .{ .integer = 5 }),
    };
    for (bad) |o| {
        try std.testing.expectError(error.TypeError, builtinHttpStart(a, &.{ base[0], base[1], base[2], base[3], o }));
    }
    for (http_slots) |s| try std.testing.expect(s.job == null);
}

// ============================================================
// http_start: what a remote server does is never a panic
// ============================================================

/// A loopback HTTP/1.1 server, one thread per connection, where every path
/// is a way for a response to go wrong. Before the tests below, every path
/// but /ok either killed the process or got a wrong answer.
const HttpBadServer = struct {
    listen_fd: c_int,
    port: u16,

    // "hello " * 1000, gzip level 9, cut in half: a body whose deflate
    // stream ends mid-symbol; std's flate decoder asserted on it
    const gz_half = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xed\xc4\x31\x0d\x00\x00\x08\x03\x30\x2b\x98\x23\xe1\x58\x82\xff";

    fn start() !*HttpBadServer {
        const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var addr = std.mem.zeroes(std.posix.sockaddr.in);
        addr.family = std.posix.AF.INET;
        addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.BindFailed;
        if (std.c.listen(fd, 64) < 0) return error.ListenFailed;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        _ = std.c.getsockname(fd, @ptrCast(&addr), &len);
        const s = try std.heap.page_allocator.create(HttpBadServer);
        s.* = .{ .listen_fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
        const t = try std.Thread.spawn(.{}, acceptLoop, .{s});
        t.detach();
        return s;
    }

    fn acceptLoop(s: *HttpBadServer) void {
        while (true) {
            const c = std.c.accept(s.listen_fd, null, null);
            if (c < 0) return;
            const t = std.Thread.spawn(.{}, serveOne, .{ s, c }) catch {
                _ = std.c.close(c);
                continue;
            };
            t.detach();
        }
    }

    fn send(c: c_int, bytes: []const u8) void {
        var at: usize = 0;
        while (at < bytes.len) {
            const n = std.c.write(c, bytes[at..].ptr, bytes.len - at);
            if (n <= 0) return;
            at += @intCast(n);
        }
    }

    /// Close with SO_LINGER 0: the client's next read is ECONNRESET.
    fn reset(c: c_int) void {
        const linger = extern struct { onoff: c_int, secs: c_int }{ .onoff = 1, .secs = 0 };
        _ = std.c.setsockopt(c, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger), @sizeOf(@TypeOf(linger)));
    }

    fn serveOne(s: *HttpBadServer, c: c_int) void {
        defer _ = std.c.close(c);
        var buf: [4096]u8 = undefined;
        var got: usize = 0;
        while (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") == null) {
            if (got == buf.len) return;
            const n = std.c.read(c, buf[got..].ptr, buf.len - got);
            if (n <= 0) return;
            got += @intCast(n);
            if (buf[0] == 0x16) return; // a TLS ClientHello: hang up on it
        }
        const head_end = std.mem.indexOf(u8, buf[0..got], "\r\n\r\n").?;
        const line_end = std.mem.indexOf(u8, buf[0..got], "\r\n").?;
        var parts = std.mem.splitScalar(u8, buf[0..line_end], ' ');
        _ = parts.next();
        const path = parts.next() orelse "/";
        var out: [256]u8 = undefined;
        const eq = std.mem.eql;
        if (eq(u8, path, "/ok")) {
            send(c, "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\narrived");
        } else if (eq(u8, path, "/headers")) {
            // the request's header lines, as the body
            const hs = buf[line_end + 2 .. head_end];
            send(c, std.fmt.bufPrint(&out, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{hs.len}) catch return);
            send(c, hs);
        } else if (eq(u8, path, "/to-https")) {
            // this same port, as https: the handshake fails, but first the
            // client has to get as far as starting one
            send(c, std.fmt.bufPrint(&out, "HTTP/1.1 301 Moved\r\nLocation: https://127.0.0.1:{d}/ok\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{s.port}) catch return);
        } else if (eq(u8, path, "/reset-mid-body") or eq(u8, path, "/reset-mid-redirect")) {
            const status = if (eq(u8, path, "/reset-mid-body")) "200 OK" else "302 Found\r\nLocation: /ok";
            send(c, std.fmt.bufPrint(&out, "HTTP/1.1 {s}\r\nContent-Length: 100000\r\nConnection: close\r\n\r\nyyyyyyyyyy", .{status}) catch return);
            httpTestNap(100);
            reset(c);
        } else if (eq(u8, path, "/reset-mid-chunked")) {
            send(c, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\na\r\nyyyyyyyyyy\r\n");
            httpTestNap(100);
            reset(c);
        } else if (eq(u8, path, "/close-mid-body")) {
            send(c, "HTTP/1.1 200 OK\r\nContent-Length: 100000\r\nConnection: close\r\n\r\nyyyyyyyyyy");
        } else if (eq(u8, path, "/gzip-cut")) {
            send(c, std.fmt.bufPrint(&out, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{gz_half.len}) catch return);
            send(c, gz_half);
        } else if (eq(u8, path, "/endless")) {
            // no length, never ends: the cap has to stop it as it arrives
            send(c, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n");
            const chunk: [65536]u8 = @splat('e');
            while (std.c.write(c, &chunk, chunk.len) > 0) {}
        } else if (eq(u8, path, "/head-with-length")) {
            // a HEAD answer names a length it will never send; hold the
            // connection open so a client that waits for it is caught
            send(c, "HTTP/1.1 200 OK\r\nContent-Length: 5000\r\nConnection: close\r\n\r\n");
            httpTestNap(3000);
        } else if (std.mem.startsWith(u8, path, "/drip")) {
            // a head at once, then a byte of body every 200ms for 4s: the
            // response has started when the deadline comes
            const head = if (eq(u8, path, "/drip"))
                "HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\n"
            else if (eq(u8, path, "/drip-chunked"))
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            else if (eq(u8, path, "/drip-redirect"))
                "HTTP/1.1 302 Found\r\nLocation: /ok\r\nContent-Length: 20\r\nConnection: close\r\n\r\n"
            else
                "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n";
            send(c, head);
            const byte = if (eq(u8, path, "/drip-chunked")) "1\r\nx\r\n" else "x";
            for (0..20) |_| {
                httpTestNap(200);
                if (std.c.write(c, byte.ptr, byte.len) <= 0) return;
            }
        } else if (eq(u8, path, "/bad-status")) {
            send(c, "HTTP/1.1 2x0 Nope\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        } else {
            send(c, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        }
    }
};

/// http_start then http_result until it answers, or 20s.
fn httpTestRequest(a: std.mem.Allocator, method: []const u8, url: []const u8, headers: *const Value) !*const Value {
    const h = try builtinHttpStart(a, &.{ try make(a, .{ .string = method }), try make(a, .{ .string = url }), headers, try make(a, .{ .string = "" }) });
    try std.testing.expect(h.integer >= 0);
    var tries: usize = 0;
    while (tries < 4000) : (tries += 1) {
        const r = try builtinHttpResult(a, &.{h});
        if (r.* != .nil) return r;
        httpTestNap(5);
    }
    return error.NeverAnswered;
}

fn httpTestExpectError(a: std.mem.Allocator, srv: *HttpBadServer, method: []const u8, path: []const u8, reason: []const u8) !void {
    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ srv.port, path });
    const r = try httpTestRequest(a, method, url, try make(a, .nil));
    std.testing.expectEqualStrings("error", r.tuple[0].atom) catch |err| {
        std.debug.print("{s} {s}: {s} {d}\n", .{ method, path, r.tuple[0].atom, r.tuple[1].integer });
        return err;
    };
    std.testing.expectEqualStrings(reason, r.tuple[1].string) catch |err| {
        std.debug.print("{s} {s}\n", .{ method, path });
        return err;
    };
}

test "http_start: a server that resets, cuts off, never ends or garbles a response is an {:error, reason}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;
    const srv = try HttpBadServer.start();

    // each of these killed the process: std's fetch answers a body read
    // that failed underneath HTTP with `bodyErr().?`, and body_err is null
    try httpTestExpectError(a, srv, "GET", "/reset-mid-body", "ConnectionResetByPeer");
    try httpTestExpectError(a, srv, "GET", "/reset-mid-chunked", "ConnectionResetByPeer");
    try httpTestExpectError(a, srv, "GET", "/reset-mid-redirect", "ConnectionResetByPeer");
    // std's flate decoder asserted on a gzip stream cut off mid-symbol
    try httpTestExpectError(a, srv, "GET", "/gzip-cut", "HttpBodyTruncated");
    // read until the heap was gone, then asked the kernel for an EINVAL read
    try httpTestExpectError(a, srv, "GET", "/endless", "ResponseTooLarge");
    // these did not panic, but answered wrong: {:ok, 200, <1000 of 100000
    // bytes>} and {:ok, 920, ""}
    try httpTestExpectError(a, srv, "GET", "/close-mid-body", "HttpBodyTruncated");
    try httpTestExpectError(a, srv, "GET", "/bad-status", "HttpHeadersInvalid");

    var url_buf: [96]u8 = undefined;
    // a HEAD answered with a Content-Length waited for a body that never comes
    const t0 = monoMs();
    const head = try httpTestRequest(a, "HEAD", try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/head-with-length", .{srv.port}), try make(a, .nil));
    try std.testing.expectEqual(@as(i64, 200), head.tuple[1].integer);
    try std.testing.expect(monoMs() - t0 < 2000);

    const ok = try httpTestRequest(a, "GET", try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/ok", .{srv.port}), try make(a, .nil));
    try std.testing.expectEqualStrings("arrived", ok.tuple[2].string);
}

test "http_start: an http:// url that redirects to https:// reaches the TLS handshake instead of panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;
    const srv = try HttpBadServer.start();
    var url_buf: [96]u8 = undefined;
    // The https:// side is this plain server, so the handshake fails; what
    // matters is that it is attempted. On main this panicked on `client.now.?`
    // before the ClientHello was written: only a request that *started* as
    // https:// loaded the CA bundle and set the clock.
    const r = try httpTestRequest(a, "GET", try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/to-https", .{srv.port}), try make(a, .nil));
    try std.testing.expectEqualStrings("error", r.tuple[0].atom);
    std.testing.expect(std.mem.startsWith(u8, r.tuple[1].string, "TlsInitializationFailed: ")) catch |err| {
        std.debug.print("got {s}\n", .{r.tuple[1].string});
        return err;
    };
}

test "http_start: a User-Agent (any case) replaces the client's, and a header that would split the request raises" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;
    const srv = try HttpBadServer.start();
    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/headers", .{srv.port});

    for ([_][]const u8{ "User-Agent", "user-agent", "USER-AGENT" }) |name| {
        const entries = try a.alloc(Value.MapEntry, 2);
        entries[0] = .{ .key = name, .val = try make(a, .{ .string = "blinks/1.0" }) };
        entries[1] = .{ .key = "X-Other", .val = try make(a, .{ .string = "yes" }) };
        const r = try httpTestRequest(a, "GET", url, try make(a, .{ .map = entries }));
        const sent = r.tuple[2].string;
        // one user-agent line, and it is ours
        var lines = std.mem.splitSequence(u8, sent, "\r\n");
        var uas: usize = 0;
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "user-agent:")) {
                uas += 1;
                try std.testing.expectEqualStrings("user-agent: blinks/1.0", line);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), uas);
        try std.testing.expect(std.mem.indexOf(u8, sent, "X-Other: yes") != null);
    }

    const bad = [_][2][]const u8{
        .{ "X-A", "a\r\nX-Injected: 1" },
        .{ "X-A", "a\nb" },
        .{ "X-A\r\nX-B", "c" },
        .{ "X:A", "c" },
        .{ "", "c" },
    };
    for (bad) |kv| {
        const entries = try a.alloc(Value.MapEntry, 1);
        entries[0] = .{ .key = kv[0], .val = try make(a, .{ .string = kv[1] }) };
        try std.testing.expectError(error.TypeError, builtinHttpStart(a, &.{ try make(a, .{ .string = "GET" }), try make(a, .{ .string = url }), try make(a, .{ .map = entries }), try make(a, .{ .string = "" }) }));
    }
    for (http_slots) |slot| try std.testing.expect(slot.job == null);
}

test "http_start: a deadline that comes while the body is arriving is {:error, \"timeout\"}, and the worker ends without a panic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;
    const srv = try HttpBadServer.start();
    const hang = try HttpTestServer.start();
    var url_buf: [96]u8 = undefined;

    // At 35-http-timeout's first commit (bc90267) each of the first four
    // answered timeout on time and then the worker panicked on std's
    // `bodyErr().?` as the cancelled read unwound through `fetch`, killing
    // the process a moment after the program had its answer. The fifth is
    // a TLS handshake the server never answers: cancelled mid-handshake.
    const cases = [_][]const u8{ "/drip", "/drip-chunked", "/drip-none", "/drip-redirect" };
    var urls: [cases.len + 1][]const u8 = undefined;
    for (cases, 0..) |path, k| urls[k] = try a.dupe(u8, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ srv.port, path }));
    urls[cases.len] = try a.dupe(u8, try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/hang", .{hang.port}));
    for (urls) |url| {
        const t0 = monoMs();
        const r = try httpTestFetch(a, url, try httpTestOpts(a, "timeout_ms", 500));
        const took = monoMs() - t0;
        std.testing.expectEqualStrings("timeout", r.tuple[1].string) catch |err| {
            std.debug.print("{s}: {s}\n", .{ url, r.tuple[1].string });
            return err;
        };
        try std.testing.expect(took >= 500 and took < 1500);
    }
    // the workers finish unwinding after the answers; give them the time
    // the panic used to take, then the next request is answered as usual
    httpTestNap(1000);
    const ok = try httpTestFetch(a, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/ok", .{srv.port}), null);
    try std.testing.expectEqualStrings("arrived", ok.tuple[2].string);
    for (http_slots) |slot| try std.testing.expect(slot.job == null);
}

// ── A WebSocket client, without stopping the program ─────────────────────
//
// ws_open(url, headers) -> handle
// ws_recv(handle)       -> [text | {:binary, bytes}, ...] | {:closed, reason}
// ws_send(handle, text) -> :ok | {:error, reason}
// ws_close(handle)      -> :ok
// ws_stats(handle)      -> %{received:, dropped:, bytes:, queued:, state:}
//
// The connection is a thread of its own (see websocket.zig); these only move
// things between its queue and the program. A handle that is not an open
// connection -- never opened, already closed, or already reported closed --
// is a TypeError, not a nil: a program that keeps polling a dead handle has
// a bug, and should hear about it. The WebAssembly build has no threads and
// no sockets, and refuses all five.

const websocket = @import("websocket.zig");

const builtinWsOpen_impl = if (is_wasm) native_stub.stub else builtinWsOpenNative;
const builtinWsRecv_impl = if (is_wasm) native_stub.stub else builtinWsRecvNative;
const builtinWsSend_impl = if (is_wasm) native_stub.stub else builtinWsSendNative;
const builtinWsClose_impl = if (is_wasm) native_stub.stub else builtinWsCloseNative;
const builtinWsStats_impl = if (is_wasm) native_stub.stub else builtinWsStatsNative;

fn wsHandle(args: []const *const Value, n: usize) EvalError!i64 {
    if (args.len != n or args[0].* != .integer) return error.TypeError;
    return args[0].integer;
}

fn wsError(err: websocket.Error) EvalError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadUrl, error.BadHandle => error.TypeError,
        error.NoFreeSlot => blk: {
            std.debug.print("ws_open: all {d} connections are in use; ws_close one first\n", .{websocket.slots_max});
            break :blk error.NotSupported;
        },
        error.ThreadSpawn => error.NotSupported,
    };
}

fn builtinWsOpenNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2 or args[0].* != .string) return error.TypeError;
    const entries: []const Value.MapEntry = if (args.len == 1) &.{} else switch (args[1].*) {
        .map => |m| m,
        .nil => &.{},
        else => return error.TypeError,
    };
    var headers_buf: [32]websocket.Header = undefined;
    if (entries.len > headers_buf.len) return error.TypeError;
    for (entries, 0..) |e, i| {
        if (e.val.* != .string) return error.TypeError;
        headers_buf[i] = .{ .name = e.key, .value = e.val.string };
    }
    const h = websocket.open(args[0].string, headers_buf[0..entries.len]) catch |err| return wsError(err);
    return make(allocator, .{ .integer = h });
}

fn builtinWsRecvNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    const h = try wsHandle(args, 1);
    switch (websocket.recv(h) catch |err| return wsError(err)) {
        .closed => |why| {
            const items = try allocator.alloc(*const Value, 2);
            items[0] = try make(allocator, .{ .atom = "closed" });
            items[1] = try make(allocator, .{ .string = allocator.dupe(u8, why) catch return error.OutOfMemory });
            return make(allocator, .{ .tuple = items });
        },
        .frames => |frames| {
            defer websocket.freeFrames(frames);
            const items = try allocator.alloc(*const Value, frames.len);
            for (frames, items) |f, *item| {
                const data = try make(allocator, .{ .string = allocator.dupe(u8, f.data) catch return error.OutOfMemory });
                if (!f.binary) {
                    item.* = data;
                    continue;
                }
                const pair = try allocator.alloc(*const Value, 2);
                pair[0] = try make(allocator, .{ .atom = "binary" });
                pair[1] = data;
                item.* = try make(allocator, .{ .tuple = pair });
            }
            return make(allocator, .{ .list = items });
        },
    }
}

fn builtinWsSendNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    const h = try wsHandle(args, 2);
    if (args[1].* != .string) return error.TypeError;
    const why = switch (websocket.send(h, args[1].string) catch |err| return wsError(err)) {
        .ok => return make(allocator, .{ .atom = "ok" }),
        .closed => "closed",
        .full => "SendQueueFull",
    };
    const items = try allocator.alloc(*const Value, 2);
    items[0] = try make(allocator, .{ .atom = "error" });
    items[1] = try make(allocator, .{ .string = why });
    return make(allocator, .{ .tuple = items });
}

fn builtinWsCloseNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    const h = try wsHandle(args, 1);
    websocket.close(h) catch |err| return wsError(err);
    return make(allocator, .{ .atom = "ok" });
}

fn builtinWsStatsNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    const h = try wsHandle(args, 1);
    const st = websocket.stats(h) catch |err| return wsError(err);
    const entries = try allocator.alloc(Value.MapEntry, 5);
    entries[0] = .{ .key = "received", .val = try make(allocator, .{ .integer = @intCast(st.received) }) };
    entries[1] = .{ .key = "dropped", .val = try make(allocator, .{ .integer = @intCast(st.dropped) }) };
    entries[2] = .{ .key = "bytes", .val = try make(allocator, .{ .integer = @intCast(st.bytes) }) };
    entries[3] = .{ .key = "queued", .val = try make(allocator, .{ .integer = @intCast(st.queued) }) };
    entries[4] = .{ .key = "state", .val = try make(allocator, .{ .atom = @tagName(st.state) }) };
    return make(allocator, .{ .map = entries });
}

fn builtinTcpConnectNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .integer) return error.TypeError;
    if (is_wasm) return error.NotSupported;

    // An empty host is not a default. macOS `getaddrinfo` resolves an empty
    // node to loopback, so `tcp_connect("", 80)` quietly connected to this
    // machine -- the one answer a caller who passed nothing cannot check.
    if (args[0].string.len == 0) return make(allocator, .nil);

    var host_buf: [256]u8 = undefined;
    if (args[0].string.len >= host_buf.len) return make(allocator, .nil);
    @memcpy(host_buf[0..args[0].string.len], args[0].string);
    host_buf[args[0].string.len] = 0;
    const host: [*:0]const u8 = @ptrCast(&host_buf);

    // Clamping is what made 99999 and 131071 both connect to a listener on
    // 65535. A port that is not a port is a connection that cannot be made.
    if (args[1].integer < 0 or args[1].integer > 65535) return make(allocator, .nil);

    var port_buf: [8]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_buf, "{d}\x00", .{@as(u16, @intCast(args[1].integer))}) catch return make(allocator, .nil);
    const port: [*:0]const u8 = @ptrCast(port_text.ptr);

    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.posix.AF.UNSPEC;
    hints.socktype = std.posix.SOCK.STREAM;

    var res: ?*std.c.addrinfo = null;
    if (std.c.getaddrinfo(host, port, &hints, &res) != @as(std.c.EAI, @enumFromInt(0))) return make(allocator, .nil);
    defer if (res) |r| std.c.freeaddrinfo(r);

    // The first address that both opens and connects wins; the rest are the
    // other families the name resolved to.
    var it = res;
    while (it) |info| : (it = info.next) {
        const addr = info.addr orelse continue;
        const fd = std.c.socket(@intCast(info.family), @intCast(info.socktype), @intCast(info.protocol));
        if (fd < 0) continue;
        if (std.c.connect(fd, addr, info.addrlen) == 0) {
            return make(allocator, .{ .integer = @intCast(fd) });
        }
        _ = std.c.close(fd);
    }
    return make(allocator, .nil);
}

/// tcp_accept(server_fd: Int) -> Int | nil
/// Blocking accept by default. Returns nil if socket is non-blocking and
/// no connection is pending (WouldBlock/EAGAIN).
fn builtinTcpAcceptNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const server_fd: std.posix.socket_t = @intCast(args[0].integer);
    sweepLingering();
    var client_addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    const accepted = std.c.accept(server_fd, &client_addr, &addr_len);
    if (accepted < 0) {
        // Non-blocking mode: no connection pending, return nil
        if (std.c._errno().* == @intFromEnum(std.c.E.AGAIN)) return make(allocator, .nil);
        return error.NotSupported;
    }
    const client_fd: std.posix.socket_t = accepted;
    return make(allocator, .{ .integer = @intCast(client_fd) });
}

/// tcp_read(fd: Int) -> String | nil
/// Reads up to 64KB. Returns nil if socket is non-blocking and no data
/// is available (WouldBlock/EAGAIN).
fn builtinTcpReadNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    var buf: [65536]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch |err| {
        if (err == error.WouldBlock) {
            // Non-blocking mode: no data available, return nil
            return make(allocator, .nil);
        }
        // A peer that resets the connection has ended the stream, which is
        // what a reader wants to hear. Reporting it as a failed builtin
        // stopped the program instead -- an HTTP client reading from a server
        // that hung up rudely died rather than finishing its response.
        if (err == error.ConnectionResetByPeer) {
            return make(allocator, .{ .string = "" });
        }
        return error.NotSupported;
    };
    const owned = allocator.dupe(u8, buf[0..n]) catch return error.OutOfMemory;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = owned };
    return result;
}

fn monoMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// How long tcp_write waits on a reader that takes nothing at all before it
/// gives up on it. Measured on the clock, from the last byte the kernel took.
const write_stall_ms: i64 = 10_000;

/// tcp_write(fd: Int, data: String) -> :ok or :error
fn builtinTcpWriteNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .integer or args[1].* != .string) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    // All of it, or :error. One write() on a non-blocking socket takes what
    // fits in the socket buffer and says how much, so a full buffer is waited
    // on. The wait used to be a counter that added 100ms for every full
    // buffer, but poll() comes back as soon as the reader takes a few KB, so
    // a counted "10 seconds" was about a hundred refills: 1100ms counted in
    // 42ms of real time on a 2.9MB body, and a 37.7MB body cut off at 23-31MB.
    // Now the deadline is real time since the reader last took a byte: a
    // reader that keeps reading gets all of it however large, and one that
    // stops for write_stall_ms is :error.
    //
    // What this does not fix: the wait blocks the calling thread, and
    // `blimp --serve` runs every request on one. A reader that stops holds
    // every other request for write_stall_ms; one that takes a byte every few
    // seconds holds them for as long as it likes. Writes that park what did
    // not fit and resume from tcp_poll are the fix for that, and a different
    // contract for tcp_write.
    const bytes = args[1].string;
    var off: usize = 0;
    var last_progress = monoMs();
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n > 0) {
            off += @intCast(n);
            last_progress = monoMs();
            continue;
        }
        const e = std.c._errno().*;
        if (n < 0 and e == @intFromEnum(std.posix.E.INTR)) continue;
        if (n < 0 and e == @intFromEnum(std.posix.E.AGAIN)) { // EWOULDBLOCK is the same number
            const left = write_stall_ms - (monoMs() - last_progress);
            if (left <= 0) break;
            var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
            _ = std.posix.poll(&pfd, @intCast(@min(left, 1000))) catch break;
            continue;
        }
        break;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = if (off == bytes.len) "ok" else "error" };
    return result;
}

/// tcp_write_some(fd: Int, data: String) -> Int | :error
///
/// One send() that never waits: the number of bytes of `data` the kernel took,
/// from 0 (its send buffer is full) up to `length(data)`. The caller keeps the
/// rest, `slice(data, n, length(data))`, and offers it again once
/// `tcp_poll_write` says the socket has room. :error when the peer is gone
/// (reset, or closed and then written to).
///
/// This is the write a program that serves many sockets from one thread
/// needs. `tcp_write` takes all of it or gives up, so a peer that stops
/// reading holds the only thread for as long as tcp_write waits for it --
/// 10s since the reader last took a byte -- and every other client waits
/// with it.
///
/// A socket nobody called tcp_set_nonblocking on is made non-blocking for the
/// one send() and put back, so it cannot block here either. Not MSG_DONTWAIT:
/// macOS does not honour it on a blocking TCP socket. Measured, a 256KB
/// send(MSG_DONTWAIT) to a loopback peer that never reads sat in the kernel
/// until it was killed, where Linux answers EAGAIN.
///
/// Raises TypeError for an fd that is not an open socket: that is a bug in the
/// program (closed twice, or never a socket), not something the peer did.
fn builtinTcpWriteSomeNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .integer or args[1].* != .string) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    const bytes = args[1].string;
    if (bytes.len == 0) return make(allocator, .{ .integer = 0 });
    const flags: u32 = if (@hasDecl(std.c.MSG, "NOSIGNAL")) std.c.MSG.NOSIGNAL else 0;
    const fl = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (fl < 0) return error.TypeError; // not an open fd
    const nonblock: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (fl & nonblock == 0) {
        if (std.c.fcntl(fd, std.posix.F.SETFL, fl | nonblock) < 0) return error.NotSupported;
    }
    defer if (fl & nonblock == 0) {
        _ = std.c.fcntl(fd, std.posix.F.SETFL, fl);
    };
    while (true) {
        const n = std.c.send(fd, bytes.ptr, bytes.len, flags);
        if (n >= 0) return make(allocator, .{ .integer = @intCast(n) });
        const e: std.posix.E = @enumFromInt(std.c._errno().*);
        switch (e) {
            .INTR => continue,
            .AGAIN => return make(allocator, .{ .integer = 0 }), // EWOULDBLOCK is the same number
            .BADF, .NOTSOCK, .FAULT, .INVAL => return error.TypeError,
            else => return make(allocator, .{ .atom = "error" }), // EPIPE, ECONNRESET, ENOTCONN, ...
        }
    }
}

/// tcp_poll_write(fds: List of Int, timeout_ms: Int) -> List of Int
///
/// `tcp_poll` for the other direction: the fds a `tcp_write_some` would take
/// at least one byte on without waiting, in the order given. timeout_ms as in
/// tcp_poll: -1 waits for one, 0 answers at once. Like tcp_poll, an fd that
/// has hung up, failed, or is not open is reported ready, because a write to
/// it will not wait -- it answers :error, and the caller learns the socket is
/// dead instead of waiting on it forever.
fn builtinTcpPollWriteNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .list or args[1].* != .integer) return error.TypeError;
    const fd_list = args[0].list;
    if (args[1].integer < -1 or args[1].integer > std.math.maxInt(i32)) return error.TypeError;
    const timeout_ms: i32 = @intCast(args[1].integer);
    sweepLingering();
    const pollfds = allocator.alloc(std.posix.pollfd, fd_list.len) catch return error.OutOfMemory;
    for (fd_list, 0..) |fd_val, i| {
        if (fd_val.* != .integer) return error.TypeError;
        pollfds[i] = .{ .fd = @intCast(fd_val.integer), .events = std.posix.POLL.OUT, .revents = 0 };
    }
    _ = std.posix.poll(pollfds, timeout_ms) catch return error.NotSupported;
    const ready_events = std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;
    var ready: std.ArrayList(*const Value) = .empty;
    for (pollfds) |pfd| {
        if (pfd.revents & ready_events == 0) continue;
        ready.append(allocator, try make(allocator, .{ .integer = @intCast(pfd.fd) })) catch return error.OutOfMemory;
    }
    return make(allocator, .{ .list = ready.toOwnedSlice(allocator) catch return error.OutOfMemory });
}

// ============================================================
// tcp_write_some / tcp_poll_write tests
// ============================================================

/// A connected loopback pair: `server` is the accepted end, `client` the
/// dialled one. Both blocking, which is the case tcp_write_some must not wait
/// in.
const LoopbackPair = struct {
    server: c_int,
    client: c_int,

    fn open() !LoopbackPair {
        const l = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (l < 0) return error.SocketFailed;
        defer _ = std.c.close(l);
        var addr = std.mem.zeroes(std.posix.sockaddr.in);
        addr.family = std.posix.AF.INET;
        addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
        if (std.c.bind(l, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.BindFailed;
        if (std.c.listen(l, 1) < 0) return error.ListenFailed;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        _ = std.c.getsockname(l, @ptrCast(&addr), &len);
        const c = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (c < 0) return error.SocketFailed;
        if (std.c.connect(c, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.ConnectFailed;
        const s = std.c.accept(l, null, null);
        if (s < 0) return error.AcceptFailed;
        return .{ .server = s, .client = c };
    }

    fn close(p: LoopbackPair) void {
        _ = std.c.close(p.server);
        _ = std.c.close(p.client);
    }
};

test "tcp_write_some to a peer that never reads takes what fits and never waits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pair = try LoopbackPair.open();
    defer pair.close();

    const fd = try make(a, .{ .integer = pair.server });
    const chunk = try a.alloc(u8, 256 * 1024);
    @memset(chunk, 'x');
    const data = try make(a, .{ .string = chunk });

    // Offer 256KB at a time until the kernel takes nothing. tcp_write would
    // sit in here for 10 seconds; this must come back from every call at once.
    const t0 = monoMs();
    var taken: usize = 0;
    var calls: usize = 0;
    while (calls < 10_000) : (calls += 1) {
        const r = try builtinTcpWriteSomeNative(a, &.{ fd, data });
        try std.testing.expect(r.* == .integer);
        if (r.integer == 0) break;
        try std.testing.expect(r.integer <= chunk.len);
        taken += @intCast(r.integer);
    }
    const took = monoMs() - t0;
    try std.testing.expect(calls < 10_000); // it did fill up
    try std.testing.expect(taken > 0);
    try std.testing.expect(took < 1000);

    // Not asserted: that tcp_poll_write now says "not writable". macOS grows
    // a loopback send buffer while the peer's receive buffer has room, so a
    // socket that just answered EAGAIN can be writable 20ms later without the
    // reader taking anything. What is asserted is that asking does not wait
    // past its timeout.
    const fds = try make(a, .{ .list = try a.dupe(*const Value, &.{fd}) });
    const t1 = monoMs();
    _ = try builtinTcpPollWriteNative(a, &.{ fds, try make(a, .{ .integer = 0 }) });
    try std.testing.expect(monoMs() - t1 < 100);

    // The reader drains everything; the socket is writable again, and the
    // bytes that arrived are exactly the ones reported taken.
    var got: usize = 0;
    var buf: [65536]u8 = undefined;
    while (got < taken) {
        const n = std.c.read(pair.client, &buf, buf.len);
        try std.testing.expect(n > 0);
        got += @intCast(n);
    }
    try std.testing.expectEqual(taken, got);
    const ready = try builtinTcpPollWriteNative(a, &.{ fds, try make(a, .{ .integer = 1000 }) });
    try std.testing.expectEqual(@as(usize, 1), ready.list.len);
    try std.testing.expectEqual(@as(i64, pair.server), ready.list[0].integer);
    const again = try builtinTcpWriteSomeNative(a, &.{ fd, data });
    try std.testing.expect(again.integer > 0);
}

test "tcp_write_some says :error once the peer is gone, and raises on a non-socket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pair = try LoopbackPair.open();
    defer _ = std.c.close(pair.server);
    // SO_LINGER 0: the client's close sends RST, so the server's next send is
    // ECONNRESET/EPIPE, not a write into a half-closed connection that
    // succeeds once.
    const lin = extern struct { onoff: c_int, linger: c_int }{ .onoff = 1, .linger = 0 };
    _ = std.c.setsockopt(pair.client, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&lin), @sizeOf(@TypeOf(lin)));
    _ = std.c.close(pair.client);

    const fd = try make(a, .{ .integer = pair.server });
    const data = try make(a, .{ .string = "hello" });
    var r = try builtinTcpWriteSomeNative(a, &.{ fd, data });
    var tries: usize = 0;
    while (r.* == .integer and tries < 100) : (tries += 1) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5_000_000 };
        _ = std.c.nanosleep(&ts, null);
        r = try builtinTcpWriteSomeNative(a, &.{ fd, data });
    }
    try std.testing.expectEqualStrings("error", r.atom);

    // A gone peer is reported writable, so a program waiting on it finds out.
    const fds = try make(a, .{ .list = try a.dupe(*const Value, &.{fd}) });
    const ready = try builtinTcpPollWriteNative(a, &.{ fds, try make(a, .{ .integer = 0 }) });
    try std.testing.expectEqual(@as(usize, 1), ready.list.len);

    // stdin-ish: an fd that is not open is the program's bug.
    const bad = try make(a, .{ .integer = 1_000_000 });
    try std.testing.expectError(error.TypeError, builtinTcpWriteSomeNative(a, &.{ bad, data }));
    try std.testing.expectError(error.TypeError, builtinTcpWriteSomeNative(a, &.{ fd, fd }));
    try std.testing.expectError(error.TypeError, builtinTcpPollWriteNative(a, &.{ fds, try make(a, .{ .integer = -2 }) }));
}

// ------------------------------------------------------------
// Closing a socket without resetting it
// ------------------------------------------------------------
//
// close() on a TCP socket whose receive buffer still holds bytes the program
// never read does not send FIN. It sends RST, on Linux and macOS alike, and
// RST throws away whatever of the response is still in the send buffer; the
// peer's next read() is ECONNRESET. A server that answers without reading
// every byte of the request -- it read once before the request arrived, or
// the request came in two segments, or it was bigger than one read -- loses
// the tail of every response bigger than what the kernel has sent so far.
// Measured: `blimp --serve test/serve/big.blimp`, 12 slow-reader runs; all 5
// that failed had read nothing (EAGAIN) and closed with 60 request bytes
// unread and 0.5-0.9MB unsent; all 7 that passed had read the 60 bytes.
//
// So tcp_close closes the way nginx's lingering_close does: read and discard
// what has arrived, shutdown(SHUT_WR) so the peer gets FIN after the last
// queued byte, and keep the fd open, reading and discarding, until the peer
// closes its side or `linger_ms` passes. The fds kept are swept, never
// waited on: every tcp_poll, tcp_accept and tcp_close drains them without
// blocking, so a site that polls every tick closes them within a tick of
// the peer hanging up. A program that never calls any of them again keeps
// them open until it exits.

const linger_ms: i64 = 30_000;
const LingerFd = struct { fd: std.posix.fd_t, deadline: i64 };
var lingering: [256]LingerFd = undefined;
var lingering_len: usize = 0;

const DrainResult = enum { open, gone };

/// Reads and throws away what is waiting on a non-blocking fd. `gone` when
/// the peer has closed its side or the socket has failed.
fn drainInput(fd: std.posix.fd_t) DrainResult {
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n > 0) continue;
        if (n == 0) return .gone;
        const e = std.c._errno().*;
        if (e == @intFromEnum(std.posix.E.INTR)) continue;
        if (e == @intFromEnum(std.posix.E.AGAIN)) return .open;
        return .gone;
    }
}

/// Drains every lingering fd once; closes those whose peer has gone or whose
/// time is up.
fn sweepLingering() void {
    if (lingering_len == 0) return;
    const now = monoMs();
    var i: usize = 0;
    while (i < lingering_len) {
        const l = lingering[i];
        if (drainInput(l.fd) == .gone or now >= l.deadline) {
            _ = std.c.close(l.fd);
            lingering_len -= 1;
            lingering[i] = lingering[lingering_len];
        } else i += 1;
    }
}

/// tcp_close(fd: Int) -> nil
fn builtinTcpCloseNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    sweepLingering();
    for (lingering[0..lingering_len]) |l| if (l.fd == fd) return make(allocator, .nil); // closed already
    // Not a socket (or not connected): nothing to protect, close it.
    if (std.c.shutdown(fd, 1) != 0) { // SHUT_WR is 1 on Linux and macOS
        _ = std.c.close(fd);
        return make(allocator, .nil);
    }
    const fl = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    const nonblock: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (fl < 0 or std.c.fcntl(fd, std.posix.F.SETFL, fl | nonblock) < 0 or drainInput(fd) == .gone) {
        _ = std.c.close(fd);
        return make(allocator, .nil);
    }
    if (lingering_len == lingering.len) {
        // Full: the one nearest its deadline goes now.
        var oldest: usize = 0;
        for (lingering[0..lingering_len], 0..) |l, j| if (l.deadline < lingering[oldest].deadline) {
            oldest = j;
        };
        _ = std.c.close(lingering[oldest].fd);
        lingering[oldest] = lingering[lingering_len - 1];
        lingering_len -= 1;
    }
    lingering[lingering_len] = .{ .fd = fd, .deadline = monoMs() + linger_ms };
    lingering_len += 1;
    return make(allocator, .nil);
}

// ============================================================
// WebSocket builtins
// ============================================================

// RFC 6455 Section 1.3 fixed magic string. Used to derive
// Sec-WebSocket-Accept from the client's Sec-WebSocket-Key.
const ws_magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// ws_accept_key(client_key: String) -> String
/// Computes the Sec-WebSocket-Accept value for the WS handshake.
/// SHA-1(client_key + magic_guid) then Base64-encoded.
fn builtinWsAcceptKeyNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const client_key = args[0].string;

    // Concatenate client key + magic GUID
    var concat_buf: [256]u8 = undefined;
    if (client_key.len + ws_magic_guid.len > concat_buf.len) return error.NotSupported;
    @memcpy(concat_buf[0..client_key.len], client_key);
    @memcpy(concat_buf[client_key.len..][0..ws_magic_guid.len], ws_magic_guid);
    const to_hash = concat_buf[0 .. client_key.len + ws_magic_guid.len];

    // SHA-1 hash
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(to_hash);
    const digest = hasher.finalResult();

    // Base64 encode
    const base64_encoder = std.base64.standard.Encoder;
    const encoded_len = base64_encoder.calcSize(digest.len);
    const encoded = allocator.alloc(u8, encoded_len) catch return error.OutOfMemory;
    _ = base64_encoder.encode(encoded, &digest);

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = encoded };
    return result;
}

/// ws_read_frame(fd: Int) -> String | nil
/// Reads and decodes one WebSocket text frame from fd.
/// Returns nil if the connection is closed or a close frame is received.
/// Handles client masking. Only supports text frames (opcode 0x1).
/// Auto-responds to Ping with Pong.
fn builtinWsReadFrameNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);

    // Read first 2 bytes (frame header)
    var header: [2]u8 = undefined;
    const h_n = std.posix.read(fd, &header) catch {
        return make(allocator, .nil);
    };
    if (h_n < 2) {
        return make(allocator, .nil);
    }

    const opcode = header[0] & 0x0F;
    const masked = (header[1] & 0x80) != 0;
    var payload_len: u64 = header[1] & 0x7F;

    // Extended payload length
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        const ext_n = std.posix.read(fd, &ext) catch {
            return make(allocator, .nil);
        };
        if (ext_n < 2) {
            return make(allocator, .nil);
        }
        payload_len = @as(u64, ext[0]) << 8 | @as(u64, ext[1]);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        const ext_n = std.posix.read(fd, &ext) catch {
            return make(allocator, .nil);
        };
        if (ext_n < 8) {
            return make(allocator, .nil);
        }
        payload_len = 0;
        for (ext) |b| {
            payload_len = (payload_len << 8) | @as(u64, b);
        }
    }

    // Read masking key if present
    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        const m_n = std.posix.read(fd, &mask_key) catch {
            return make(allocator, .nil);
        };
        if (m_n < 4) {
            return make(allocator, .nil);
        }
    }

    // Limit payload to 1MB to prevent DOS
    if (payload_len > 1048576) {
        return make(allocator, .nil);
    }

    // Read payload
    const plen: usize = @intCast(payload_len);
    const payload = allocator.alloc(u8, plen) catch return error.OutOfMemory;
    var total_read: usize = 0;
    while (total_read < plen) {
        const n = std.posix.read(fd, payload[total_read..]) catch {
            return make(allocator, .nil);
        };
        if (n == 0) {
            return make(allocator, .nil);
        }
        total_read += n;
    }

    // Unmask payload
    if (masked) {
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask_key[i % 4];
        }
    }

    // Handle opcode
    switch (opcode) {
        0x1 => {
            // Text frame -- return the payload as a string
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .string = payload };
            return result;
        },
        0x8 => {
            // Close frame -- return nil
            return make(allocator, .nil);
        },
        0x9 => {
            // Ping -- send Pong with same payload, then read next frame
            wsWriteFrame(fd, 0xA, payload) catch {};
            return builtinWsReadFrameNative(allocator, args);
        },
        0xA => {
            // Pong -- ignore, read next frame
            return builtinWsReadFrameNative(allocator, args);
        },
        else => {
            // Unsupported opcode -- return nil
            return make(allocator, .nil);
        },
    }
}

/// ws_write_frame(fd: Int, data: String) -> nil
/// Writes a WebSocket text frame (server-to-client, unmasked).
fn builtinWsWriteFrameNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .integer or args[1].* != .string) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    const data = args[1].string;
    // Don't crash on dead fds -- return :error instead
    wsWriteFrame(fd, 0x1, data) catch {
        const result = allocator.create(Value) catch return error.OutOfMemory;
        result.* = Value{ .atom = "error" };
        return result;
    };
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = "ok" };
    return result;
}

/// Internal: write a WS frame with given opcode and payload.
fn wsWriteFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) !void {
    // Build frame header
    var header_buf: [10]u8 = undefined;
    var header_len: usize = 2;

    header_buf[0] = 0x80 | opcode; // FIN + opcode
    if (payload.len < 126) {
        header_buf[1] = @intCast(payload.len);
    } else if (payload.len <= 65535) {
        header_buf[1] = 126;
        header_buf[2] = @intCast((payload.len >> 8) & 0xFF);
        header_buf[3] = @intCast(payload.len & 0xFF);
        header_len = 4;
    } else {
        header_buf[1] = 127;
        const len64: u64 = @intCast(payload.len);
        inline for (0..8) |i| {
            header_buf[2 + i] = @intCast((len64 >> @intCast(56 - i * 8)) & 0xFF);
        }
        header_len = 10;
    }

    // Write header
    if (std.c.write(fd, &header_buf, header_len) < 0) return error.NotSupported;
    // Write payload
    if (payload.len > 0) {
        if (std.c.write(fd, payload.ptr, payload.len) < 0) return error.NotSupported;
    }
}

// ============================================================
// View diffing
// ============================================================

/// view_diff(old_tree, new_tree) -> List of patch maps
/// Compares two view_node trees and returns a list of patches.
/// Each patch is %{op: "replace"|"text"|"attrs", path: "0.1.2", value: "..."}
fn builtinViewDiffNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;

    var patches: std.ArrayListUnmanaged(*const Value) = .empty;
    diffViewNodes(allocator, args[0], args[1], "", &patches) catch return error.OutOfMemory;

    const result = allocator.create(Value) catch return error.OutOfMemory;
    const items = patches.toOwnedSlice(allocator) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

fn diffViewNodes(
    allocator: std.mem.Allocator,
    old: *const Value,
    new: *const Value,
    path: []const u8,
    patches: *std.ArrayListUnmanaged(*const Value),
) !void {
    // If structurally equal, no patches needed
    if (old.eql(new.*)) return;

    // Both view_nodes: compare structurally
    if (old.* == .view_node and new.* == .view_node) {
        const o = old.view_node;
        const n = new.view_node;

        // Different tags -> full replace
        if (!std.mem.eql(u8, o.tag, n.tag)) {
            try appendReplacePatch(allocator, patches, path, new);
            return;
        }

        // Different attribute count -> full replace
        if (o.attrs.len != n.attrs.len) {
            try appendReplacePatch(allocator, patches, path, new);
            return;
        }

        // Check attrs for changes
        var attrs_changed = false;
        for (o.attrs, n.attrs) |oa, na| {
            if (!std.mem.eql(u8, oa.key, na.key) or !oa.val.eql(na.val.*)) {
                attrs_changed = true;
                break;
            }
        }
        if (attrs_changed) {
            try appendAttrsPatch(allocator, patches, path, n.attrs);
        }

        // Different child count -> full replace
        if (o.children.len != n.children.len) {
            try appendReplacePatch(allocator, patches, path, new);
            return;
        }

        // Recurse into children
        for (o.children, n.children, 0..) |old_child, new_child, i| {
            const child_path = if (path.len == 0)
                std.fmt.allocPrint(allocator, "{d}", .{i}) catch return error.OutOfMemory
            else
                std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, i }) catch return error.OutOfMemory;
            try diffViewNodes(allocator, old_child, new_child, child_path, patches);
        }
        return;
    }

    // Both strings: text patch
    if (old.* == .string and new.* == .string) {
        if (!std.mem.eql(u8, old.string, new.string)) {
            try appendTextPatch(allocator, patches, path, new.string);
        }
        return;
    }

    // Both integers
    if (old.* == .integer and new.* == .integer) {
        if (old.integer != new.integer) {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{new.integer}) catch return;
            const owned = try allocator.dupe(u8, s);
            try appendTextPatch(allocator, patches, path, owned);
        }
        return;
    }

    // Type changed or unsupported combination -> full replace
    try appendReplacePatch(allocator, patches, path, new);
}

fn appendReplacePatch(
    allocator: std.mem.Allocator,
    patches: *std.ArrayListUnmanaged(*const Value),
    path: []const u8,
    node: *const Value,
) !void {
    // Render the new node to HTML
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    renderHtml(allocator, node, &buf) catch return;
    const html = buf.toOwnedSlice(allocator) catch return;

    const patch = try makePatchMap(allocator, "replace", path, html);
    try patches.append(allocator, patch);
}

fn appendTextPatch(
    allocator: std.mem.Allocator,
    patches: *std.ArrayListUnmanaged(*const Value),
    path: []const u8,
    text_val: []const u8,
) !void {
    const patch = try makePatchMap(allocator, "text", path, text_val);
    try patches.append(allocator, patch);
}

fn appendAttrsPatch(
    allocator: std.mem.Allocator,
    patches: *std.ArrayListUnmanaged(*const Value),
    path: []const u8,
    attrs: []const Value.ViewNode.ViewAttr,
) !void {
    // Serialize attrs as a simple string for now: "key=val,key2=val2"
    var attr_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (attrs, 0..) |attr, i| {
        if (i > 0) attr_buf.appendSlice(allocator, ",") catch return;
        attr_buf.appendSlice(allocator, attr.key) catch return;
        attr_buf.appendSlice(allocator, "=") catch return;
        var val_buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&val_buf);
        attr.val.format(&fbs);
        attr_buf.appendSlice(allocator, fbs.buffered()) catch return;
    }
    const attr_str = attr_buf.toOwnedSlice(allocator) catch return;
    const patch = try makePatchMap(allocator, "attrs", path, attr_str);
    try patches.append(allocator, patch);
}

fn makePatchMap(
    allocator: std.mem.Allocator,
    op: []const u8,
    path: []const u8,
    value_str: []const u8,
) !*const Value {
    // Create a map: %{op: "replace", path: "0.1", value: "<html>"}
    const entries = try allocator.alloc(Value.MapEntry, 3);

    const op_val = try allocator.create(Value);
    op_val.* = Value{ .string = op };
    entries[0] = .{ .key = "op", .val = op_val };

    const path_val = try allocator.create(Value);
    path_val.* = Value{ .string = if (path.len > 0) path else "" };
    entries[1] = .{ .key = "path", .val = path_val };

    const value_val = try allocator.create(Value);
    value_val.* = Value{ .string = value_str };
    entries[2] = .{ .key = "value", .val = value_val };

    const result = try allocator.create(Value);
    result.* = Value{ .map = entries };
    return result;
}

// ============================================================
// Process builtins (fork, waitpid, exit)
// ============================================================

/// fork() -> Int
/// Returns 0 in the child process, the child PID in the parent.
/// Returns -1 on error.
fn builtinForkNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    const result_val = allocator.create(Value) catch return error.OutOfMemory;
    const fork_result = std.c.fork();
    if (fork_result < 0) {
        result_val.* = Value{ .integer = -1 };
        return result_val;
    }
    if (fork_result == 0) {
        // Child process
        result_val.* = Value{ .integer = 0 };
    } else {
        // Parent process -- fork_result is the child PID
        result_val.* = Value{ .integer = @intCast(fork_result) };
    }
    return result_val;
}

/// waitpid(pid: Int, nohang: Bool) -> Int
/// Waits for a child process. If nohang is true, returns immediately.
/// Returns the pid if the child exited, 0 if nohang and child still running, -1 on error.
fn builtinWaitpidNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args[0].* != .integer) return error.TypeError;
    const pid: std.posix.pid_t = @intCast(args[0].integer);
    const nohang = if (args.len >= 2) switch (args[1].*) {
        .boolean => |b| b,
        else => false,
    } else false;

    const flags: u32 = if (nohang) @as(u32, 1) else 0; // WNOHANG = 1 on macOS/Linux
    const result_val = allocator.create(Value) catch return error.OutOfMemory;
    var status: c_int = undefined;
    const waited = std.c.waitpid(pid, &status, @intCast(flags));
    result_val.* = Value{ .integer = @intCast(waited) };
    return result_val;
}

/// exit(code: Int) -> never returns
/// Exits the current process with the given status code.
fn builtinExitNative(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const code: u8 = @intCast(@max(0, @min(255, args[0].integer)));
    std.process.exit(code);
}

// ============================================================
// Non-blocking IO builtins
// ============================================================

/// tcp_set_nonblocking(fd: Int) -> :ok
/// Sets a socket to non-blocking mode. After this, tcp_accept and tcp_read
/// will return nil instead of blocking when no data/connection is ready.
fn builtinTcpSetNonblockingNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);

    // Get current flags and add O_NONBLOCK (same pattern as Zig stdlib)
    const fl_flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (fl_flags < 0) return error.NotSupported;
    const nonblock: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (std.c.fcntl(fd, std.posix.F.SETFL, fl_flags | nonblock) < 0) return error.NotSupported;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = "ok" };
    return result;
}

/// tcp_poll(fds: List of Int, timeout_ms: Int) -> List of Int
/// Polls a list of file descriptors for readability.
/// Returns a list of fds that are ready to read (or accept).
/// timeout_ms: -1 = block forever, 0 = return immediately, >0 = wait up to N ms.
fn builtinTcpPollNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .list or args[1].* != .integer) return error.TypeError;

    const fd_list = args[0].list;
    const timeout_ms: i32 = @intCast(args[1].integer);
    sweepLingering();

    // Build pollfd array
    const pollfds = allocator.alloc(std.posix.pollfd, fd_list.len) catch return error.OutOfMemory;
    for (fd_list, 0..) |fd_val, i| {
        if (fd_val.* != .integer) return error.TypeError;
        pollfds[i] = .{
            .fd = @intCast(fd_val.integer),
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
    }

    // Call poll
    _ = std.posix.poll(pollfds, timeout_ms) catch return error.NotSupported;

    // Collect ready fds
    const ready_events = std.posix.POLL.IN | std.posix.POLL.HUP |
        std.posix.POLL.ERR | std.posix.POLL.NVAL;
    var ready_list: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
    for (pollfds) |pfd| {
        // Not `POLL.IN` alone. An fd that has hung up, errored, or was never
        // valid is one a read will not block on -- it returns 0 or fails --
        // and reporting it as not ready leaves the caller with nothing to
        // wait for and nothing to do, which is a spin.
        //
        // On macOS a `poll` of /dev/null answers at once with none of these
        // bits, so `blimp prog.blimp < /dev/null` burned a core: the async
        // scheduler asked for a 1000ms wait, got an immediate answer with
        // nothing ready, and went round again. Callers that watch sockets
        // gain from it too -- a peer that hung up now shows up as readable,
        // gets read to end of stream and closed, instead of never appearing.
        if (pfd.revents & ready_events != 0) {
            const fd_val = allocator.create(Value) catch return error.OutOfMemory;
            fd_val.* = Value{ .integer = @intCast(pfd.fd) };
            ready_list.append(allocator, fd_val) catch return error.OutOfMemory;
        }
    }

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = ready_list.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

test "type_of view_node returns :view_node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try alloc.create(Value);
    const node_view = try alloc.create(Value.ViewNode);
    node_view.* = .{ .tag = "text", .attrs = &.{}, .children = &.{} };
    node.* = Value{ .view_node = node_view };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = node;
    const result = try builtinTypeOf(alloc, args);
    try std.testing.expect(result.eql(Value{ .atom = "view_node" }));
}

// ============================================================
// WebSocket tests
// ============================================================

test "ws_accept_key produces correct accept value for RFC example" {
    // RFC 6455 Section 1.3 example: key "dGhlIHNhbXBsZSBub25jZQ==" must
    // produce accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" via
    // Base64(SHA-1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const key_val = try alloc.create(Value);
    key_val.* = Value{ .string = "dGhlIHNhbXBsZSBub25jZQ==" };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = key_val;

    const result = try builtinWsAcceptKeyNative(alloc, args);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", result.string);
}

test "ws_accept_key rejects non-string arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const int_val = try alloc.create(Value);
    int_val.* = Value{ .integer = 42 };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = int_val;

    const result = builtinWsAcceptKeyNative(alloc, args);
    try std.testing.expectError(error.TypeError, result);
}

// ============================================================
// View diff tests
// ============================================================

test "view_diff identical trees returns empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create two identical text nodes: text("hello")
    const child1 = try alloc.create(Value);
    child1.* = Value{ .string = "hello" };
    const children1 = try alloc.alloc(*const Value, 1);
    children1[0] = child1;

    const node1 = try alloc.create(Value);
    const node1_view = try alloc.create(Value.ViewNode);
    node1_view.* = .{ .tag = "text", .attrs = &.{}, .children = children1 };
    node1.* = Value{ .view_node = node1_view };

    const child2 = try alloc.create(Value);
    child2.* = Value{ .string = "hello" };
    const children2 = try alloc.alloc(*const Value, 1);
    children2[0] = child2;

    const node2 = try alloc.create(Value);
    const node2_view = try alloc.create(Value.ViewNode);
    node2_view.* = .{ .tag = "text", .attrs = &.{}, .children = children2 };
    node2.* = Value{ .view_node = node2_view };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = node1;
    args[1] = node2;

    const result = try builtinViewDiffNative(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expectEqual(@as(usize, 0), result.list.len);
}

test "view_diff detects text change in child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Old: text("Count: 4")
    const old_child = try alloc.create(Value);
    old_child.* = Value{ .string = "Count: 4" };
    const old_children = try alloc.alloc(*const Value, 1);
    old_children[0] = old_child;
    const old_node = try alloc.create(Value);
    const old_node_view = try alloc.create(Value.ViewNode);
    old_node_view.* = .{ .tag = "text", .attrs = &.{}, .children = old_children };
    old_node.* = Value{ .view_node = old_node_view };

    // New: text("Count: 5")
    const new_child = try alloc.create(Value);
    new_child.* = Value{ .string = "Count: 5" };
    const new_children = try alloc.alloc(*const Value, 1);
    new_children[0] = new_child;
    const new_node = try alloc.create(Value);
    const new_node_view = try alloc.create(Value.ViewNode);
    new_node_view.* = .{ .tag = "text", .attrs = &.{}, .children = new_children };
    new_node.* = Value{ .view_node = new_node_view };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = old_node;
    args[1] = new_node;

    const result = try builtinViewDiffNative(alloc, args);
    try std.testing.expect(result.* == .list);
    // Should have exactly 1 patch for the text change
    try std.testing.expectEqual(@as(usize, 1), result.list.len);

    // Check the patch is a text op
    const patch = result.list[0];
    try std.testing.expect(patch.* == .map);
    // Find the "op" entry
    var found_op = false;
    for (patch.map) |entry| {
        if (std.mem.eql(u8, entry.key, "op")) {
            try std.testing.expectEqualStrings("text", entry.val.string);
            found_op = true;
        }
    }
    try std.testing.expect(found_op);
}

test "view_diff detects tag change as replace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Old: a "text" node
    const old_node = try alloc.create(Value);
    const old_node_view = try alloc.create(Value.ViewNode);
    old_node_view.* = .{ .tag = "text", .attrs = &.{}, .children = &.{} };
    old_node.* = Value{ .view_node = old_node_view };

    // New: a "heading" node
    const new_node = try alloc.create(Value);
    const new_node_view = try alloc.create(Value.ViewNode);
    new_node_view.* = .{ .tag = "heading", .attrs = &.{}, .children = &.{} };
    new_node.* = Value{ .view_node = new_node_view };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = old_node;
    args[1] = new_node;

    const result = try builtinViewDiffNative(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expectEqual(@as(usize, 1), result.list.len);

    // Should be a "replace" op
    const patch = result.list[0];
    for (patch.map) |entry| {
        if (std.mem.eql(u8, entry.key, "op")) {
            try std.testing.expectEqualStrings("replace", entry.val.string);
        }
    }
}

test "builtin abs wraps minInt to itself instead of panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = try alloc.create(Value);
    n.* = Value{ .integer = std.math.minInt(i64) };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = n;
    const result = try builtinAbs(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = std.math.minInt(i64) }));
}

test "builtin abs is unchanged for ordinary values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = try alloc.create(Value);
    n.* = Value{ .integer = -7 };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = n;
    const result = try builtinAbs(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 7 }));
}

test "builtin sum wraps past maxInt instead of panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try alloc.create(Value);
    a.* = Value{ .integer = std.math.maxInt(i64) };
    const b = try alloc.create(Value);
    b.* = Value{ .integer = 1 };
    const items = try alloc.alloc(*const Value, 2);
    items[0] = a;
    items[1] = b;
    const list_val = try alloc.create(Value);
    list_val.* = Value{ .list = items };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = list_val;

    const result = try builtinSum(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = std.math.minInt(i64) }));
}

test "pow answers a fractional exponent, which repeated multiplication cannot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const base = try alloc.create(Value);
    base.* = Value{ .float = 4.0 };
    const exponent = try alloc.create(Value);
    exponent.* = Value{ .float = -0.5 };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = base;
    args[1] = exponent;

    const result = try builtinPow(alloc, args);
    try std.testing.expectEqual(@as(f64, 0.5), result.float);
}

test "a float function takes an Int and answers a Float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = try alloc.create(Value);
    n.* = Value{ .integer = 16 };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = n;

    const sqrt = unaryFloat(struct {
        fn f(x: f64) f64 {
            return @sqrt(x);
        }
    }.f);
    const result = try sqrt(alloc, args);
    try std.testing.expectEqual(@as(f64, 4.0), result.float);

    // A string has no square root, and says so rather than answering one.
    const text = try alloc.create(Value);
    text.* = Value{ .string = "16" };
    args[0] = text;
    try std.testing.expectError(error.TypeError, sqrt(alloc, args));
}

test "the transcendental functions agree with their identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const x = try alloc.create(Value);
    x.* = Value{ .float = 1.0 };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = x;

    inline for (float_fns) |entry| {
        const result = try unaryFloat(entry[1])(alloc, args);
        // Every one of these is defined at 1.0. That is all this asserts:
        // sin wired to cos would pass it. The identity below is the check
        // with teeth.
        try std.testing.expect(result.* == .float);
        try std.testing.expect(!std.math.isNan(result.float));
    }

    // log(e) is 1, and e is exp(1): the two entries are each other's inverse.
    const e = try unaryFloat(struct {
        fn f(v: f64) f64 {
            return @exp(v);
        }
    }.f)(alloc, args);
    args[0] = e;
    const back = try unaryFloat(struct {
        fn f(v: f64) f64 {
            return @log(v);
        }
    }.f)(alloc, args);
    try std.testing.expectEqual(@as(f64, 1.0), back.float);
}

test "write_file writes a string and read_file reads it back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = try alloc.create(Value);
    path.* = Value{ .string = "zig-cache-write-file-test.txt" };
    const text = try alloc.create(Value);
    text.* = Value{ .string = "<testsuites/>" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = path;
    args[1] = text;

    // A builtin that touches a file needs an `Io`, and a unit test does not go
    // through `main`, so nothing has installed one. `ioenv.io` defaults to
    // `failing` rather than `undefined` -- this is the test that would
    // otherwise have segfaulted inside libc -- so the test installs a real one.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;

    const wrote = try builtinWriteFile(alloc, args);
    try std.testing.expect(wrote.boolean);
    defer std.Io.Dir.cwd().deleteFile(ioenv.io, path.string) catch {};

    const back = try builtinReadFile(alloc, args[0..1]);
    try std.testing.expectEqualStrings(text.string, back.string);

    // A directory that is not there is a false, not a crash: the caller
    // decides whether that matters.
    const bad = try alloc.create(Value);
    bad.* = Value{ .string = "no-such-directory/out.txt" };
    args[0] = bad;
    const failed = try builtinWriteFile(alloc, args);
    try std.testing.expect(!failed.boolean);
}

test "sleep_ms waits at least as long as it was asked to" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try builtinNowMs(a, &.{});
    const ms = try make(a, .{ .integer = 60 });
    const answer = try builtinSleepMsNative(a, &.{ms});
    const after = try builtinNowMs(a, &.{});

    try std.testing.expectEqualStrings("ok", answer.atom);
    // Only a lower bound is asserted. A scheduler may take longer, and on a
    // loaded machine it will; what must never happen is returning early.
    try std.testing.expect(after.integer - before.integer >= 60);
}

test "sleep_ms rejects what it cannot wait for" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const notANumber = try make(a, .{ .string = "soon" });
    try std.testing.expectError(error.TypeError, builtinSleepMsNative(a, &.{notANumber}));
    try std.testing.expectError(error.TypeError, builtinSleepMsNative(a, &.{}));
}

test "now_ms goes forwards and has more than second resolution" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try builtinNowMs(a, &.{});
    _ = try builtinSleepMsNative(a, &.{try make(a, .{ .integer = 5 })});
    const second = try builtinNowMs(a, &.{});
    // 5ms is unmeasurable with `now()`, which is the reason this exists.
    try std.testing.expect(second.integer > first.integer);
}

test "poll reports a hung-up fd as ready" {
    if (is_wasm) return;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A pipe whose write end is closed. A read on it will not block -- it
    // answers end of stream -- so a poll that called it "not ready" would
    // leave a caller with nothing to wait for and nothing to do.
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SkipZigTest;
    _ = std.c.close(fds[1]);
    defer _ = std.c.close(fds[0]);

    const fd = try make(a, .{ .integer = @intCast(fds[0]) });
    const list = try a.alloc(*const Value, 1);
    list[0] = fd;
    const fd_list = try make(a, .{ .list = list });
    // A timeout long enough that returning it would be obvious.
    const timeout = try make(a, .{ .integer = 5000 });

    const before = try builtinNowMs(a, &.{});
    const ready = try builtinTcpPollNative(a, &.{ fd_list, timeout });
    const after = try builtinNowMs(a, &.{});

    try std.testing.expectEqual(@as(usize, 1), ready.list.len);
    try std.testing.expect(after.integer - before.integer < 1000);
}

test "poll waits when nothing is ready" {
    if (is_wasm) return;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Both ends open and nothing written: the one case that must block.
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SkipZigTest;
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    const fd = try make(a, .{ .integer = @intCast(fds[0]) });
    const list = try a.alloc(*const Value, 1);
    list[0] = fd;
    const fd_list = try make(a, .{ .list = list });
    const timeout = try make(a, .{ .integer = 60 });

    const before = try builtinNowMs(a, &.{});
    const ready = try builtinTcpPollNative(a, &.{ fd_list, timeout });
    const after = try builtinNowMs(a, &.{});

    try std.testing.expectEqual(@as(usize, 0), ready.list.len);
    try std.testing.expect(after.integer - before.integer >= 60);
}

// ── P-256 and AES-128-GCM ─────────────────────────────────────────────
//
// What Web Push needs (RFC 8291 message encryption, RFC 8292 VAPID), as
// functions over byte Strings: a private key is the 32-byte big-endian
// scalar, a public key the 65-byte uncompressed SEC1 point (0x04 || x || y),
// which is what a browser's PushSubscription hands over as `p256dh` and what
// VAPID's `k=` carries. HKDF is not here: Web Push's HKDF is two HMACs and
// hmac_sha256 already exists.
//
// A wrong-length argument is an error that names the argument. None of
// these truncate, pad or reinterpret: a 31-byte "private key" is a bug in the
// caller, and quietly left-padding it would sign with a key nobody chose.

const P256 = std.crypto.ecc.P256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

/// The String argument `name` of builtin `func`, which must be `len` bytes.
fn bytesArg(comptime func: []const u8, comptime name: []const u8, v: *const Value, comptime len: usize) EvalError!*const [len]u8 {
    if (v.* != .string) return failArg(func ++ ": " ++ name ++ " must be a String of {d} bytes, got {s}", .{ len, @tagName(v.*) });
    if (v.string.len != len) return failArg(func ++ ": " ++ name ++ " must be {d} bytes, got {d}", .{ len, v.string.len });
    return v.string[0..len];
}

/// A String argument of any length, named when it is not a String.
fn anyBytesArg(comptime func: []const u8, comptime name: []const u8, v: *const Value) EvalError![]const u8 {
    if (v.* != .string) return failArg(func ++ ": " ++ name ++ " must be a String, got {s}", .{@tagName(v.*)});
    return v.string;
}

/// A private key: 32 bytes, big-endian, in [1, n). Zero and anything at or
/// past the group order are refused rather than reduced, because the key
/// that would be used is not the one the caller holds.
fn privateKeyArg(comptime func: []const u8, v: *const Value) EvalError![32]u8 {
    const bytes = (try bytesArg(func, "private", v, 32)).*;
    const s = P256.scalar.Scalar.fromBytes(bytes, .big) catch
        return failArg(func ++ ": private is not below the P-256 group order", .{});
    if (s.isZero()) return failArg(func ++ ": private is zero", .{});
    return bytes;
}

/// A public key: 65-byte uncompressed SEC1 that is a point on the curve.
fn publicKeyArg(comptime func: []const u8, comptime name: []const u8, v: *const Value) EvalError!P256 {
    const bytes = try bytesArg(func, name, v, 65);
    if (bytes[0] != 0x04) return failArg(func ++ ": " ++ name ++ " must start with 0x04 (uncompressed), got 0x{x:0>2}", .{bytes[0]});
    const p = P256.fromSec1(bytes) catch
        return failArg(func ++ ": " ++ name ++ " is not a point on P-256", .{});
    p.rejectIdentity() catch return failArg(func ++ ": " ++ name ++ " is the point at infinity", .{});
    return p;
}

fn bytesValue(allocator: std.mem.Allocator, bytes: []const u8) EvalError!*const Value {
    const out = allocator.dupe(u8, bytes) catch return error.OutOfMemory;
    return make(allocator, .{ .string = out });
}

fn publicFromPrivate(private: [32]u8) EvalError![65]u8 {
    const kp = EcdsaP256.KeyPair.fromSecretKey(.{ .bytes = private }) catch return error.TypeError;
    return kp.public_key.toUncompressedSec1();
}

/// p256_keypair() -> {private, public}: a 32-byte scalar from the OS CSPRNG
/// and its 65-byte uncompressed point. Web Push wants a fresh one per
/// message. Rejection sampling, not reduction mod n, so every key is equally
/// likely. Native only, like random_bytes: WASM has no entropy to offer, and
/// a key from a predictable source is worse than none.
fn builtinP256KeypairNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return failArg("p256_keypair takes no arguments, got {d}", .{args.len});
    var private: [32]u8 = undefined;
    while (true) {
        ioenv.io.randomSecure(&private) catch return error.NotSupported;
        const s = P256.scalar.Scalar.fromBytes(private, .big) catch continue;
        if (!s.isZero()) break;
    }
    const public = try publicFromPrivate(private);
    const items = allocator.alloc(*const Value, 2) catch return error.OutOfMemory;
    items[0] = try bytesValue(allocator, &private);
    items[1] = try bytesValue(allocator, &public);
    return make(allocator, .{ .tuple = items });
}

const builtinP256Keypair_impl = if (is_wasm) native_stub.stub else builtinP256KeypairNative;

/// p256_public_key(private) -> the 65-byte uncompressed public key. What
/// VAPID's `k=` is, derived from the one secret that has to be configured.
fn builtinP256PublicKey(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return failArg("p256_public_key takes 1 argument (private), got {d}", .{args.len});
    const public = try publicFromPrivate(try privateKeyArg("p256_public_key", args[0]));
    return bytesValue(allocator, &public);
}

/// p256_ecdh(private, peer_public) -> the 32-byte shared secret: the x
/// coordinate of private * peer_public (SEC1 / RFC 8291's ecdh_secret). The
/// peer's key is checked to be on the curve first -- a point off it is how
/// an invalid-curve attack reads a private key out one bit at a time.
fn builtinP256Ecdh(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return failArg("p256_ecdh takes 2 arguments (private, peer_public), got {d}", .{args.len});
    const private = try privateKeyArg("p256_ecdh", args[0]);
    const peer = try publicKeyArg("p256_ecdh", "peer_public", args[1]);
    const shared = peer.mul(private, .big) catch
        return failArg("p256_ecdh: the shared point is the point at infinity", .{});
    return bytesValue(allocator, &shared.affineCoordinates().x.toBytes(.big));
}

/// ecdsa_p256_sign(private, message) -> 64 bytes, r || s, each 32 bytes
/// big-endian: ES256 as JWS wants it (RFC 7518 3.4), not DER. The message
/// is hashed with SHA-256 here; pass the JWT signing input as-is.
///
/// Deterministic: the nonce is derived from the key and the message (Zig's
/// std, the hedged-signature construction with its noise left empty), so the
/// same key signs the same message the same way. That is not RFC 6979's
/// derivation, so another library's deterministic signature of the same
/// message will differ -- and both verify. It never needs the entropy WASM
/// does not have, and a nonce reused across two messages is impossible.
fn builtinEcdsaP256Sign(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return failArg("ecdsa_p256_sign takes 2 arguments (private, message), got {d}", .{args.len});
    const private = try privateKeyArg("ecdsa_p256_sign", args[0]);
    const message = try anyBytesArg("ecdsa_p256_sign", "message", args[1]);
    const kp = EcdsaP256.KeyPair.fromSecretKey(.{ .bytes = private }) catch return error.TypeError;
    const sig = kp.sign(message, null) catch return failArg("ecdsa_p256_sign: signing failed", .{});
    return bytesValue(allocator, &sig.toBytes());
}

/// ecdsa_p256_verify(public, message, signature) -> true or false. The
/// signature is r || s, 64 bytes. An r or s of zero or at/past the group
/// order is false, as is any mismatch; a key that is not a curve point or a
/// signature that is not 64 bytes is an error, because that is a caller
/// passing the wrong thing, not a forgery.
fn builtinEcdsaP256Verify(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return failArg("ecdsa_p256_verify takes 3 arguments (public, message, signature), got {d}", .{args.len});
    const point = try publicKeyArg("ecdsa_p256_verify", "public", args[0]);
    const message = try anyBytesArg("ecdsa_p256_verify", "message", args[1]);
    const sig_bytes = try bytesArg("ecdsa_p256_verify", "signature", args[2], 64);
    const sig = EcdsaP256.Signature.fromBytes(sig_bytes.*);
    const ok = if (sig.verify(message, .{ .p = point })) true else |_| false;
    return make(allocator, .{ .boolean = ok });
}

/// aes128gcm_encrypt(key, nonce, plaintext, aad) -> ciphertext || tag: the
/// ciphertext is as long as the plaintext and the 16-byte tag follows, the
/// layout RFC 8188's aes128gcm records use. key is 16 bytes, nonce 12.
fn builtinAes128GcmEncrypt(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 4) return failArg("aes128gcm_encrypt takes 4 arguments (key, nonce, plaintext, aad), got {d}", .{args.len});
    const key = try bytesArg("aes128gcm_encrypt", "key", args[0], Aes128Gcm.key_length);
    const nonce = try bytesArg("aes128gcm_encrypt", "nonce", args[1], Aes128Gcm.nonce_length);
    const plaintext = try anyBytesArg("aes128gcm_encrypt", "plaintext", args[2]);
    const aad = try anyBytesArg("aes128gcm_encrypt", "aad", args[3]);
    const out = allocator.alloc(u8, plaintext.len + Aes128Gcm.tag_length) catch return error.OutOfMemory;
    Aes128Gcm.encrypt(out[0..plaintext.len], out[plaintext.len..][0..Aes128Gcm.tag_length], plaintext, aad, nonce.*, key.*);
    return make(allocator, .{ .string = out });
}

/// aes128gcm_decrypt(key, nonce, ciphertext_and_tag, aad) -> the plaintext,
/// or nil when the tag does not authenticate it: a wrong key, another
/// nonce, other AAD, or any changed byte. nil and not an error, because a
/// message that fails to authenticate is data arriving, not a program bug.
/// Input shorter than the 16-byte tag cannot be a message and is an error.
fn builtinAes128GcmDecrypt(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 4) return failArg("aes128gcm_decrypt takes 4 arguments (key, nonce, ciphertext, aad), got {d}", .{args.len});
    const key = try bytesArg("aes128gcm_decrypt", "key", args[0], Aes128Gcm.key_length);
    const nonce = try bytesArg("aes128gcm_decrypt", "nonce", args[1], Aes128Gcm.nonce_length);
    const sealed = try anyBytesArg("aes128gcm_decrypt", "ciphertext", args[2]);
    const aad = try anyBytesArg("aes128gcm_decrypt", "aad", args[3]);
    if (sealed.len < Aes128Gcm.tag_length)
        return failArg("aes128gcm_decrypt: ciphertext must be at least the 16-byte tag, got {d} bytes", .{sealed.len});
    const n = sealed.len - Aes128Gcm.tag_length;
    const out = allocator.alloc(u8, n) catch return error.OutOfMemory;
    Aes128Gcm.decrypt(out, sealed[0..n], sealed[n..][0..Aes128Gcm.tag_length].*, aad, nonce.*, key.*) catch
        return make(allocator, .nil);
    return make(allocator, .{ .string = out });
}

test "p256 and aes128gcm name the argument that is the wrong length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const short = try make(a, .{ .string = "short" });
    const key32 = try make(a, .{ .string = "\x01" ** 32 });
    try std.testing.expectError(error.TypeError, builtinP256Ecdh(a, &.{ key32, short }));
    try std.testing.expectEqualStrings("p256_ecdh: peer_public must be 65 bytes, got 5", takeFailure().?);
    try std.testing.expectError(error.TypeError, builtinEcdsaP256Sign(a, &.{ short, short }));
    try std.testing.expectEqualStrings("ecdsa_p256_sign: private must be 32 bytes, got 5", takeFailure().?);
    const order = try make(a, .{ .string = &[_]u8{
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    } });
    try std.testing.expectError(error.TypeError, builtinP256PublicKey(a, &.{order}));
    try std.testing.expectEqualStrings("p256_public_key: private is not below the P-256 group order", takeFailure().?);
    try std.testing.expectEqual(@as(?[]const u8, null), takeFailure());
}

test "a signature from ecdsa_p256_sign verifies, and one flipped bit does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const private = try make(a, .{ .string = "\x07" ** 32 });
    const msg = try make(a, .{ .string = "header.claims" });
    const public = try builtinP256PublicKey(a, &.{private});
    const sig = try builtinEcdsaP256Sign(a, &.{ private, msg });
    try std.testing.expectEqual(@as(usize, 64), sig.string.len);
    try std.testing.expect((try builtinEcdsaP256Verify(a, &.{ public, msg, sig })).boolean);

    var bad = try a.dupe(u8, sig.string);
    bad[63] ^= 1;
    const bad_sig = try make(a, .{ .string = bad });
    try std.testing.expect(!(try builtinEcdsaP256Verify(a, &.{ public, msg, bad_sig })).boolean);
}

test "process_stats answers what the process has used, all of it counted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try builtinProcessStats(a, &.{});
    const m = v.map;
    try std.testing.expectEqual(@as(usize, 4), m.len);
    try std.testing.expectEqualStrings("cpu_ms", m[0].key);
    try std.testing.expectEqualStrings("rss_bytes", m[1].key);
    try std.testing.expectEqualStrings("heap_bytes", m[2].key);
    try std.testing.expectEqualStrings("cores", m[3].key);
    try std.testing.expect(m[0].val.integer >= 0);
    // A running process on the two systems it reads is resident somewhere.
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) try std.testing.expect(m[1].val.integer > 0);
    try std.testing.expect(m[3].val.integer >= 1);
    try std.testing.expectError(error.TypeError, builtinProcessStats(a, &.{v}));
}

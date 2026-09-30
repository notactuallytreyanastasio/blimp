//! Zig 0.16.0's lib/std/compress/flate/Decompress.zig, vendored into Blimp.
//!
//! http_start's worker decompresses gzip and deflate bodies with it, and
//! upstream's panics on a body that is cut off: a gzip response whose
//! connection closed early killed the whole process (a safe build asserts in
//! `Reader.toss`). What differs from upstream, each marked "Blimp:" below:
//!
//!  1. `tossBitsShort` checked `buffered * 8 + consumed_bits < n` where it
//!     means `buffered * 8 - consumed_bits < n`: with a partly consumed last
//!     byte it tossed a byte that was not there. Now EndOfStream, which is
//!     `error.ReadFailed` with `err` set, like every other truncation.
//!  2. `@import("std")` and `flate_token.zig` instead of paths in the std tree.
//!  3. Upstream's tests that read its testdata/fuzz corpus are gone: the
//!     installed Zig lib does not ship the corpus. The truncation and
//!     corruption tests at the end are Blimp's.
//!
const std = @import("std"); // Blimp
const assert = std.debug.assert;
const flate = std.compress.flate;
const testing = std.testing;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const Container = flate.Container;

const Decompress = @This();
const token = @import("flate_token.zig"); // Blimp

input: *Reader,
consumed_bits: u3,

reader: Reader,

container_metadata: Container.Metadata,

lit_dec: LiteralDecoder,
dst_dec: DistanceDecoder,

final_block: bool,
state: State,

err: ?Error,

const BlockType = enum(u2) {
    stored = 0,
    fixed = 1,
    dynamic = 2,
    invalid = 3,
};

const State = union(enum) {
    protocol_header,
    block_header,
    stored_block: u16,
    fixed_block,
    fixed_block_literal: u8,
    fixed_block_match: u16,
    dynamic_block,
    dynamic_block_literal: u8,
    dynamic_block_match: u16,
    protocol_footer,
    end,
};

pub const Error = Container.Error || error{
    InvalidCode,
    InvalidMatch,
    WrongStoredBlockNlen,
    InvalidBlockType,
    InvalidDynamicBlockHeader,
    ReadFailed,
    OversubscribedHuffmanTree,
    IncompleteHuffmanTree,
    MissingEndOfBlockCode,
    EndOfStream,
};

const direct_vtable: Reader.VTable = .{
    .stream = streamDirect,
    .rebase = rebaseFallible,
    .discard = discardDirect,
    .readVec = readVec,
};

const indirect_vtable: Reader.VTable = .{
    .stream = streamIndirect,
    .rebase = rebaseFallible,
    .discard = discardIndirect,
    .readVec = readVec,
};

/// `input` buffer is asserted to be at least 10 bytes, or EOF before then.
///
/// If `buffer` is provided then asserted to have `flate.max_window_len`
/// capacity.
pub fn init(input: *Reader, container: Container, buffer: []u8) Decompress {
    if (buffer.len != 0) assert(buffer.len >= flate.max_window_len);
    return .{
        .reader = .{
            .vtable = if (buffer.len == 0) &direct_vtable else &indirect_vtable,
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .input = input,
        .consumed_bits = 0,
        .container_metadata = .init(container),
        .lit_dec = .{},
        .dst_dec = .{},
        .final_block = false,
        .state = .protocol_header,
        .err = null,
    };
}

fn rebaseFallible(r: *Reader, capacity: usize) Reader.RebaseError!void {
    rebase(r, capacity);
}

fn rebase(r: *Reader, capacity: usize) void {
    assert(capacity <= r.buffer.len - flate.history_len);
    assert(r.end + capacity > r.buffer.len);
    const discard_n = @min(r.seek, r.end - flate.history_len);
    const keep = r.buffer[discard_n..r.end];
    @memmove(r.buffer[0..keep.len], keep);
    r.end = keep.len;
    r.seek -= discard_n;
}

/// This could be improved so that when an amount is discarded that includes an
/// entire frame, skip decoding that frame.
fn discardDirect(r: *Reader, limit: std.Io.Limit) Reader.Error!usize {
    if (r.end + flate.history_len > r.buffer.len) rebase(r, flate.history_len);
    var writer: Writer = .{
        .vtable = &.{
            .drain = std.Io.Writer.Discarding.drain,
            .sendFile = std.Io.Writer.Discarding.sendFile,
        },
        .buffer = r.buffer,
        .end = r.end,
    };
    defer {
        assert(writer.end != 0);
        r.end = writer.end;
        r.seek = r.end;
    }
    const n = r.stream(&writer, limit) catch |err| switch (err) {
        error.WriteFailed => unreachable,
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.EndOfStream,
    };
    assert(n <= @intFromEnum(limit));
    return n;
}

fn discardIndirect(r: *Reader, limit: std.Io.Limit) Reader.Error!usize {
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));
    if (r.end + flate.history_len > r.buffer.len) rebase(r, flate.history_len);
    var writer: Writer = .{
        .buffer = r.buffer,
        .end = r.end,
        .vtable = &.{ .drain = Writer.unreachableDrain },
    };
    {
        defer r.end = writer.end;
        _ = streamFallible(d, &writer, .limited(writer.buffer.len - writer.end)) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            else => |e| return e,
        };
    }
    const n = limit.minInt(r.end - r.seek);
    r.seek += n;
    return n;
}

fn readVec(r: *Reader, data: [][]u8) Reader.Error!usize {
    _ = data;
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));
    return streamIndirectInner(d);
}

fn streamIndirectInner(d: *Decompress) Reader.Error!usize {
    const r = &d.reader;
    if (r.buffer.len - r.end < flate.history_len) rebase(r, flate.history_len);
    var writer: Writer = .{
        .buffer = r.buffer,
        .end = r.end,
        .vtable = &.{
            .drain = Writer.unreachableDrain,
            .rebase = Writer.unreachableRebase,
        },
    };
    defer r.end = writer.end;
    _ = streamFallible(d, &writer, .limited(writer.buffer.len - writer.end)) catch |err| switch (err) {
        error.WriteFailed => unreachable,
        else => |e| return e,
    };
    return 0;
}

fn decodeLength(self: *Decompress, code_int: u5) !u16 {
    if (code_int > 28) return error.InvalidCode;
    const l: token.LenCode = .fromInt(code_int);
    const base = l.base();
    const extra = l.extraBits();
    return token.min_length + (base | try self.takeBits(extra));
}

fn decodeDistance(self: *Decompress, code_int: u5) !u16 {
    if (code_int > 29) return error.InvalidCode;
    const d: token.DistCode = .fromInt(code_int);
    const base = d.base();
    const extra = d.extraBits();
    return token.min_distance + (base | try self.takeBits(extra));
}

/// Decode code length symbol to code length. Writes decoded length into
/// lens slice starting at position pos. Returns number of positions
/// advanced.
fn dynamicCodeLength(self: *Decompress, code: u16, lens: []u4, pos: usize) !usize {
    if (pos >= lens.len)
        return error.InvalidDynamicBlockHeader;

    switch (code) {
        0...15 => {
            // Represent code lengths of 0 - 15
            lens[pos] = @intCast(code);
            return 1;
        },
        16 => {
            // Copy the previous code length 3 - 6 times.
            // The next 2 bits indicate repeat length
            const n: u8 = @as(u8, try self.takeIntBits(u2)) + 3;
            if (pos == 0 or pos + n > lens.len)
                return error.InvalidDynamicBlockHeader;
            for (0..n) |i| {
                lens[pos + i] = lens[pos + i - 1];
            }
            return n;
        },
        // Repeat a code length of 0 for 3 - 10 times. (3 bits of length)
        17 => return @as(u8, try self.takeIntBits(u3)) + 3,
        // Repeat a code length of 0 for 11 - 138 times (7 bits of length)
        18 => return @as(u8, try self.takeIntBits(u7)) + 11,
        else => return error.InvalidDynamicBlockHeader,
    }
}

fn decodeSymbol(self: *Decompress, decoder: anytype) !u16 {
    // Maximum code len is 15 bits.
    const sym = try decoder.find(try self.peekIntBitsShort(u15));
    try self.tossBitsShort(sym.code_bits);
    return sym.value;
}

fn streamDirect(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));
    return streamFallible(d, w, limit);
}

fn streamIndirect(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));
    _ = limit;
    _ = w;
    return streamIndirectInner(d);
}

fn streamFallible(d: *Decompress, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    return streamInner(d, w, limit) catch |err| switch (err) {
        error.EndOfStream => {
            if (d.state == .end) {
                return error.EndOfStream;
            } else {
                d.err = error.EndOfStream;
                return error.ReadFailed;
            }
        },
        error.WriteFailed => return error.WriteFailed,
        else => |e| {
            // In the event of an error, state is unmodified so that it can be
            // better used to diagnose the failure.
            d.err = e;
            return error.ReadFailed;
        },
    };
}

fn streamInner(d: *Decompress, w: *Writer, limit: std.Io.Limit) (Error || Reader.StreamError)!usize {
    var remaining = @intFromEnum(limit);
    const in = d.input;
    sw: switch (d.state) {
        .protocol_header => switch (d.container_metadata.container()) {
            .gzip => {
                const Header = extern struct {
                    magic: u16 align(1),
                    method: u8,
                    flags: packed struct(u8) {
                        text: bool,
                        hcrc: bool,
                        extra: bool,
                        name: bool,
                        comment: bool,
                        reserved: u3,
                    },
                    mtime: u32 align(1),
                    xfl: u8,
                    os: u8,
                };
                const header = try in.takeStruct(Header, .little);
                if (header.magic != 0x8b1f or header.method != 0x08)
                    return error.BadGzipHeader;
                if (header.flags.extra) {
                    const extra_len = try in.takeInt(u16, .little);
                    try in.discardAll(extra_len);
                }
                if (header.flags.name) {
                    _ = try in.discardDelimiterInclusive(0);
                }
                if (header.flags.comment) {
                    _ = try in.discardDelimiterInclusive(0);
                }
                if (header.flags.hcrc) {
                    try in.discardAll(2);
                }
                continue :sw .block_header;
            },
            .zlib => {
                const header = try in.takeArray(2);
                const cmf: packed struct(u8) { cm: u4, cinfo: u4 } = @bitCast(header[0]);
                if (cmf.cm != 8 or cmf.cinfo > 7) return error.BadZlibHeader;
                continue :sw .block_header;
            },
            .raw => continue :sw .block_header,
        },
        .block_header => {
            d.final_block = (try d.takeIntBits(u1)) != 0;
            const block_type: BlockType = @enumFromInt(try d.takeIntBits(u2));
            switch (block_type) {
                .stored => {
                    d.alignBitsForward();
                    // everything after this is byte aligned in stored block
                    const len = try in.takeInt(u16, .little);
                    const nlen = try in.takeInt(u16, .little);
                    if (len != ~nlen) return error.WrongStoredBlockNlen;
                    continue :sw .{ .stored_block = len };
                },
                .fixed => continue :sw .fixed_block,
                .dynamic => {
                    const hlit: u16 = @as(u16, try d.takeIntBits(u5)) + 257; // number of ll code entries present - 257
                    const hdist: u16 = @as(u16, try d.takeIntBits(u5)) + 1; // number of distance code entries - 1
                    const hclen: u8 = @as(u8, try d.takeIntBits(u4)) + 4; // hclen + 4 code lengths are encoded

                    if (hlit > 286 or hdist > 30)
                        return error.InvalidDynamicBlockHeader;

                    // lengths for code lengths
                    var cl_lens: [19]u4 = @splat(0);
                    for (token.codegen_order[0..hclen]) |i| {
                        cl_lens[i] = try d.takeIntBits(u3);
                    }
                    var cl_dec: CodegenDecoder = .{};
                    try cl_dec.generate(&cl_lens);

                    // decoded code lengths
                    var dec_lens: [286 + 30]u4 = @splat(0);
                    var pos: usize = 0;
                    while (pos < hlit + hdist) {
                        const peeked = try d.peekIntBitsShort(u7);
                        const sym = try cl_dec.find(peeked);
                        try d.tossBitsShort(sym.code_bits);
                        pos += try d.dynamicCodeLength(sym.value, &dec_lens, pos);
                    }
                    if (pos > hlit + hdist) {
                        return error.InvalidDynamicBlockHeader;
                    }

                    // literal code lengths to literal decoder
                    try d.lit_dec.generate(dec_lens[0..hlit]);

                    // distance code lengths to distance decoder
                    try d.dst_dec.generate(dec_lens[hlit..][0..hdist]);

                    continue :sw .dynamic_block;
                },
                .invalid => return error.InvalidBlockType,
            }
        },
        .stored_block => |remaining_len| {
            const out: []u8 = if (remaining != 0)
                try w.writableSliceGreedyPreserve(flate.history_len, 1)
            else
                &.{};
            var limited_out: [1][]u8 = .{limit.min(.limited(remaining_len)).slice(out)};
            const n = try in.readVec(&limited_out);
            if (remaining_len - n == 0) {
                d.state = if (d.final_block) .protocol_footer else .block_header;
            } else {
                d.state = .{ .stored_block = @intCast(remaining_len - n) };
            }
            w.advance(n);
            return @intFromEnum(limit) - remaining + n;
        },
        .fixed_block => while (true) {
            // Consume bytes
            const sym = try d.readFixedCode();

            if (sym >= 256) {
                @branchHint(.unlikely);

                if (sym == 256) {
                    @branchHint(.unlikely);
                    // End
                    d.state = if (d.final_block) .protocol_footer else .block_header;
                    continue :sw d.state;
                }

                // Match
                const length = try d.decodeLength(@intCast(sym - 257));
                continue :sw .{ .fixed_block_match = length };
            }

            const byte: u8 = @intCast(sym);
            if (remaining != 0) {
                @branchHint(.likely);
                remaining -= 1;
                try w.writeBytePreserve(flate.history_len, byte);
            } else {
                d.state = .{ .fixed_block_literal = byte };
                return @intFromEnum(limit) - remaining;
            }
        },
        .fixed_block_literal => |symbol| {
            assert(remaining != 0);
            remaining -= 1;
            try w.writeBytePreserve(flate.history_len, symbol);
            continue :sw .fixed_block;
        },
        .fixed_block_match => |length| {
            if (remaining >= length) {
                @branchHint(.likely);
                const distance = try d.decodeDistance(@bitReverse(try d.takeIntBits(u5)));
                try writeMatch(w, length, distance);
                remaining -= length;
                continue :sw .fixed_block;
            } else {
                d.state = .{ .fixed_block_match = length };
                return @intFromEnum(limit) - remaining;
            }
        },
        // In larger archives most blocks are usually dynamic, so
        // decompression performance depends on this logic.
        .dynamic_block => while (true) {
            // Consume bytes
            const sym = try d.decodeSymbol(&d.lit_dec);

            if (sym >= 256) {
                @branchHint(.unlikely);

                if (sym == 256) {
                    @branchHint(.unlikely);
                    // End
                    d.state = if (d.final_block) .protocol_footer else .block_header;
                    continue :sw d.state;
                }

                // Match
                const length = try d.decodeLength(@intCast(sym - 257));
                continue :sw .{ .dynamic_block_match = length };
            }

            const byte: u8 = @intCast(sym);
            if (remaining != 0) {
                @branchHint(.likely);
                remaining -= 1;
                try w.writeBytePreserve(flate.history_len, byte);
            } else {
                d.state = .{ .dynamic_block_literal = byte };
                return @intFromEnum(limit) - remaining;
            }
        },
        .dynamic_block_literal => |symbol| {
            assert(remaining != 0);
            remaining -= 1;
            try w.writeBytePreserve(flate.history_len, symbol);
            continue :sw .dynamic_block;
        },
        .dynamic_block_match => |length| {
            if (remaining >= length) {
                @branchHint(.likely);
                remaining -= length;
                const dsm = try d.decodeSymbol(&d.dst_dec);
                const distance = try d.decodeDistance(@intCast(dsm));
                try writeMatch(w, length, distance);
                continue :sw .dynamic_block;
            } else {
                d.state = .{ .dynamic_block_match = length };
                return @intFromEnum(limit) - remaining;
            }
        },
        .protocol_footer => {
            d.alignBitsForward();
            switch (d.container_metadata) {
                .gzip => |*gzip| {
                    gzip.crc = try in.takeInt(u32, .little);
                    gzip.count = try in.takeInt(u32, .little);
                },
                .zlib => |*zlib| {
                    zlib.adler = try in.takeInt(u32, .big);
                },
                .raw => {},
            }
            d.state = .end;
            return @intFromEnum(limit) - remaining;
        },
        .end => return error.EndOfStream,
    }
}

/// Write match (back-reference to the same data slice) starting at `distance`
/// back from current write position, and `length` of bytes.
fn writeMatch(w: *Writer, length: u16, distance: u16) !void {
    if (w.end < distance) return error.InvalidMatch;
    assert(length >= token.min_length);
    assert(length <= token.max_length);
    assert(distance >= token.min_distance);
    assert(distance <= token.max_distance);

    // This is not a @memmove; it intentionally repeats patterns caused by
    // iterating one byte at a time.
    const dest = try w.writableSlicePreserve(flate.history_len, length);
    const end = dest.ptr - w.buffer.ptr;
    const src = w.buffer[end - distance ..][0..length];
    if (distance >= length) {
        @memcpy(dest, src);
    } else if (distance == 1) {
        // Repeating copy of single byte
        @memset(dest, src[0]);
    } else {
        // Repeating copy of multiple bytes
        for (dest, src) |*d, s| d.* = s;
    }
}

fn peekBits(d: *Decompress, n: u4) !u16 {
    const bits = d.input.peekInt(u32, .little) catch |e| return switch (e) {
        error.ReadFailed => error.ReadFailed,
        error.EndOfStream => d.peekBitsEnding(n),
    };
    const mask = @shlExact(@as(u16, 1), n) - 1;
    return @intCast((bits >> d.consumed_bits) & mask);
}

fn peekBitsEnding(d: *Decompress, n: u4) !u16 {
    @branchHint(.unlikely);

    const left = d.input.buffered();
    if (left.len * 8 - d.consumed_bits < n) return error.EndOfStream;
    const bits = std.mem.readVarInt(u32, left, .little);
    const mask = @shlExact(@as(u16, 1), n) - 1;
    return @intCast((bits >> d.consumed_bits) & mask);
}

/// Safe only after `peekBits` has been called with a greater or equal `n` value.
fn tossBits(d: *Decompress, n: u4) void {
    d.input.toss((@as(u8, n) + d.consumed_bits) / 8);
    d.consumed_bits +%= @truncate(n);
}

fn takeBits(d: *Decompress, n: u4) !u16 {
    const bits = try d.peekBits(n);
    d.tossBits(n);
    return bits;
}

fn alignBitsForward(d: *Decompress) void {
    d.input.toss(@intFromBool(d.consumed_bits != 0));
    d.consumed_bits = 0;
}

fn peekBitsShort(d: *Decompress, n: u4) !u16 {
    const bits = d.input.peekInt(u32, .little) catch |e| return switch (e) {
        error.ReadFailed => error.ReadFailed,
        error.EndOfStream => d.peekBitsShortEnding(n),
    };
    const mask = @shlExact(@as(u16, 1), n) - 1;
    return @intCast((bits >> d.consumed_bits) & mask);
}

fn peekBitsShortEnding(d: *Decompress, n: u4) !u16 {
    @branchHint(.unlikely);

    const left = d.input.buffered();
    const bits = std.mem.readVarInt(u32, left, .little);
    const mask = @shlExact(@as(u16, 1), n) - 1;
    return @intCast((bits >> d.consumed_bits) & mask);
}

fn tossBitsShort(d: *Decompress, n: u4) !void {
    // Blimp: consumed bits are bits no longer there; upstream added them.
    if (d.input.bufferedLen() * 8 < @as(usize, n) + d.consumed_bits) return error.EndOfStream;
    d.tossBits(n);
}

fn takeIntBits(d: *Decompress, T: type) !T {
    return @intCast(try d.takeBits(@bitSizeOf(T)));
}

fn peekIntBitsShort(d: *Decompress, T: type) !T {
    return @intCast(try d.peekBitsShort(@bitSizeOf(T)));
}

/// Reads first 7 bits, and then maybe 1 or 2 more to get full 7,8 or 9 bit code.
/// ref: https://datatracker.ietf.org/doc/html/rfc1951#page-12
///         Lit Value    Bits        Codes
///          ---------    ----        -----
///            0 - 143     8          00110000 through
///                                   10111111
///          144 - 255     9          110010000 through
///                                   111111111
///          256 - 279     7          0000000 through
///                                   0010111
///          280 - 287     8          11000000 through
///                                   11000111
fn readFixedCode(d: *Decompress) !u16 {
    const code7 = @bitReverse(try d.takeIntBits(u7));
    return switch (code7) {
        0...0b0010_111 => @as(u16, code7) + 256,
        0b0010_111 + 1...0b1011_111 => (@as(u16, code7) << 1) + @as(u16, try d.takeIntBits(u1)) - 0b0011_0000,
        0b1011_111 + 1...0b1100_011 => (@as(u16, code7 - 0b1100000) << 1) + try d.takeIntBits(u1) + 280,
        else => (@as(u16, code7 - 0b1100_100) << 2) + @as(u16, @bitReverse(try d.takeIntBits(u2))) + 144,
    };
}

pub const Symbol = packed struct(u16) {
    value: u12 = 0,
    code_bits: u4 = 0, // number of bits in code 0-15
};

pub const LiteralDecoder = HuffmanDecoder(286, 15, 9);
pub const DistanceDecoder = HuffmanDecoder(30, 15, 9);
pub const CodegenDecoder = HuffmanDecoder(19, 7, 7);

/// Creates huffman tree codes from list of code lengths (in `build`).
///
/// `find` then finds symbol for code bits. Code can be any length between 1 and
/// 15 bits. When calling `find` we don't know how many bits will be used to
/// find symbol. When symbol is returned it has code_bits field which defines
/// how much we should advance in bit stream.
///
/// Lookup table is used to map 15 bit int to symbol. Same symbol is written
/// many times in this table; 32K places for 286 (at most) symbols.
/// Small lookup table is optimization for faster search.
/// It is variation of the algorithm explained in [zlib](https://github.com/madler/zlib/blob/643e17b7498d12ab8d15565662880579692f769d/doc/algorithm.txt#L92)
/// with difference that we here use statically allocated arrays.
fn HuffmanDecoder(
    comptime alphabet_size: u16,
    comptime max_code_bits: u4,
    comptime lookup_bits: u4,
) type {
    const lookup_shift = max_code_bits - lookup_bits;
    const lookup_mask = (1 << lookup_bits) - 1;

    return struct {
        // lookup table code -> symbol
        // for values with code_bits == 0, symbol is the index of the first node in linked
        // if the index of the first node is 0xfff, it is an invalid code
        lookup: [1 << lookup_bits]Symbol = undefined,
        linked: if (lookup_bits == max_code_bits) void else [alphabet_size]struct {
            // sym.value is the next index in linked where the current index ends the chain
            // the actual symbol is this nodes's index
            sym: Symbol,
            code: u16,
        } = undefined,

        const Self = @This();

        fn reverseIdx(idx: usize) u16 {
            return @bitReverse(@as(@Int(.unsigned, lookup_bits), @intCast(idx)));
        }

        /// Generates symbols and lookup tables from list of code lens for each symbol.
        pub fn generate(self: *Self, lens: []const u4) !void {
            try checkCompleteness(lens);

            var buckets: [1 + @as(usize, max_code_bits)][alphabet_size]Symbol = undefined;
            var bucket_len: [buckets.len]u16 = @splat(0);
            for (0.., lens) |symbol, bits| {
                buckets[bits][bucket_len[bits]] = .{
                    .value = @intCast(symbol),
                    .code_bits = bits,
                };
                bucket_len[bits] += 1;
            }

            var code: u16 = 0;
            var idx: u16 = 0;
            for (1..lookup_bits + 1) |bits| {
                const inc = @as(u16, 1) << @intCast(max_code_bits - bits);
                for (buckets[bits][0..bucket_len[bits]]) |lookup_sym| {
                    const next_code = code + inc;
                    const next_idx = next_code >> lookup_shift;
                    for (idx..next_idx) |i| {
                        self.lookup[reverseIdx(i)] = lookup_sym;
                    }
                    code = next_code;
                    idx = next_idx;
                }
            }
            for (lookup_bits + 1..buckets.len) |bits| {
                const inc = @as(u16, 1) << @intCast(max_code_bits - bits);
                for (buckets[bits][0..bucket_len[bits]]) |linked_sym| {
                    const next_code = code + inc;
                    const next_idx = next_code >> lookup_shift;

                    const ri = reverseIdx(idx);
                    const next: Symbol = .{
                        .value = self.lookup[ri].value,
                        .code_bits = linked_sym.code_bits,
                    };
                    self.linked[linked_sym.value] = .{
                        .sym = next,
                        .code = @bitReverse(@as(@Int(.unsigned, max_code_bits), @intCast(code))),
                    };
                    self.lookup[ri] = .{ .value = linked_sym.value, .code_bits = 0 };

                    code = next_code;
                    idx = next_idx;
                }
            }

            // Invalid codes
            for (idx..self.lookup.len) |i| {
                self.lookup[reverseIdx(i)] = .{ .value = 0xfff, .code_bits = 0 };
            }
        }

        /// Given the list of code lengths check that it represents a canonical
        /// Huffman code for n symbols.
        ///
        /// Reference: https://github.com/madler/zlib/blob/5c42a230b7b468dff011f444161c0145b5efae59/contrib/puff/puff.c#L340
        fn checkCompleteness(lens: []const u4) !void {
            if (alphabet_size == 286)
                if (lens[256] == 0) return error.MissingEndOfBlockCode;

            var count = [_]u16{0} ** (@as(usize, max_code_bits) + 1);
            var max: usize = 0;
            for (lens) |n| {
                if (n == 0) continue;
                if (n > max) max = n;
                count[n] += 1;
            }
            if (max == 0) // empty tree
                return;

            // check for an over-subscribed or incomplete set of lengths
            var left: usize = 1; // one possible code of zero length
            for (1..count.len) |len| {
                left <<= 1; // one more bit, double codes left
                if (count[len] > left)
                    return error.OversubscribedHuffmanTree;
                left -= count[len]; // deduct count from possible codes
            }
            if (left > 0) { // left > 0 means incomplete
                // incomplete code ok only for single length 1 code
                if (max_code_bits > 7 and max == count[0] + count[1]) return;
                return error.IncompleteHuffmanTree;
            }
        }

        /// Finds symbol for lookup table code.
        pub fn find(self: *Self, code: u16) !Symbol {
            // try to find in lookup table
            const idx = code & lookup_mask;
            const sym = self.lookup[idx];
            if (sym.code_bits != 0) return sym;
            // if not use linked list of symbols with same prefix
            return self.findLinked(code, sym.value);
        }

        fn findLinked(self: *Self, code: u16, start: u16) !Symbol {
            if (start == 0xfff) return error.InvalidCode;
            if (lookup_bits == max_code_bits) unreachable;
            var pos = start;
            while (true) {
                const node = self.linked[pos];
                const shift = -%node.sym.code_bits;
                // compare code_bits number of upper bits
                if ((code ^ node.code) << shift == 0)
                    return .{ .value = @intCast(pos), .code_bits = node.sym.code_bits };
                pos = node.sym.value;
            }
        }
    };
}

test "init/find" {
    // example data from: https://youtu.be/SJPvNi4HrWQ?t=8423
    const code_lens = [_]u4{ 4, 3, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 3, 2 };
    var h: CodegenDecoder = .{};
    try h.generate(&code_lens);

    // All possible codes for each symbol.
    // Lookup table has 126 elements, to cover all possible 7 bit codes.
    for (0b0000_000..0b0100_000) |c| // 0..32 (32)
        try testing.expectEqual(
            Symbol{ .value = 3, .code_bits = 2 },
            try h.find(@bitReverse(@as(u7, @intCast(c)))),
        );

    for (0b0100_000..0b1000_000) |c| // 32..64 (32)
        try testing.expectEqual(
            Symbol{ .value = 18, .code_bits = 2 },
            try h.find(@bitReverse(@as(u7, @intCast(c)))),
        );

    for (0b1000_000..0b1010_000) |c| // 64..80 (16)
        try testing.expectEqual(
            Symbol{ .value = 1, .code_bits = 3 },
            try h.find(@bitReverse(@as(u7, @intCast(c)))),
        );

    for (0b1010_000..0b1100_000) |c| // 80..96 (16)
        try testing.expectEqual(
            Symbol{ .value = 4, .code_bits = 3 },
            try h.find(@bitReverse(@as(u7, @intCast(c)))),
        );

    for (0b1100_000..0b1110_000) |c| // 96..112 (16)
        try testing.expectEqual(
            Symbol{ .value = 17, .code_bits = 3 },
            try h.find(@bitReverse(@as(u7, @intCast(c)))),
        );

    for (0b1110_000..0b1111_000) |c| // 112..120 (8)
        try testing.expectEqual(
            Symbol{ .value = 0, .code_bits = 4 },
            try h.find(@bitReverse(@as(u7, @intCast(c)))),
        );

    for (0b1111_000..0b1_0000_000) |c| // 120...128 (8)
        try testing.expectEqual(
            Symbol{ .value = 16, .code_bits = 4 },
            try h.find(@bitReverse(@as(u7, @intCast(c)))),
        );
}

test "encode/decode literals" {
    // Check that the example in RFC 1951 section 3.2.2 works (plus some zeroes)
    const max_bits = 5;
    var decoder: HuffmanDecoder(16, max_bits, 3) = .{};
    try decoder.generate(&.{ 3, 3, 3, 3, 0, 0, 3, 2, 4, 4 });

    inline for (0.., .{
        @as(u3, 0b010),
        @as(u3, 0b011),
        @as(u3, 0b100),
        @as(u3, 0b101),
        @as(u0, 0),
        @as(u0, 0),
        @as(u3, 0b110),
        @as(u2, 0b00),
        @as(u4, 0b1110),
        @as(u4, 0b1111),
    }) |i, code| {
        const bits = @bitSizeOf(@TypeOf(code));
        if (bits == 0) continue;
        for (0..1 << (max_bits - bits)) |extra| {
            const full = (@as(u16, code) << (max_bits - bits)) | @as(u16, @intCast(extra));
            const symbol = try decoder.find(@bitReverse(@as(u5, @intCast(full))));
            try testing.expectEqual(i, symbol.value);
            try testing.expectEqual(bits, symbol.code_bits);
        }
    }
}

test "non compressed block (type 0)" {
    try testDecompress(.raw, &[_]u8{
        0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, // deflate fixed buffer header len, nlen
        'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a, // non compressed data
    }, "Hello world\n");
}

test "fixed code block (type 1)" {
    try testDecompress(.raw, &[_]u8{
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, // deflate data block type 1
        0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
    }, "Hello world\n");
}

test "dynamic block (type 2)" {
    try testDecompress(.raw, &[_]u8{
        0x3d, 0xc6, 0x39, 0x11, 0x00, 0x00, 0x0c, 0x02, // deflate data block type 2
        0x30, 0x2b, 0xb5, 0x52, 0x1e, 0xff, 0x96, 0x38,
        0x16, 0x96, 0x5c, 0x1e, 0x94, 0xcb, 0x6d, 0x01,
    }, "ABCDEABCD ABCDEABCD");
}

test "gzip non compressed block (type 0)" {
    try testDecompress(.gzip, &[_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // gzip header (10 bytes)
        0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, // deflate fixed buffer header len, nlen
        'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a, // non compressed data
        0xd5, 0xe0, 0x39, 0xb7, // gzip footer: checksum
        0x0c, 0x00, 0x00, 0x00, // gzip footer: size
    }, "Hello world\n");
}

test "gzip fixed code block (type 1)" {
    try testDecompress(.gzip, &[_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03, // gzip header (10 bytes)
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, // deflate data block type 1
        0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00,
        0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00, // gzip footer (chksum, len)
    }, "Hello world\n");
}

test "gzip dynamic block (type 2)" {
    try testDecompress(.gzip, &[_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // gzip header (10 bytes)
        0x3d, 0xc6, 0x39, 0x11, 0x00, 0x00, 0x0c, 0x02, // deflate data block type 2
        0x30, 0x2b, 0xb5, 0x52, 0x1e, 0xff, 0x96, 0x38,
        0x16, 0x96, 0x5c, 0x1e, 0x94, 0xcb, 0x6d, 0x01,
        0x17, 0x1c, 0x39, 0xb4, 0x13, 0x00, 0x00, 0x00, // gzip footer (chksum, len)
    }, "ABCDEABCD ABCDEABCD");
}

test "gzip header with name" {
    try testDecompress(.gzip, &[_]u8{
        0x1f, 0x8b, 0x08, 0x08, 0xe5, 0x70, 0xb1, 0x65, 0x00, 0x03, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e,
        0x74, 0x78, 0x74, 0x00, 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1,
        0x02, 0x00, 0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00,
    }, "Hello world\n");
}

test "zlib decompress non compressed block (type 0)" {
    try testDecompress(.zlib, &[_]u8{
        0x78, 0b10_0_11100, // zlib header (2 bytes)
        0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, // deflate fixed buffer header len, nlen
        'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a, // non compressed data
        0x1c, 0xf2, 0x04, 0x47, // zlib footer: checksum
    }, "Hello world\n");
}

test "invalid block type" {
    try testFailure(.raw, &[_]u8{0b110}, error.InvalidBlockType);
}

test "reading into empty buffer" {
    // Inspired by https://github.com/ziglang/zig/issues/19895
    const input = &[_]u8{
        0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, // deflate fixed buffer header len, nlen
        'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a, // non compressed data
    };
    var in: Reader = .fixed(input);
    var decomp: Decompress = .init(&in, .raw, &.{});
    const r = &decomp.reader;
    var bufs: [1][]u8 = .{&.{}};
    try testing.expectEqual(0, try r.readVec(&bufs));
}

test "zlib header" {
    // Truncated header
    try testFailure(.zlib, &[_]u8{0x78}, error.EndOfStream);

    // Wrong CM
    try testFailure(.zlib, &[_]u8{ 0x79, 0x94 }, error.BadZlibHeader);

    // Wrong CINFO
    try testFailure(.zlib, &[_]u8{ 0x88, 0x98 }, error.BadZlibHeader);

    // Truncated checksum
    try testFailure(.zlib, &[_]u8{ 0x78, 0xda, 0x03, 0x00, 0x00 }, error.EndOfStream);
}

test "gzip header" {
    // Truncated header
    try testFailure(.gzip, &[_]u8{ 0x1f, 0x8B }, error.EndOfStream);

    // Wrong CM
    try testFailure(.gzip, &[_]u8{
        0x1f, 0x8b, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03,
    }, error.BadGzipHeader);

    // Truncated checksum
    try testFailure(.gzip, &[_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x03, 0x00, 0x00, 0x00, 0x00,
    }, error.EndOfStream);

    // Truncated initial size field
    try testFailure(.gzip, &[_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    }, error.EndOfStream);

    try testDecompress(.gzip, &[_]u8{
        // GZIP header
        0x1f, 0x8b, 0x08, 0x12, 0x00, 0x09, 0x6e, 0x88, 0x00, 0xff, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00,
        // header.FHCRC (should cover entire header)
        0x99, 0xd6,
        // GZIP data
        0x01, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }, "");
}

test "zlib should not overshoot" {
    // Compressed zlib data with extra 4 bytes at the end.
    const data = [_]u8{
        0x78, 0x9c, 0x73, 0xce, 0x2f, 0xa8, 0x2c, 0xca, 0x4c, 0xcf, 0x28, 0x51, 0x08, 0xcf, 0xcc, 0xc9,
        0x49, 0xcd, 0x55, 0x28, 0x4b, 0xcc, 0x53, 0x08, 0x4e, 0xce, 0x48, 0xcc, 0xcc, 0xd6, 0x51, 0x08,
        0xce, 0xcc, 0x4b, 0x4f, 0x2c, 0xc8, 0x2f, 0x4a, 0x55, 0x30, 0xb4, 0xb4, 0x34, 0xd5, 0xb5, 0x34,
        0x03, 0x00, 0x8b, 0x61, 0x0f, 0xa4, 0x52, 0x5a, 0x94, 0x12,
    };

    var reader: std.Io.Reader = .fixed(&data);

    var decompress_buffer: [flate.max_window_len]u8 = undefined;
    var decompress: Decompress = .init(&reader, .zlib, &decompress_buffer);
    var out: [128]u8 = undefined;

    {
        const n = try decompress.reader.readSliceShort(&out);
        try std.testing.expectEqual(46, n);
        try std.testing.expectEqualStrings("Copyright Willem van Schaik, Singapore 1995-96", out[0..n]);
    }

    // 4 bytes after compressed chunk are available in reader.
    const n = try reader.readSliceShort(&out);
    try std.testing.expectEqual(n, 4);
    try std.testing.expectEqualSlices(u8, data[data.len - 4 .. data.len], out[0..n]);
}

fn testFailure(container: Container, in: []const u8, expected_err: anyerror) !void {
    var reader: Reader = .fixed(in);
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var decompress: Decompress = .init(&reader, container, &.{});
    try testing.expectError(error.ReadFailed, decompress.reader.streamRemaining(&aw.writer));
    try testing.expectEqual(expected_err, decompress.err orelse return error.TestFailed);
}

fn testDecompress(container: Container, compressed: []const u8, expected_plain: []const u8) !void {
    var in: std.Io.Reader = .fixed(compressed);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    var decompress: Decompress = .init(&in, container, &.{});
    const decompressed_len = try decompress.reader.streamRemaining(&aw.writer);
    try testing.expectEqual(expected_plain.len, decompressed_len);
    try testing.expectEqualSlices(u8, expected_plain, aw.written());
}

// ── Blimp: a body cut off or corrupted is an error, never a panic ────────

const blimp_test_data = struct {
    pub const hello_gz = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xed\xc4\x31\x0d\x00\x00\x08\x03\x30\x2b\x98\x23\xe1\x58\x82\xff\x0f\x11\xbc\xed\xd1\xe9\x64\x6b\x6c\xdb\xb6\x6d\xdb\xb6\x6d\xdb\xf6\xe3\x03\xc1\x37\x0c\x40\x70\x17\x00\x00";
    pub const words_gz = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x95\x5a\x59\x6e\xdb\x40\x0c\xfd\xe7\x29\x74\x83\xfc\x07\x45\xef\x92\x16\x46\x12\xb4\x71\x8c\x44\x3f\xbd\x7d\x6d\x78\x16\xf2\x2d\xa3\x44\x41\x61\x59\x9a\x85\x43\x3e\x3e\x2e\xee\xe5\xe3\xfd\x72\xfa\xd8\xff\x6d\x3f\xde\x4e\xfb\xd3\xcf\xed\x65\xdf\x2f\x9f\x8f\x0f\x0f\xdb\xaf\xbf\xaf\xe7\x3f\x9f\xdb\xfb\xf3\xe3\xeb\xdb\xd3\xf3\x69\xbb\x5e\xe3\xfe\xd2\x27\xb5\x41\xd7\x6b\x7f\x39\xd1\x94\xb1\xd6\xb8\x19\xaf\x6e\xc3\xf3\xd2\x76\xdb\xb4\x2e\x8e\x49\xaf\xae\x57\x93\xff\xf7\xfb\x79\x3f\x9d\xf7\x39\xb8\x3d\xcf\xe2\xf7\x31\x73\x56\xd9\x6e\x9c\x4e\x9e\x3d\x6d\x1e\x45\xf2\x31\x2d\xae\x7f\xe3\x4b\xdf\xeb\x36\xbe\x6d\x56\xce\x9e\x64\x89\xbc\x44\x7f\x3e\x06\x4a\x6d\xb5\x15\x2f\x60\xc4\x58\x9a\x71\x8c\xe6\x9b\x9b\xe8\xbc\x63\x97\x25\x48\x0b\xf3\x0d\xe9\x1d\x31\x12\x24\xe5\x58\x2c\xb2\x52\xfb\x42\x49\x59\x8c\xa3\x24\x09\x1f\xf9\x7a\xc1\x22\xea\x15\x0b\x3a\x9e\x24\x5b\xe1\x36\x49\xaa\x04\xbf\x40\xf4\xf5\xcf\xf6\x5e\x88\xc1\xba\x9f\x40\x1d\xab\x66\x53\x2f\x6e\x92\x22\x95\x8f\x14\x70\x07\x9d\x0c\x0d\x85\x36\x16\x0e\x64\xa7\x14\x6b\x81\x4e\x14\xda\x18\x6b\xd1\xfe\x08\xff\x56\xec\x89\x41\xd2\xe0\x4d\x9c\xac\x6b\x1a\x90\xf0\xa0\x3c\x12\x27\x8e\xef\x6d\xe1\xfb\x55\x9e\xf6\x7f\x05\x4c\x6d\x78\x90\xe2\xac\x1b\x15\x1e\x0a\xa1\x3b\xcd\xa4\x77\x0b\x97\xc9\xf7\x47\xec\x84\xac\xfa\x22\x72\x10\x68\x79\x66\x72\x47\xc6\x62\x75\x98\xf6\x51\x21\x15\xf3\x46\x98\x68\xb2\x73\x55\x56\xa6\x32\x94\x11\xfc\x32\x6b\x33\x99\xb5\xe8\x27\x3d\x47\xe4\xb6\x55\x92\x1d\xf2\xa0\xb9\x7d\xb9\xcb\xfe\x2b\x4f\x5d\x3f\xa2\x9c\x07\x77\x1c\x97\x1c\xd6\x4f\x0b\x6c\x93\x47\x46\x1a\x9e\x7c\x0c\x36\xc8\x8b\xc4\xd8\xb1\xbd\x48\x3e\xd2\x9e\x30\x36\x14\x24\x34\x54\x75\x2a\xe0\xbc\x1d\x61\x01\xbc\x1e\x15\xfd\x69\xf3\xc4\xd3\x82\x7c\x0f\xb8\x7f\xe1\x6d\xe8\xc0\x59\x91\x31\xfd\x8c\x37\xa8\x5a\x64\xe7\x2b\x07\x21\x2e\xd2\xf1\xc4\x45\xb9\x45\x0e\x54\x59\x88\xf6\x31\xf1\xca\x8d\xa3\xe7\xfa\x38\xf4\x36\x94\xfa\x48\xfc\xea\x3d\x0d\x7b\x88\x10\x2d\x79\xc6\x14\x80\xb7\xe0\xdc\x85\x28\xe0\x8f\x4a\x40\x53\xa0\xe9\x21\xd1\x1c\x43\x61\x11\x48\x23\x93\x12\x31\xb5\x25\xdd\x7a\x3e\xa7\x7f\xc3\x60\x2c\x15\xc8\x01\x07\x0d\x20\xa9\xa9\x33\x50\x0c\x7b\x0a\xc6\x43\xc1\xc4\xe8\xd4\x88\x05\x95\xd7\x80\x11\x9b\xd6\x0f\x61\x68\x8a\x1a\xfc\x8e\x50\xc1\xea\xc4\x5a\x85\x12\x3f\xc2\xac\x0e\x17\x95\xc3\x31\xe3\xaa\xb6\x5e\xc6\xdd\xb9\x50\x75\x93\x60\x93\xe6\x03\x65\x0a\xca\xf7\x22\xef\x42\xb8\xde\x57\x57\x11\x9f\xf6\x54\xfe\x4a\x71\x57\x6b\x2e\x65\x2c\x92\x5b\x0a\x22\x26\x3c\x03\xce\x29\x63\x0b\xa1\xb8\xce\x11\xb5\x4c\x3f\x37\x13\xf4\x34\x29\xb9\x04\xbf\xe2\x28\x42\xca\x94\x6e\x5e\x46\x38\xd2\x67\xf7\xf9\x46\xf4\x5a\xf8\x9e\x70\x62\x3a\xea\x57\x2a\x7e\xde\x02\xd0\x42\x5a\x82\xe7\x82\xda\x65\x41\x55\x28\xc6\x7a\xfe\x64\x6f\xdc\x8f\xb3\x08\xa2\xbf\xe9\xcb\x5c\x7d\x5a\x80\xe3\x67\x41\x57\x89\x4a\x47\xc9\x74\xb1\x4d\x4e\xd5\x4a\x07\x41\x44\x7f\xc2\x31\x3a\xe5\xa6\x8a\x3c\x99\x2e\xab\xbe\x0c\xdf\xb4\x3d\xc9\xe4\xdc\x1c\x58\xb8\x0f\xda\x29\x8b\xa0\x5a\x03\x0e\x60\xd5\xa9\xd2\x84\x58\xc6\xc9\xc0\x34\x33\xc5\x69\x51\x1b\xcb\x4c\x9d\xb3\x13\x0d\x6e\x55\x8c\x30\xe9\xa8\x52\x55\xaa\x39\x6d\xc4\x05\xaf\xd0\xf9\x68\x6a\x35\x60\x29\x23\xeb\x9c\xe8\x3e\xd3\x27\x8c\x45\x3c\x5d\x9b\x2e\x08\xac\xb8\x0a\x68\x2e\xeb\x7e\x96\xbf\x18\xb5\xea\x53\x11\x12\x92\x69\x2c\x1d\x2f\x1a\x90\x66\x84\x79\xbb\x2c\xc3\x55\xaf\x61\xe2\x8c\x82\x17\x6b\x8b\xb3\x13\xa4\x38\x9f\x30\x2d\x02\x01\x82\x8c\x28\x81\xa7\x0c\xef\x2e\x14\x32\xd2\x65\x25\x31\xc2\xad\x6c\x69\xd2\x37\xdf\x97\x2c\x7e\xcb\xdb\x1d\xe5\xfd\x96\xcb\x4d\xab\xac\x6c\x27\xa3\x36\x07\x17\xec\x12\x88\x70\xa7\xf4\x24\x9b\xd4\xaa\xfd\xa6\x8b\xee\xdc\x62\xdc\xb8\xd1\xb5\x20\x9f\x75\xa9\x57\x58\x75\x51\x84\x47\xa7\x18\x5b\xea\xda\x64\x43\x25\xeb\x81\xfd\xf5\xf4\x55\x96\x1e\x2c\x70\x1e\x26\x82\x0e\xc7\x88\x02\x6e\x6e\xed\x49\x08\x42\xe3\x86\xa1\x39\x33\x0b\xca\xa6\x75\x60\xb6\x99\x5c\x45\x95\x28\xf2\xd4\x6c\x76\x6e\x50\xa2\x4a\x0b\xe3\xee\xd1\xac\x52\x19\x4e\x45\xc8\x3c\xec\x5f\xd8\xd4\xc9\xf9\x2b\xa7\x05\x78\x52\x9d\x3c\xa8\x80\x77\xec\x12\x8b\xba\x50\x76\x30\x45\x45\xb9\x42\x82\xab\x9c\xa8\xfb\xb8\x90\xac\xc6\x3f\x2c\x2f\x10\xbb\x36\x01\xa5\xce\x76\x71\x72\x91\x63\x1f\x37\x91\xf5\x2f\x2a\x1b\xf7\x42\x4d\xf9\x6b\xc1\xa2\x2d\x5c\x9b\xb9\x48\xbe\xa9\xe0\xea\xa5\x19\x67\xf8\xc7\x21\x7b\x71\xdc\xce\xb8\x32\x41\x90\x28\x40\xf2\xd8\x6c\xa3\x5a\x77\x15\x89\x4f\xd4\xcf\x90\x0e\x5c\xfe\x57\x96\x94\x7f\x55\x70\x6d\xd0\x60\x47\x70\xa9\x70\xe0\xfa\x70\x6e\xc0\xaa\x67\xde\x35\xac\xb2\xe4\x2f\x24\x2f\xf6\x37\x1f\x65\xcb\x74\x16\x4e\x4b\x6d\x04\xe3\xd4\x19\x8e\x27\x0b\x29\xd3\x0a\x0c\x91\xe5\xd7\x0f\x3a\x6b\xd6\x5e\x46\x9a\xac\x21\x54\x1e\x62\xe8\xad\xa0\xcd\x7a\x89\x75\x58\x22\x49\xf4\x55\xd6\x36\x4d\x31\xe4\xcd\x33\x85\x57\x29\x60\xce\x6c\x40\x94\xd3\xb6\x57\x96\x03\xa3\x2d\x92\x23\x03\x49\xf9\xa4\xa8\xe2\xbc\xbf\x32\xfc\x54\xaf\xd7\x35\x38\xf5\xef\x0a\x90\x48\xe9\xd8\xa9\x9f\xb6\xba\x99\x88\x4e\x36\x3d\x74\x8a\xba\x8a\xa0\xc7\x14\xbc\xc2\xc9\x1a\x09\x3a\xcf\xca\x84\xa2\x9b\x64\x94\xd4\x19\x91\x45\xd7\x51\xf5\x75\x7c\x8b\xdd\x39\xce\x51\xb5\x22\x9b\xf5\x94\x66\xae\x3a\x66\xac\x9a\x00\xff\xa1\x53\x9a\xc2\x78\xab\xbd\x59\x43\x58\xca\x45\xea\x8f\x97\xa6\x7f\x32\xcb\x7e\x9b\x1a\x85\x3e\xd0\xb7\x7a\x9a\xcb\xec\xd2\x26\xad\xf7\x4b\x31\x8d\xf8\x2f\x0c\xd2\x68\x5d\x15\xff\x01\x34\x42\xfd\xc9\xbd\x25\x00\x00";
    pub const dyn_gz = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x0b\xc9\x48\x55\x28\x2c\xcd\x4c\xce\x56\x48\x2a\xca\x2f\xcf\x53\x48\xcb\xaf\x50\xc8\x2a\xcd\x2d\x28\x56\xc8\x2f\x4b\x2d\x52\x28\x01\x4a\xe7\x24\x56\x55\x2a\xa4\xe4\xa7\xeb\x29\x84\xd0\x4c\xb1\x82\xa2\x92\xb2\x8a\xaa\x9a\xba\x86\xa6\x96\xb6\x8e\xae\x9e\xbe\x81\xa1\x91\xb1\x89\xa9\x99\xb9\x85\xa5\x95\xb5\x8d\xad\x9d\xbd\x83\xa3\x93\xb3\x8b\xab\x9b\xbb\x87\xa7\x97\xb7\x8f\xaf\x9f\x7f\x40\x60\x50\x70\x48\x68\x58\x78\x44\x64\x54\x74\x4c\x6c\x5c\x7c\x42\x62\x52\x72\x4a\x6a\x5a\x7a\x46\x66\x56\x76\x4e\x6e\x5e\x7e\x41\x61\x51\x71\x49\x69\x59\x79\x45\x65\x55\x75\x4d\x6d\x9d\x4d\x46\x49\x6e\x8e\x9d\x4d\x46\x6a\x62\x8a\x9d\x4d\x6e\x6a\x49\xa2\x42\x41\x51\x7e\x41\x6a\x51\x49\xa5\xad\x52\x7e\xba\x55\x49\x66\x49\x4e\xaa\x92\x42\x72\x7e\x5e\x49\x6a\x5e\x89\xad\x52\x52\x4e\x66\x5e\x76\xb1\x92\x9d\x8d\x3e\x44\x87\x3e\x58\x3b\x57\xc8\x68\x58\x8d\x86\xd5\x68\x58\x0d\x68\x58\x01\x00\xc6\x70\x7b\x2e\xb0\x04\x00\x00";
    pub const dyn_plain_len = 1200;
    pub const fixed_gz = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x13\xcb\x48\xcd\xc9\xc9\x57\xc8\x40\x22\xd3\x32\x2b\x52\x53\x14\x32\x4a\xd3\xd2\x72\x13\xf3\x00\x89\xa4\xd2\x07\x1f\x00\x00\x00";
};

/// Decompresses `in` in both of the decompressor's modes (no buffer: it
/// writes straight to the output; a window buffer: http.zig's choice) and
/// says whether it finished. Any other ending than finished or ReadFailed
/// with `err` set fails the test; a panic fails it harder.
fn blimpTryDecompress(container: Container, in: []const u8, buffered: bool) !bool {
    var reader: Reader = .fixed(in);
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const window = try testing.allocator.alloc(u8, if (buffered) flate.max_window_len else 0);
    defer testing.allocator.free(window);
    var d: Decompress = .init(&reader, container, window);
    _ = d.reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => {
            try testing.expect(d.err != null);
            return false;
        },
        error.WriteFailed => return err,
    };
    return true;
}

test "Blimp: a gzip body cut off at any byte is an error, not a panic" {
    for ([_][]const u8{ blimp_test_data.dyn_gz, blimp_test_data.fixed_gz, blimp_test_data.hello_gz, blimp_test_data.words_gz }) |gz| {
        for ([_]bool{ false, true }) |buffered| {
            for (0..gz.len) |n| {
                try testing.expect(!try blimpTryDecompress(.gzip, gz[0..n], buffered));
            }
            try testing.expect(try blimpTryDecompress(.gzip, gz, buffered));
        }
    }
}

test "Blimp: a gzip body with any one bit flipped decompresses or is an error, not a panic" {
    var buf: [blimp_test_data.dyn_gz.len]u8 = undefined;
    for ([_]bool{ false, true }) |buffered| {
        for (0..buf.len * 8) |bit| {
            @memcpy(&buf, blimp_test_data.dyn_gz);
            buf[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
            _ = try blimpTryDecompress(.gzip, &buf, buffered);
        }
    }
}

//! The two numbers a scope lookup wants of a name, computed once.
//!
//! `Environment.lookup` and `defineIn` need `hashName(name)` and
//! `nameBit(name)`.  Computing them from the string on every read hashed a
//! parameter's name once per loop iteration.  The parser computes them once
//! per node and carries them in a `Key`; a node built by hand has the empty
//! key (`bit == 0`, which `nameBit` never returns) and the evaluator hashes
//! for it as before.

/// FNV-1a over the name's bytes.
pub fn hashName(name: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (name) |c| {
        h ^= c;
        h *%= 0x01000193;
    }
    return h;
}

/// The bit a name claims in a scope's `names` mask.  Never zero.
pub fn nameBit(name: []const u8) u64 {
    if (name.len == 0) return 1;
    const first: u64 = name[0];
    const last: u64 = name[name.len - 1];
    const h = first ^ (last << 2) ^ (@as(u64, name.len) << 4);
    return @as(u64, 1) << @as(u6, @truncate(h));
}

pub const Key = struct {
    hash: u32 = 0,
    /// 0 means "not computed".
    bit: u64 = 0,

    pub fn of(name: []const u8) Key {
        return .{ .hash = hashName(name), .bit = nameBit(name) };
    }

    pub fn isSet(self: Key) bool {
        return self.bit != 0;
    }
};

//! Copying collection for the evaluator heap.
//!
//! The tree-walking evaluator never frees anything: every value, closure
//! capture and scope binding stays alive for the life of the allocator it
//! was created in.  That is fine for a one-shot native run (an arena freed
//! at exit) but a browser session evaluates thousands of small programs
//! against the same evaluator, so the WASM host needs a way to drop the
//! garbage between evals.
//!
//! `compact` copies everything the evaluator can still reach (the global
//! environment, the actor registry with each instance's state and mailbox,
//! and a few evaluator fields) into a fresh allocator and points the
//! evaluator at it.  The caller then frees the old allocator.  Values are
//! immutable and closures capture flat binding lists, so a deep copy that
//! remembers where each value went preserves sharing and terminates on
//! cycles.  AST nodes and source text are not copied: closures and handlers
//! keep pointing at them, so those must live in an allocator that outlives
//! every compaction.
//!
//! Where each value went is a forwarding table, not a hash map.  The old
//! heap is an `ArenaAllocator`, a short list of large chunks, so a value in
//! it is named by (chunk, offset / @sizeOf(Value)): two distinct values
//! never overlap, so no two share a slot.  The table is one pointer per
//! @sizeOf(Value) bytes of old heap, mapped fresh (and so zeroed) per
//! compaction.  It is kept beside the heap rather than written over the old
//! values: the old heap must stay intact until the copy has succeeded,
//! because a compaction that runs out of memory part-way leaves the
//! evaluator on the old heap (see `compactWith`).  A value outside the old
//! heap (a literal the parser built in the code arena, say) still goes
//! through a hash map, as every value used to; the small integers, the
//! booleans and nil from `value.interned` are static and are kept as they
//! are.
//!
//! Strings are copied only when their bytes are in the old heap.  A name
//! the parser interned (name_key.zig) is kept as is, so its pointer stays
//! the one every AST node holds and `sameName` keeps answering on the
//! pointer after a compaction; copying it used to un-intern every binding
//! and map key the first time the heap was compacted.
//!
//! Only call this between evals.  Nothing on the Zig stack may hold a value
//! pointer (no active handler, no actor context) when it runs.

const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Evaluator = @import("eval.zig").Evaluator;
const Environment = @import("env.zig").Environment;
const registry_mod = @import("registry.zig");
const Registry = registry_mod.Registry;
const mailbox_mod = @import("mailbox.zig");
const Mailbox = mailbox_mod.Mailbox;
const Message = mailbox_mod.Message;
const name_key = @import("name_key.zig");

pub const CompactError = error{OutOfMemory};

/// Copy the evaluator's live data into `to` and make `to` its allocator.
/// `from` is the arena the evaluator allocates from now, when the caller
/// has one; without it every value is looked up in a hash map, which is
/// correct and several times slower.  `scratch` holds the bookkeeping for
/// the duration of the call and is left clean.  On error the evaluator is
/// untouched (everything already copied into `to` is simply abandoned
/// there).
pub fn compact(eval: *Evaluator, from: ?*const std.heap.ArenaAllocator, to: std.mem.Allocator, scratch: std.mem.Allocator) CompactError!void {
    _ = try compactWith(eval, from, to, scratch, .keep_all);
}

/// What a compaction does with actors nothing can reach.
pub const Actors = enum {
    /// Copy every instance, reachable or not. The REPL and the browser keep
    /// this: a host (blimp.js) may hold an actor's id where no Blimp value
    /// does, so "unreachable from Blimp" does not mean unreachable.
    keep_all,
    /// Copy only the instances a live value can still name, and those with
    /// work pending. `blimp --serve` uses this: its only host is the tick,
    /// and every actor a program means to keep is bound somewhere.
    drop_unreachable,
};

/// The same, and the number of actor instances left behind.
///
/// An actor instance is kept when:
///   - some value copied from a root (the top-level scope, the templates'
///     defaults, the pending bubble) or from a kept actor's state or mailbox
///     holds its ref, or
///   - it has messages waiting, is not idle, or is on the scheduler's run
///     queue: it has work to do whether or not anyone holds it.
/// Everything else can never receive another message, so it is dropped with
/// the rest of the garbage. Ids are never reused (`next_id` only grows), so
/// a ref printed before the drop still names nothing rather than someone
/// else.
pub fn compactWith(eval: *Evaluator, from: ?*const std.heap.ArenaAllocator, to: std.mem.Allocator, scratch: std.mem.Allocator, actors: Actors) CompactError!usize {
    const r = try compactPlan(eval, .{ .from = from, .to = to, .scratch = scratch, .actors = actors });
    return r.dropped;
}

/// An address range [lo, hi) that one compare-and-subtract answers for.
pub const Region = struct {
    lo: usize = 0,
    hi: usize = 0,

    pub fn of(bytes: []const u8) Region {
        return .{ .lo = @intFromPtr(bytes.ptr), .hi = @intFromPtr(bytes.ptr) + bytes.len };
    }

    pub inline fn has(self: Region, addr: usize) bool {
        return addr -% self.lo < self.hi -% self.lo;
    }

    pub fn len(self: Region) usize {
        return self.hi - self.lo;
    }
};

/// Everything a compaction needs to know.
///
/// The old space.  A long-lived server builds most of its heap once, at
/// boot (prebuilt pages, parsed data files), and never changes it; copying
/// all of that on every compaction made each pause as long as the whole
/// live set.  A *promotion* (`promote_into`) writes the immutable data it
/// copies (values, strings, element lists, map entries, closures, captures,
/// view nodes, handler tables) into one caller-owned region instead of
/// `to`.  Later compactions pass that region as `keep`: a value, string or
/// handler table inside it is returned unchanged and not followed.
///
/// That is sound because of what goes in the region and what does not.
/// Values are immutable, and a promotion copies a value's children before
/// anything can point at the copy, so the region only ever points into
/// itself, at interned names, at the static small values, and at AST nodes
/// (which outlive every compaction).  Nothing old can come to point at
/// something young.  What *is* mutated after it is made -- the scope
/// binding lists (rebound in place), each actor's entry and its
/// `state_fields` (written by `become`), mailboxes, the registry's lists,
/// handle tables -- is never put in the region: it is allocated from `to`
/// on every compaction, promotion included, and walked as a root each time.
/// The test "a binding and an actor's state rebound after promotion survive
/// compaction" fails if one of those ends up in the region.
pub const Plan = struct {
    /// The arena the evaluator allocates from now (see `compact`).
    from: ?*const std.heap.ArenaAllocator,
    to: std.mem.Allocator,
    scratch: std.mem.Allocator,
    actors: Actors = .keep_all,
    /// The current old space: kept where it is, never followed.
    keep: Region = .{},
    /// Promote: put every immutable thing copied into this region.  When it
    /// is too small the compaction fails with OutOfMemory and changes
    /// nothing.  `keep` must not overlap it; to re-promote, pass the
    /// previous old space as `also_from` instead of `keep`, and free it
    /// after.
    promote_into: ?[]u8 = null,
    /// More from-space beside `from`: a previous old space being folded
    /// into a new one.
    also_from: Region = .{},
    /// The actor ids the values in `keep` name (`Result.old_refs` of the
    /// promotion that made it).  The copier does not look inside `keep`, so
    /// without these `.drop_unreachable` would drop an actor that only an
    /// old value holds -- the site's own top-level actors, for one.
    keep_refs: []const u64 = &.{},
};

pub const Result = struct {
    /// Actor instances left behind (see `compactWith`).
    dropped: usize,
    /// Bytes of `promote_into` used, from its start.
    promoted: usize = 0,
    /// After a promotion: every actor id a promoted value names, allocated
    /// from `scratch` and owned by the caller, to pass back as `keep_refs`.
    old_refs: []u64 = &.{},
};

pub fn compactPlan(eval: *Evaluator, plan: Plan) CompactError!Result {
    const to = plan.to;
    const scratch = plan.scratch;
    const from = plan.from;
    const actors = plan.actors;
    var copier = Copier{
        .to = to,
        .keep = plan.keep,
        .values = std.AutoHashMap(usize, *const Value).init(scratch),
        .handlers = std.AutoHashMap(usize, []const Value.HandlerDef).init(scratch),
        .seen = std.AutoHashMap(u64, void).init(scratch),
        .pending = .{ .items = &.{}, .capacity = 0 },
        .scratch = scratch,
    };
    defer copier.values.deinit();
    defer copier.handlers.deinit();
    defer copier.seen.deinit();
    defer copier.pending.deinit(scratch);
    if (plan.promote_into) |region| copier.bump = .{ .buf = region, .fixed = true };
    var old_ids = std.AutoHashMap(u64, void).init(scratch);
    defer old_ids.deinit();
    if (plan.promote_into != null) copier.old_ids = &old_ids;
    for (plan.keep_refs) |id| try copier.see(id);
    if (from) |arena| copier.old = try Forwarding.init(scratch, arena, plan.also_from);
    defer copier.old.deinit(scratch);
    copier.interned = try internedRanges(scratch);
    defer scratch.free(copier.interned);

    // Build every replacement first, then swap them in, so a failure
    // part-way leaves the evaluator consistent.
    const scopes = try copier.scopes(eval.env.scopes.items);
    const templates = try copier.templates(eval.registry.templates.items);
    const bubble_reason: ?*const Value = if (eval.bubble_reason) |r| try copier.value(r) else null;
    if (eval.scheduler) |sched| {
        for (sched.run_queue.items) |id| try copier.see(id);
    }
    // Buffers and hash maps (handles.zig) hold pointers into the heap being
    // left; their storage is outside it.  The copies are made here, before
    // the instances, because a value in a buffer may name an actor, and
    // written back with the rest of the swap at the end.  Compaction used
    // to refuse once any buffer existed, so a Temper program, whose
    // ListBuilder is a buffer, never freed anything.
    const handles_mod = @import("handles.zig");
    const handle_old = try handles_mod.valuePointers(scratch);
    defer scratch.free(handle_old);
    const handle_new = try scratch.alloc(*const Value, handle_old.len);
    defer scratch.free(handle_new);
    for (handle_old, 0..) |v, i| handle_new[i] = try copier.value(v);
    const old_instances = eval.registry.instances.items;
    const instances = switch (actors) {
        .keep_all => try copier.instances(old_instances),
        .drop_unreachable => try copier.reachableInstances(old_instances),
    };
    const dropped = old_instances.len - instances.items.len;
    // One slot per entry the evaluator can hold.  The WASM host drains the
    // log after every eval so 64 was enough there; a REPL that never reads it
    // fills all 256 and used to walk off the end of this buffer.
    var msg_log: [Evaluator.msg_log_cap]Evaluator.MsgLogEntry = undefined;
    for (0..eval.msg_log_count) |i| {
        const e = eval.msg_log[i];
        msg_log[i] = .{
            .target_id = e.target_id,
            .target_type = try copier.str(e.target_type),
            .message = try copier.str(e.message),
        };
    }
    // The builtin table's storage is in the heap being left; its contents
    // are static, so it is copied rather than built again.
    const builtins = try eval.builtins.cloneInto(to);
    const old_refs = try scratch.alloc(u64, old_ids.count());
    {
        var it = old_ids.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) old_refs[i] = k.*;
    }

    eval.env.scopes = scopes;
    // The recycled binding lists belong to the allocator being dropped.
    eval.env.free_scopes = .{ .items = &.{}, .capacity = 0 };
    eval.env.allocator = to;
    eval.env.reindexGlobals();
    eval.registry.templates = templates;
    eval.registry.instances = instances;
    eval.registry.allocator = to;
    eval.registry.reindex();
    eval.bubble_reason = bubble_reason;
    for (0..eval.msg_log_count) |i| eval.msg_log[i] = msg_log[i];
    eval.builtins = builtins;
    eval.allocator = to;
    handles_mod.relocate(handle_new);
    const promoted = if (plan.promote_into) |region| @intFromPtr(copier.bump.buf.ptr) - @intFromPtr(region.ptr) else 0;
    return .{ .dropped = dropped, .promoted = promoted, .old_refs = old_refs };
}

/// An address range, [lo, hi).
const Range = struct {
    lo: usize,
    hi: usize,
    /// Forwarding: the table index of the slot for address `lo`.
    first_slot: usize = 0,

    fn lessThan(_: void, a: Range, b: Range) bool {
        return a.lo < b.lo;
    }
};

/// The chunks an arena has handed out, sorted by address.
///
/// This reads `ArenaAllocator`'s private node list (zig 0.16's layout: each
/// chunk starts with a node whose `size`, low bit masked, is the chunk's
/// length, header included).  The test "the old heap's chunks are found"
/// fails if a std upgrade changes that.  Only `used_list` holds memory that
/// was handed out; `free_list` chunks were never or are no longer in use.
fn arenaRanges(scratch: std.mem.Allocator, arena: *const std.heap.ArenaAllocator) CompactError![]Range {
    var n: usize = 0;
    var it = arena.state.used_list;
    while (it) |node| : (it = node.next) n += 1;
    const out = try scratch.alloc(Range, n);
    it = arena.state.used_list;
    var i: usize = 0;
    while (it) |node| : (it = node.next) {
        const size = @as(usize, @bitCast(node.size)) & ~@as(usize, 1);
        out[i] = .{ .lo = @intFromPtr(node), .hi = @intFromPtr(node) + size };
        i += 1;
    }
    std.mem.sort(Range, out, {}, Range.lessThan);
    return out;
}

fn findRange(ranges: []const Range, addr: usize) ?*const Range {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (addr < ranges[mid].lo) {
            hi = mid;
        } else if (addr >= ranges[mid].hi) {
            lo = mid + 1;
        } else return &ranges[mid];
    }
    return null;
}

fn internedRanges(scratch: std.mem.Allocator) CompactError![]Range {
    const arena = name_key.lockArena();
    defer name_key.unlockArena();
    return arenaRanges(scratch, arena);
}

/// Where each value of the old heap went: one slot per @sizeOf(Value)
/// bytes of every chunk.
const Forwarding = struct {
    ranges: []Range = &.{},
    slots: []?*const Value = &.{},

    const grain = @sizeOf(Value);

    fn init(scratch: std.mem.Allocator, arena: *const std.heap.ArenaAllocator, extra: Region) CompactError!Forwarding {
        var ranges = try arenaRanges(scratch, arena);
        errdefer scratch.free(ranges);
        if (extra.len() > 0) {
            ranges = try scratch.realloc(ranges, ranges.len + 1);
            ranges[ranges.len - 1] = .{ .lo = extra.lo, .hi = extra.hi };
            std.mem.sort(Range, ranges, {}, Range.lessThan);
        }
        var total: usize = 0;
        for (ranges) |*r| {
            r.first_slot = total;
            total += (r.hi - r.lo) / grain + 1;
        }
        return .{ .ranges = ranges, .slots = try zeroedSlots(scratch, total) };
    }

    fn deinit(self: *Forwarding, scratch: std.mem.Allocator) void {
        scratch.free(self.ranges);
        freeSlots(scratch, self.slots);
        self.* = .{};
    }

    /// The slot for `v`, or null when `v` is not in the old heap.
    inline fn slot(self: *const Forwarding, v: *const Value) ?*?*const Value {
        const addr = @intFromPtr(v);
        const r = findRange(self.ranges, addr) orelse return null;
        return &self.slots[r.first_slot + (addr - r.lo) / grain];
    }

    // Natively the table comes straight from mmap, which hands back zeroed
    // pages and materialises only the ones touched; a heap of 170MB needs a
    // 43MB table, so a memset of it would cost more than the lookups save.
    // WASM's page allocator reuses memory, so it is cleared there.
    const use_pages = !builtin.target.cpu.arch.isWasm();

    fn zeroedSlots(scratch: std.mem.Allocator, n: usize) CompactError![]?*const Value {
        if (n == 0) return &.{};
        if (use_pages) {
            // rawAlloc, not alloc: in safe builds `alloc` fills the memory
            // with 0xaa, which both touches every page and reads as a
            // forwarding pointer.
            const bytes = n * @sizeOf(?*const Value);
            const p = std.heap.page_allocator.rawAlloc(bytes, .of(?*const Value), @returnAddress()) orelse return error.OutOfMemory;
            const slots: [*]?*const Value = @ptrCast(@alignCast(p));
            return slots[0..n];
        }
        const out = try scratch.alloc(?*const Value, n);
        @memset(out, null);
        return out;
    }

    fn freeSlots(scratch: std.mem.Allocator, slots: []?*const Value) void {
        if (slots.len == 0) return;
        if (use_pages) {
            std.heap.page_allocator.rawFree(std.mem.sliceAsBytes(slots), .of(?*const Value), @returnAddress());
        } else scratch.free(slots);
    }
};

/// Bump allocation in large blocks taken from `to`.  Every value the copier
/// makes is immutable and is never freed or resized on its own (the whole
/// heap goes at the next compaction), so there is no reason to pay the
/// arena's per-allocation atomics for each of a million small objects.
/// Lists the evaluator appends to later (scopes, bindings, mailboxes, the
/// registry's) are allocated from `to` directly.
const Bump = struct {
    buf: []u8 = &.{},
    /// A promotion's region: everything goes in `buf`, and running out of
    /// it is running out of memory.
    fixed: bool = false,

    /// Small next to the arena's own chunks (which grow by half each time):
    /// when a block does not fit the rest of a chunk the arena starts a new
    /// one and the rest is wasted, so a big block wastes a big tail. 4MB
    /// blocks made a 106MB heap measure 176MB, and 64KB ones 109MB.
    const block = 16 * 1024;

    fn bytes(self: *Bump, to: std.mem.Allocator, n: usize, comptime alignment: usize) CompactError![*]u8 {
        const base = @intFromPtr(self.buf.ptr);
        const pad = std.mem.alignForward(usize, base, alignment) - base;
        if (pad + n <= self.buf.len) {
            const p = self.buf.ptr + pad;
            self.buf = self.buf[pad + n ..];
            return p;
        }
        if (self.fixed) return error.OutOfMemory;
        // rawAlloc: `alloc` would fill the memory with 0xaa in a safe
        // build, a second pass over every byte about to be written.
        if (n > block / 4) return to.rawAlloc(n, .fromByteUnits(alignment), @returnAddress()) orelse error.OutOfMemory;
        const fresh = to.rawAlloc(block, .@"16", @returnAddress()) orelse return error.OutOfMemory;
        self.buf = fresh[n..block];
        return fresh;
    }
};

const Copier = struct {
    to: std.mem.Allocator,
    bump: Bump = .{},
    old: Forwarding = .{},
    keep: Region = .{},
    /// Promoting: the actor ids promoted values name (Result.old_refs).
    old_ids: ?*std.AutoHashMap(u64, void) = null,
    interned: []Range = &.{},
    /// Values outside the old heap, by address.
    values: std.AutoHashMap(usize, *const Value),
    handlers: std.AutoHashMap(usize, []const Value.HandlerDef),
    /// Every actor id a copied value holds, and those not yet visited.
    seen: std.AutoHashMap(u64, void),
    pending: std.ArrayList(u64),
    scratch: std.mem.Allocator,

    fn create(self: *Copier, comptime T: type) CompactError!*T {
        comptime std.debug.assert(@alignOf(T) <= 16);
        return @ptrCast(@alignCast(try self.bump.bytes(self.to, @sizeOf(T), @alignOf(T))));
    }

    fn alloc(self: *Copier, comptime T: type, n: usize) CompactError![]T {
        comptime std.debug.assert(@alignOf(T) <= 16);
        if (n == 0) return &.{};
        const p: [*]T = @ptrCast(@alignCast(try self.bump.bytes(self.to, @sizeOf(T) * n, @alignOf(T))));
        return p[0..n];
    }

    fn see(self: *Copier, id: u64) CompactError!void {
        const got = try self.seen.getOrPut(id);
        if (!got.found_existing) try self.pending.append(self.scratch, id);
    }

    /// The bytes of `s` where they will still be after the old heap is
    /// freed: kept when they are an interned name, copied otherwise.
    fn str(self: *Copier, s: []const u8) CompactError![]const u8 {
        if (s.len == 0) return s;
        if (self.keep.has(@intFromPtr(s.ptr))) return s;
        if (findRange(self.interned, @intFromPtr(s.ptr)) != null) return s;
        const out = try self.alloc(u8, s.len);
        @memcpy(out, s);
        return out;
    }

    fn optStr(self: *Copier, s: ?[]const u8) CompactError!?[]const u8 {
        return if (s) |x| try self.str(x) else null;
    }

    fn value(self: *Copier, v: *const Value) CompactError!*const Value {
        if (value_mod.interned.isStatic(v)) return v;
        if (self.keep.has(@intFromPtr(v))) return v;
        // Record the copy before recursing so shared and cyclic references
        // resolve to it.
        var nv: *Value = undefined;
        if (self.old.slot(v)) |s| {
            if (s.*) |done| return done;
            nv = try self.create(Value);
            s.* = nv;
        } else {
            const got = try self.values.getOrPut(@intFromPtr(v));
            if (got.found_existing) return got.value_ptr.*;
            nv = self.create(Value) catch |err| {
                _ = self.values.remove(@intFromPtr(v));
                return err;
            };
            got.value_ptr.* = nv;
        }
        nv.* = switch (v.*) {
            .integer, .float, .boolean, .nil, .hole => v.*,
            .string => |s| .{ .string = try self.str(s) },
            .atom => |a| .{ .atom = try self.str(a) },
            .list => |items| .{ .list = try self.valueList(items) },
            .tuple => |items| .{ .tuple = try self.valueList(items) },
            .map => |entries| .{ .map = try self.mapEntries(entries) },
            .actor_ref => |r| blk: {
                try self.see(r.id);
                if (self.old_ids) |ids| try ids.put(r.id, {});
                break :blk .{ .actor_ref = .{ .id = r.id, .type_name = try self.str(r.type_name) } };
            },
            .closure => |c| .{ .closure = try self.closure(c) },
            .view_node => |n| .{ .view_node = try self.viewNode(n) },
        };
        return nv;
    }

    fn viewNode(self: *Copier, n: *const Value.ViewNode) CompactError!*const Value.ViewNode {
        const out = try self.create(Value.ViewNode);
        out.* = .{
            .tag = try self.str(n.tag),
            .attrs = try self.attrs(n.attrs),
            .children = try self.valueList(n.children),
        };
        return out;
    }

    fn closure(self: *Copier, c: *const Value.Closure) CompactError!*const Value.Closure {
        const out = try self.create(Value.Closure);
        out.* = .{
            .params = c.params,
            .body = c.body,
            .env = try self.captured(c.env),
            // The bitmask lookup checks before it searches env; left at its
            // default of 0 it says the closure captured nothing, and every
            // captured name falls through to whatever the caller has bound.
            .env_names = c.env_names,
            .top_level = c.top_level,
            // The top-level scope is copied whole and in order, so the mark
            // still counts the same bindings.
            .globals_mark = c.globals_mark,
            .return_type = try self.optStr(c.return_type),
        };
        return out;
    }

    fn valueList(self: *Copier, items: []const *const Value) CompactError![]const *const Value {
        const out = try self.alloc(*const Value, items.len);
        for (items, 0..) |item, i| out[i] = try self.value(item);
        return out;
    }

    fn mapEntries(self: *Copier, entries: []const Value.MapEntry) CompactError![]Value.MapEntry {
        const out = try self.alloc(Value.MapEntry, entries.len);
        for (entries, 0..) |e, i| out[i] = .{ .key = try self.str(e.key), .val = try self.value(e.val) };
        return out;
    }

    fn captured(self: *Copier, bindings: []const Value.CapturedBinding) CompactError![]const Value.CapturedBinding {
        const out = try self.alloc(Value.CapturedBinding, bindings.len);
        for (bindings, 0..) |b, i| out[i] = .{ .name = try self.str(b.name), .val = try self.value(b.val), .hash = b.hash };
        return out;
    }

    fn attrs(self: *Copier, list: []const Value.ViewNode.ViewAttr) CompactError![]const Value.ViewNode.ViewAttr {
        const out = try self.alloc(Value.ViewNode.ViewAttr, list.len);
        for (list, 0..) |a, i| out[i] = .{ .key = try self.str(a.key), .val = try self.value(a.val) };
        return out;
    }

    // Handler tables are shared between a template and its instances, so
    // memo them by slice address to keep that sharing.
    fn handlerDefs(self: *Copier, defs: []const Value.HandlerDef) CompactError![]const Value.HandlerDef {
        if (defs.len == 0) return defs;
        if (self.keep.has(@intFromPtr(defs.ptr))) return defs;
        if (self.handlers.get(@intFromPtr(defs.ptr))) |done| return done;
        const out = try self.alloc(Value.HandlerDef, defs.len);
        for (defs, 0..) |h, i| out[i] = .{
            .name = try self.str(h.name),
            .hash = h.hash,
            .params = h.params,
            .guard = h.guard,
            .body = h.body,
            .bubble_strategy = try self.optStr(h.bubble_strategy),
        };
        try self.handlers.put(@intFromPtr(defs.ptr), out);
        return out;
    }

    fn scopes(self: *Copier, old: []const Environment.Scope) CompactError!std.ArrayList(Environment.Scope) {
        var out: std.ArrayList(Environment.Scope) = .{ .items = &.{}, .capacity = 0 };
        try out.ensureTotalCapacity(self.to, old.len);
        for (old) |scope| {
            var bindings: std.ArrayList(Environment.Binding) = .{ .items = &.{}, .capacity = 0 };
            try bindings.ensureTotalCapacity(self.to, scope.bindings.items.len);
            // The scope's name mask is rebuilt from what lands here rather
            // than copied: a stale mask hides bindings from every lookup.
            var names: u64 = 0;
            for (scope.bindings.items) |b| {
                const name = try self.str(b.name);
                names |= Environment.nameBit(name);
                bindings.appendAssumeCapacity(.{ .name = name, .val = try self.value(b.val), .hash = b.hash });
            }
            out.appendAssumeCapacity(.{ .bindings = bindings, .names = names });
        }
        return out;
    }

    fn templates(self: *Copier, old: []const registry_mod.ActorTemplate) CompactError!std.ArrayList(registry_mod.ActorTemplate) {
        var out: std.ArrayList(registry_mod.ActorTemplate) = .{ .items = &.{}, .capacity = 0 };
        try out.ensureTotalCapacity(self.to, old.len);
        for (old) |t| {
            out.appendAssumeCapacity(.{
                .name = try self.str(t.name),
                .default_state = try self.mapEntries(t.default_state),
                .handlers = try self.handlerDefs(t.handlers),
            });
        }
        return out;
    }

    // Entries are boxed so the evaluator's `*ActorEntry` survives a spawn;
    // a compaction moves them to a fresh box in the new heap.  Nothing may
    // be holding one of those pointers when this runs -- see the module
    // comment.
    fn instances(self: *Copier, old: []const *registry_mod.ActorEntry) CompactError!std.ArrayList(*registry_mod.ActorEntry) {
        var out: std.ArrayList(*registry_mod.ActorEntry) = .{ .items = &.{}, .capacity = 0 };
        try out.ensureTotalCapacity(self.to, old.len);
        for (old) |e| out.appendAssumeCapacity(try self.entry(e));
        return out;
    }

    fn entry(self: *Copier, e: *const registry_mod.ActorEntry) CompactError!*registry_mod.ActorEntry {
        // The entry and its state are written in place (`become`, status,
        // reductions), so they come from `to`, never from a promotion's
        // region: see `Plan`.
        const ne = try self.to.create(registry_mod.ActorEntry);
        const state = try self.to.alloc(Value.MapEntry, e.state_fields.len);
        for (e.state_fields, 0..) |f, i| state[i] = .{ .key = try self.str(f.key), .val = try self.value(f.val) };
        ne.* = .{
            .ref = .{ .id = e.ref.id, .type_name = try self.str(e.ref.type_name) },
            .state_fields = state,
            .handlers = try self.handlerDefs(e.handlers),
            .status = e.status,
            .mailbox = try self.mailbox(e.mailbox),
            .reductions = e.reductions,
        };
        return ne;
    }

    /// The instances something can still reach, in their original order.
    /// A worklist, not repeated passes: copying one actor's state can name
    /// another, and a chain of actors each holding the next (a Temper
    /// ListBuilder's nodes, say) would otherwise take a pass per link.
    fn reachableInstances(self: *Copier, old: []const *registry_mod.ActorEntry) CompactError!std.ArrayList(*registry_mod.ActorEntry) {
        var index = std.AutoHashMap(u64, usize).init(self.scratch);
        defer index.deinit();
        try index.ensureTotalCapacity(@intCast(old.len));
        for (old, 0..) |e, i| index.putAssumeCapacity(e.ref.id, i);

        // Work pending makes an actor a root of its own.
        for (old) |e| {
            if (e.mailbox.messages.items.len > 0 or (e.status != .idle and e.status != .dead)) try self.see(e.ref.id);
        }

        const copies = try self.scratch.alloc(?*registry_mod.ActorEntry, old.len);
        defer self.scratch.free(copies);
        @memset(copies, null);
        while (self.pending.pop()) |id| {
            const i = index.get(id) orelse continue; // a ref to an actor already gone
            if (copies[i] != null) continue;
            copies[i] = try self.entry(old[i]);
        }

        var out: std.ArrayList(*registry_mod.ActorEntry) = .{ .items = &.{}, .capacity = 0 };
        for (copies) |c| if (c) |ne| try out.append(self.to, ne);
        return out;
    }

    fn mailbox(self: *Copier, old: Mailbox) CompactError!Mailbox {
        var out = Mailbox.init();
        try out.messages.ensureTotalCapacity(self.to, old.messages.items.len);
        for (old.messages.items) |m| {
            // Nobody can be blocked on a reply between evals.
            out.messages.appendAssumeCapacity(.{ .name = try self.str(m.name), .args = try self.valueList(m.args), .reply_slot = null });
        }
        return out;
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;

fn run(code: std.mem.Allocator, eval: *Evaluator, source: []const u8) !*const Value {
    // The AST lives in `code`, which outlives every heap swap.
    var parser = Parser.init(code, source);
    const nodes = try parser.parseFile();
    var last: *const Value = undefined;
    for (nodes) |*node| last = try eval.eval(node);
    return last;
}

const program =
    \\actor Counter do
    \\  state count: Int :: 0
    \\  state log: List :: []
    \\  state tags: Map :: %{kind: :counter}
    \\  on :add(n: Int) do
    \\    become count: count + n, log: [n | log]
    \\    reply count + n
    \\  end
    \\  on :count do reply count end
    \\  on :log do reply log end
    \\  on :kind do reply lookup(tags, :kind) end
    \\  on :panel do reply stack(heading("counter"), text("n = #{count}"), button("more", :add)) end
    \\end
    \\def twice(f: Function, x: Int) -> Int do f(f(x)) end
    \\def inc(x: Int) -> Int do x + 1 end
    \\c = spawn Counter
    \\other = spawn Counter, count: 10
    \\shared = [1, 2, 3]
    \\pair = {shared, shared}
    \\greeting = "hello"
    \\c <- :add(5)
;

fn checkProgram(eval: *Evaluator, code: std.mem.Allocator) !void {
    try std.testing.expectEqual(@as(i64, 5), (try run(code, eval, "c <- :count")).integer);
    try std.testing.expectEqual(@as(i64, 10), (try run(code, eval, "other <- :count")).integer);
    try std.testing.expectEqual(@as(i64, 12), (try run(code, eval, "c <- :add(7)")).integer);
    try std.testing.expectEqual(@as(i64, 12), (try run(code, eval, "c <- :count")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try run(code, eval, "head(c <- :log)")).integer);
    try std.testing.expectEqual(@as(i64, 5), (try run(code, eval, "elem(c <- :log, 1)")).integer);
    try std.testing.expectEqualStrings("counter", (try run(code, eval, "c <- :kind")).atom);
    try std.testing.expectEqual(@as(i64, 3), (try run(code, eval, "twice(inc, 1)")).integer);
    try std.testing.expectEqual(@as(i64, 6), (try run(code, eval, "sum(shared)")).integer);
    try std.testing.expect((try run(code, eval, "pair")).eql((try run(code, eval, "{[1, 2, 3], [1, 2, 3]}")).*));
    try std.testing.expectEqualStrings("hello", (try run(code, eval, "greeting")).string);
    const panel = try run(code, eval, "c <- :panel");
    try std.testing.expect(panel.* == .view_node);
    try std.testing.expectEqual(@as(usize, 3), panel.view_node.children.len);
    // become after compaction still lands in the registry
    _ = try run(code, eval, "c <- :add(-12)");
    try std.testing.expectEqual(@as(i64, 0), (try run(code, eval, "c <- :count")).integer);
    _ = try run(code, eval, "c <- :add(5)");
}

test "compact keeps actors, closures, bindings and views alive after the old heap is freed" {
    // The handle table is process-global; nothing an earlier test left there
    // may be followed by this compaction.
    @import("handles.zig").dropAll();
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval, program);
    try checkProgram(&eval, code.allocator());

    try compact(&eval, &heap_a, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);

    try checkProgram(&eval, code.allocator());
}

test "compact can run after every eval, swapping heaps back and forth" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();
    var live: usize = 0;

    var eval = Evaluator.init(heaps[live].allocator());
    _ = try run(code.allocator(), &eval, program);

    var i: i64 = 0;
    while (i < 20) : (i += 1) {
        _ = try run(code.allocator(), &eval, "c <- :add(1)");
        const next = 1 - live;
        try compact(&eval, &heaps[live], heaps[next].allocator(), std.testing.allocator);
        _ = heaps[live].reset(.free_all);
        live = next;
        try std.testing.expectEqual(5 + i + 1, (try run(code.allocator(), &eval, "c <- :count")).integer);
    }
    try std.testing.expectEqual(@as(usize, 20 + 1), (try run(code.allocator(), &eval, "c <- :log")).list.len);
    try std.testing.expectEqual(@as(i64, 3), (try run(code.allocator(), &eval, "twice(inc, 1)")).integer);
}

test "compact preserves sharing between references to one value" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval, program);
    try compact(&eval, &heap_a, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);

    const pair = try run(code.allocator(), &eval, "pair");
    try std.testing.expect(pair.tuple[0] == pair.tuple[1]);
}

test "compact copies a full message log" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval, program);

    // Nothing reads the log in a REPL session, so it fills to its cap.
    while (eval.msg_log_count < Evaluator.msg_log_cap) {
        _ = try run(code.allocator(), &eval, "c <- :count");
    }

    try compact(&eval, &heap_a, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);

    try std.testing.expectEqual(@as(i64, 5), (try run(code.allocator(), &eval, "c <- :count")).integer);
}

test "an actor defined by blimp_eval survives compaction" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();
    var live: usize = 0;

    var eval = Evaluator.init(heaps[live].allocator());
    eval.code_allocator = code.allocator();
    _ = try run(code.allocator(), &eval,
        \\blimp_eval("actor Hot do\n  on :hi(who: String) do\n    reply concat(\"yo \", who)\n  end\nend")
        \\h = spawn Hot
    );

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const next = 1 - live;
        try compact(&eval, &heaps[live], heaps[next].allocator(), std.testing.allocator);
        // free_all hands the pages back; the testing allocator poisons them,
        // so a handler still pointing into the old heap reads garbage
        _ = heaps[live].reset(.free_all);
        live = next;
        try std.testing.expectEqualStrings("yo there", (try run(code.allocator(), &eval, "h <- :hi(\"there\")")).string);
    }
}

test "a top-level def sees the current definition of the defs it calls" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();

    var eval = Evaluator.init(heaps[0].allocator());
    eval.code_allocator = code.allocator();
    _ = try run(code.allocator(), &eval,
        \\def greet(who: String) -> String do concat("hello ", who) end
        \\def page(who: String) -> String do concat("<p>", greet(who), "</p>") end
        \\def loop(n: Int, acc: String) -> String do
        \\  case n do
        \\    0 -> acc
        \\    _ -> loop(n - 1, concat(acc, greet("x")))
        \\  end
        \\end
    );
    try std.testing.expectEqualStrings("<p>hello b</p>", (try run(code.allocator(), &eval, "page(\"b\")")).string);

    // redefined the way the control socket does it: another top-level def
    _ = try run(code.allocator(), &eval, "def greet(who: String) -> String do concat(\"howdy \", who) end");
    try compact(&eval, &heaps[0], heaps[1].allocator(), std.testing.allocator);
    _ = heaps[0].reset(.free_all);

    try std.testing.expectEqualStrings("<p>howdy b</p>", (try run(code.allocator(), &eval, "page(\"b\")")).string);
    // through a tail call, whose frame is collapsed
    try std.testing.expectEqualStrings("howdy xhowdy x", (try run(code.allocator(), &eval, "loop(2, \"\")")).string);
}

test "a def inside a function still keeps what it captured" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap.deinit();
    var eval = Evaluator.init(heap.allocator());
    _ = try run(code.allocator(), &eval,
        \\k = 1
        \\def make() -> Any do
        \\  k = 5
        \\  fn(x: Int) -> Int do x + k end
        \\end
        \\f = make()
        \\k = 100
    );
    try std.testing.expectEqual(@as(i64, 6), (try run(code.allocator(), &eval, "f(1)")).integer);
}

test "a fn literal sees the top level as it was when it was made, and globals defined later" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();

    var eval = Evaluator.init(heaps[0].allocator());
    eval.code_allocator = code.allocator();
    // A fn literal no longer copies the top level into its captures; it reads
    // the top level in place, as far as it went when the fn was made. These
    // are the answers the copy gave.
    _ = try run(code.allocator(), &eval,
        \\x = 1
        \\f = fn() -> Int do x end
        \\x = 2
        \\def g() -> Int do 10 end
        \\h = fn() -> Int do g() end
        \\def g() -> Int do 20 end
        \\k = fn() -> Int do later() end
        \\def later() -> Int do 99 end
        \\def outer() -> Any do fn() -> Int do later2() end end
        \\kk = outer()
        \\def later2() -> Int do 7 end
        \\def shadow_caller(cb: Fn) -> Int do
        \\  x = 100
        \\  cb()
        \\end
        \\def uses_x() -> Int do x end
    );
    for (0..2) |round| {
        // the snapshot: the x and the g there were when the fn was made
        try std.testing.expectEqual(@as(i64, 1), (try run(code.allocator(), &eval, "f()")).integer);
        try std.testing.expectEqual(@as(i64, 10), (try run(code.allocator(), &eval, "h()")).integer);
        // a name the top level did not have yet is found when it is called
        try std.testing.expectEqual(@as(i64, 99), (try run(code.allocator(), &eval, "k()")).integer);
        try std.testing.expectEqual(@as(i64, 7), (try run(code.allocator(), &eval, "kk()")).integer);
        // what the fn saw of the top level beats the caller's local of that name
        try std.testing.expectEqual(@as(i64, 1), (try run(code.allocator(), &eval, "shadow_caller(f)")).integer);
        // a top-level def reads the top level live: last definition wins
        try std.testing.expectEqual(@as(i64, 2), (try run(code.allocator(), &eval, "uses_x()")).integer);
        try std.testing.expectEqual(@as(i64, 20), (try run(code.allocator(), &eval, "g()")).integer);
        if (round == 0) {
            // and all of it survives compaction, which rebuilds the index
            try compact(&eval, &heaps[0], heaps[1].allocator(), std.testing.allocator);
            _ = heaps[0].reset(.free_all);
        }
    }
}

test "a fn literal tail-calling another keeps seeing what it saw of the top level" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap.deinit();
    var eval = Evaluator.init(heap.allocator());
    eval.code_allocator = code.allocator();
    // `b` is made before `w` exists, `a` while it is 5, and `a` tail-calls
    // `b`, handing it the frame. `b` has no `w` of its own, so it reads the
    // `w` that `a` saw -- which used to sit in the frame as one of `a`'s
    // copied captures, and is now `a`'s mark (Scope.left_mark). Without it
    // `b` falls through to the live top level and answers 51.
    _ = try run(code.allocator(), &eval,
        \\b = fn(n: Int) -> Int do n + w end
        \\w = 5
        \\a = fn(n: Int) -> Int do b(n) end
        \\w = 50
    );
    try std.testing.expectEqual(@as(i64, 6), (try run(code.allocator(), &eval, "a(1)")).integer);
    try std.testing.expectEqual(@as(i64, 51), (try run(code.allocator(), &eval, "b(1)")).integer);
}

test "redefining an actor updates its running instances and keeps their state" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();

    var eval = Evaluator.init(heaps[0].allocator());
    eval.code_allocator = code.allocator();
    _ = try run(code.allocator(), &eval,
        \\actor Tally do
        \\  state n: Int :: 0
        \\  state old: String :: "gone soon"
        \\  on :add(k: Int) do
        \\    become n: n + k
        \\    reply n + k
        \\  end
        \\  on :show do reply "n=#{n}" end
        \\end
        \\t = spawn Tally
        \\t <- :add(5)
        \\t <- :add(2)
    );
    try std.testing.expectEqualStrings("n=7", (try run(code.allocator(), &eval, "t <- :show")).string);

    _ = try run(code.allocator(), &eval,
        \\actor Tally do
        \\  state n: Int :: 0
        \\  state label: String :: "total"
        \\  on :add(k: Int) do
        \\    become n: n + k * 10
        \\    reply n + k * 10
        \\  end
        \\  on :show do reply "#{label}: #{n}" end
        \\end
    );
    try compact(&eval, &heaps[0], heaps[1].allocator(), std.testing.allocator);
    _ = heaps[0].reset(.free_all);

    // the running instance: new handlers, its n kept, the new field defaulted
    try std.testing.expectEqualStrings("total: 7", (try run(code.allocator(), &eval, "t <- :show")).string);
    try std.testing.expectEqual(@as(i64, 17), (try run(code.allocator(), &eval, "t <- :add(1)")).integer);
    // a new instance gets the new definition too
    try std.testing.expectEqualStrings("total: 0", (try run(code.allocator(), &eval, "u = spawn Tally\nu <- :show")).string);
}

test "drop_unreachable keeps every actor a value can name, and only those" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval,
        \\actor Box do
        \\  state held: Any :: nil
        \\  state n: Int :: 0
        \\  on :hold(x: Any) do become held: x end
        \\  on :held do reply held end
        \\  on :bump do become n: n + 1 end
        \\  on :n do reply n end
        \\end
        \\def scratch(i: Int) -> Int do
        \\  b = spawn Box
        \\  b <- :bump
        \\  b <- :n
        \\end
        \\def many(i: Int) -> Int do
        \\  case i >= 50 do
        \\    true -> i
        \\    false ->
        \\      scratch(i)
        \\      many(i + 1)
        \\  end
        \\end
        \\bound = spawn Box
        \\outer = spawn Box
        \\inner = spawn Box
        \\outer <- :hold(inner)
        \\inner = nil
        \\chain = spawn Box
        \\c2 = spawn Box
        \\c3 = spawn Box
        \\c2 <- :hold(%{next: [c3]})
        \\chain <- :hold({c2})
        \\c2 = nil
        \\c3 = nil
        \\in_closure = fn() do spawn Box end
        \\kept_by_fn = spawn Box
        \\f = fn() do kept_by_fn end
        \\kept_by_fn = nil
        \\many(0)
    );
    // 7 kept (bound, outer, the one outer holds, chain, c2, c3, kept_by_fn)
    // plus 50 that scratch/1 spawned and let go.
    try std.testing.expectEqual(@as(usize, 57), eval.registry.instances.items.len);

    const dropped = try compactWith(&eval, &heap_a, heap_b.allocator(), std.testing.allocator, .drop_unreachable);
    _ = heap_a.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 50), dropped);
    try std.testing.expectEqual(@as(usize, 7), eval.registry.instances.items.len);

    // What was kept still works, including what is reachable only through
    // another actor's state, a tuple, a map inside a list, or a closure.
    _ = try run(code.allocator(), &eval, "(outer <- :held) <- :bump");
    try std.testing.expectEqual(@as(i64, 1), (try run(code.allocator(), &eval, "(outer <- :held) <- :n")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try run(code.allocator(), &eval, "(head(lookup(elem(chain <- :held, 0) <- :held, :next))) <- :n")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try run(code.allocator(), &eval, "f() <- :n")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try run(code.allocator(), &eval, "bound <- :n")).integer);
}

test "keep_all still keeps every actor" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval,
        \\actor Box do
        \\  state n: Int :: 0
        \\end
        \\def one(i: Int) -> Int do
        \\  b = spawn Box
        \\  i
        \\end
        \\one(1)
        \\one(2)
    );
    try std.testing.expectEqual(@as(usize, 0), try compactWith(&eval, &heap_a, heap_b.allocator(), std.testing.allocator, .keep_all));
    _ = heap_a.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 2), eval.registry.instances.items.len);
}

test "a literal built once by the parser survives compaction, bound and re-evaluated" {
    @import("handles.zig").dropAll();
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var parser = Parser.init(code.allocator(),
        \\s = "a\tb"
        \\n = 5000
        \\f = 2.5
        \\k = :ok
        \\t = "n=#{n}!"
        \\[s, n, f, k, t]
    );
    const nodes = try parser.parseFile();
    // The parser built the value once; every evaluation returns that pointer.
    const lit = nodes[0].kind.assign_stmt.value.kind.string_lit;
    try std.testing.expect(lit.prebuilt != null);

    var eval = Evaluator.init(heap_a.allocator());
    var last: *const Value = undefined;
    for (nodes) |*node| last = try eval.eval(node);
    try std.testing.expect(last.list[0] == lit.prebuilt.?);

    try compact(&eval, &heap_a, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);

    // The bindings hold copies; the AST's own values were never in heap_a.
    try std.testing.expectEqualStrings("a\tb", (try run(code.allocator(), &eval, "s")).string);
    try std.testing.expectEqual(@as(i64, 5000), (try run(code.allocator(), &eval, "n")).integer);
    try std.testing.expectEqualStrings("n=5000!", (try run(code.allocator(), &eval, "t")).string);

    // Evaluate the same nodes again after the swap.
    for (nodes) |*node| last = try eval.eval(node);
    try std.testing.expectEqualStrings("a\tb", last.list[0].string);
    try std.testing.expectEqual(@as(i64, 5000), last.list[1].integer);
    try std.testing.expectEqual(@as(f64, 2.5), last.list[2].float);
    try std.testing.expectEqualStrings("ok", last.list[3].atom);
    try std.testing.expectEqualStrings("n=5000!", last.list[4].string);

    // A second compaction copies the shared prebuilt values by value.
    try compact(&eval, &heap_b, heap_a.allocator(), std.testing.allocator);
    _ = heap_b.reset(.free_all);
    try std.testing.expectEqualStrings("a\tb", (try run(code.allocator(), &eval, "s")).string);
}

test "a call site cached before compaction is not used after it" {
    @import("handles.zig").dropAll();
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    // `caller` holds the site; it lives in `code`, so it survives the swap,
    // and the site's cached value points into heap_a.
    _ = try run(code.allocator(), &eval,
        \\def name() do "marginalia" end
        \\def caller() do name() + "!" end
    );
    try std.testing.expectEqualStrings("marginalia!", (try run(code.allocator(), &eval, "caller()")).string);
    try std.testing.expectEqualStrings("marginalia!", (try run(code.allocator(), &eval, "caller()")).string);

    try compact(&eval, &heap_a, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);

    // Were the cache trusted now it would read freed memory.
    try std.testing.expectEqualStrings("marginalia!", (try run(code.allocator(), &eval, "caller()")).string);
    try std.testing.expectEqualStrings("marginalia!", (try run(code.allocator(), &eval, "caller()")).string);
}

test "the old heap's chunks are found, and nothing outside them" {
    // arenaRanges reads ArenaAllocator's private node list; a std upgrade
    // that changes it must fail here, not corrupt a heap.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ptrs: [2000]*Value = undefined;
    for (&ptrs, 0..) |*p, i| {
        p.* = try arena.allocator().create(Value);
        p.*.* = .{ .integer = @intCast(i) };
        // big allocations in between force several chunks
        if (i % 100 == 0) _ = try arena.allocator().alloc(u8, 10_000 + i * 50);
    }
    var fwd = try Forwarding.init(std.testing.allocator, &arena, .{});
    defer fwd.deinit(std.testing.allocator);
    try std.testing.expect(fwd.ranges.len > 1);
    for (ptrs) |p| {
        const s = fwd.slot(p) orelse return error.TestUnexpectedResult;
        // every value has its own slot, and all start empty
        try std.testing.expect(s.* == null);
        s.* = p;
    }
    var outside: Value = .nil;
    try std.testing.expect(fwd.slot(&outside) == null);
    try std.testing.expect(fwd.slot(value_mod.interned.boolean(true)) == null);
}

test "compaction keeps interned names interned and the small-integer table shared" {
    @import("handles.zig").dropAll();
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval,
        \\counter_name = 7
        \\m = %{counter_name: 7}
    );
    try compact(&eval, &heap_a, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);
    try compact(&eval, &heap_b, heap_a.allocator(), std.testing.allocator);
    _ = heap_b.reset(.free_all);

    const interned = name_key.intern("counter_name");
    var found = false;
    for (eval.env.scopes.items[0].bindings.items) |b| {
        if (std.mem.eql(u8, b.name, "counter_name")) {
            try std.testing.expect(b.name.ptr == interned.ptr);
            try std.testing.expect(b.val == value_mod.interned.intPtr(7).?);
            found = true;
        }
    }
    try std.testing.expect(found);
    const m = try run(code.allocator(), &eval, "m");
    try std.testing.expect(m.map[0].key.ptr == interned.ptr);
    try std.testing.expectEqual(@as(i64, 7), (try run(code.allocator(), &eval, "counter_name")).integer);
}

test "without the old arena every value goes through the map, and still survives" {
    @import("handles.zig").dropAll();
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval, program);
    try compact(&eval, null, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);
    try checkProgram(&eval, code.allocator());
    const pair = try run(code.allocator(), &eval, "pair");
    try std.testing.expect(pair.tuple[0] == pair.tuple[1]);
}

// ── Old space (Plan.promote_into / Plan.keep) ────────────────

fn regionHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

fn inRegion(region: []const u8, p: anytype) bool {
    return Region.of(region).has(@intFromPtr(p));
}

test "a binding and an actor's state rebound after promotion survive compaction" {
    @import("handles.zig").dropAll();
    const ta = std.testing.allocator;
    var code = std.heap.ArenaAllocator.init(ta);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{ std.heap.ArenaAllocator.init(ta), std.heap.ArenaAllocator.init(ta) };
    defer heaps[0].deinit();
    defer heaps[1].deinit();
    var live: usize = 0;

    var eval = Evaluator.init(heaps[live].allocator());
    eval.code_allocator = code.allocator();
    _ = try run(code.allocator(), &eval, program);
    // `held` is an actor only a list names; once that list is old, nothing
    // the copier walks names it.
    _ = try run(code.allocator(), &eval, "held = [spawn Counter, count: 40]\nbig = \"#{range(1, 2000)}\"");

    const region = try ta.alignedAlloc(u8, .@"16", 1 << 20);
    defer ta.free(region);
    @memset(region, 0);
    const p = try compactPlan(&eval, .{
        .from = &heaps[live],
        .to = heaps[1 - live].allocator(),
        .scratch = ta,
        .actors = .drop_unreachable,
        .promote_into = region,
    });
    defer ta.free(p.old_refs);
    _ = heaps[live].reset(.free_all);
    live = 1 - live;
    try std.testing.expect(p.promoted > 0);

    // What boot made is in the region now.
    const shared_before = try run(code.allocator(), &eval, "shared");
    try std.testing.expect(inRegion(region, shared_before));
    try std.testing.expect(inRegion(region, (try run(code.allocator(), &eval, "big")).string.ptr));
    const sum = regionHash(region[0..p.promoted]);

    // Rebind after promotion: a top-level name to a value made now, a new
    // top-level name, actor state through `become` (in place, on the
    // entry), and a fresh actor. Every one of these is young, and the only
    // thing pointing at it is something mutable.
    _ = try run(code.allocator(), &eval,
        \\greeting = concat("hel", "lo again")
        \\fresh = [greeting, shared, concat("n", "ew")]
        \\late = spawn Counter, count: 3
        \\late <- :add(4)
        \\c <- :add(100)
        \\other <- :add(1)
        \\wrapped = fn(x: Int) -> Int do twice(inc, x) + length(fresh) end
    );

    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const dropped = (try compactPlan(&eval, .{
            .from = &heaps[live],
            .to = heaps[1 - live].allocator(),
            .scratch = ta,
            .actors = .drop_unreachable,
            .keep = Region.of(region),
            .keep_refs = p.old_refs,
        })).dropped;
        // The testing allocator poisons what reset hands back, so anything
        // still pointing into the young heap just left reads garbage.
        _ = heaps[live].reset(.free_all);
        live = 1 - live;
        try std.testing.expectEqual(@as(usize, 0), dropped);

        try std.testing.expectEqualStrings("hello again", (try run(code.allocator(), &eval, "greeting")).string);
        const fresh = try run(code.allocator(), &eval, "fresh");
        try std.testing.expectEqual(@as(usize, 3), fresh.list.len);
        try std.testing.expectEqualStrings("new", fresh.list[2].string);
        // the old value it holds was kept where it was, not copied
        try std.testing.expect(fresh.list[1] == shared_before);
        try std.testing.expect((try run(code.allocator(), &eval, "shared")) == shared_before);
        try std.testing.expectEqual(@as(i64, 7), (try run(code.allocator(), &eval, "late <- :count")).integer);
        try std.testing.expectEqual(@as(i64, 105 + @as(i64, @intCast(round))), (try run(code.allocator(), &eval, "c <- :count")).integer);
        try std.testing.expectEqual(@as(i64, if (round == 0) 100 else 1), (try run(code.allocator(), &eval, "head(c <- :log)")).integer);
        try std.testing.expectEqual(@as(i64, 11), (try run(code.allocator(), &eval, "other <- :count")).integer);
        try std.testing.expectEqual(@as(i64, 6), (try run(code.allocator(), &eval, "wrapped(1)")).integer);
        // only an old list names this actor
        try std.testing.expectEqual(@as(i64, 40), (try run(code.allocator(), &eval, "head(held) <- :count")).integer);
        try std.testing.expect((try run(code.allocator(), &eval, "big")).string.len > 5000);
        try checkProgramAfterPromotion(&eval, code.allocator());
        _ = try run(code.allocator(), &eval, "c <- :add(1)");
        // Nothing wrote into the old space: not `become`, not a rebinding,
        // not a compaction.
        try std.testing.expectEqual(sum, regionHash(region[0..p.promoted]));
    }
}

fn checkProgramAfterPromotion(eval: *Evaluator, code: std.mem.Allocator) !void {
    try std.testing.expectEqualStrings("counter", (try run(code, eval, "c <- :kind")).atom);
    try std.testing.expectEqual(@as(i64, 3), (try run(code, eval, "twice(inc, 1)")).integer);
    try std.testing.expect((try run(code, eval, "pair")).eql((try run(code, eval, "{[1, 2, 3], [1, 2, 3]}")).*));
    const panel = try run(code, eval, "c <- :panel");
    try std.testing.expectEqual(@as(usize, 3), panel.view_node.children.len);
}

test "a promotion that does not fit its region changes nothing" {
    @import("handles.zig").dropAll();
    const ta = std.testing.allocator;
    var code = std.heap.ArenaAllocator.init(ta);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(ta);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(ta);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval, program);
    const region = try ta.alignedAlloc(u8, .@"16", 256);
    defer ta.free(region);
    try std.testing.expectError(error.OutOfMemory, compactPlan(&eval, .{
        .from = &heap_a,
        .to = heap_b.allocator(),
        .scratch = ta,
        .promote_into = region,
    }));
    // still on heap_a, and working
    try checkProgram(&eval, code.allocator());
}

test "re-promotion folds the previous old space in, and it can be freed" {
    @import("handles.zig").dropAll();
    const ta = std.testing.allocator;
    var code = std.heap.ArenaAllocator.init(ta);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{ std.heap.ArenaAllocator.init(ta), std.heap.ArenaAllocator.init(ta) };
    defer heaps[0].deinit();
    defer heaps[1].deinit();

    var eval = Evaluator.init(heaps[0].allocator());
    eval.code_allocator = code.allocator();
    _ = try run(code.allocator(), &eval, program);
    _ = try run(code.allocator(), &eval, "held = [spawn Counter, count: 40]");

    const first = try ta.alignedAlloc(u8, .@"16", 1 << 20);
    const p1 = try compactPlan(&eval, .{ .from = &heaps[0], .to = heaps[1].allocator(), .scratch = ta, .actors = .drop_unreachable, .promote_into = first });
    defer ta.free(p1.old_refs);
    _ = heaps[0].reset(.free_all);

    _ = try run(code.allocator(), &eval, "young = concat(\"made \", \"later\")\nc <- :add(2)");

    const second = try ta.alignedAlloc(u8, .@"16", 1 << 20);
    defer ta.free(second);
    const p2 = try compactPlan(&eval, .{ .from = &heaps[1], .to = heaps[0].allocator(), .scratch = ta, .actors = .drop_unreachable, .promote_into = second, .also_from = Region.of(first) });
    defer ta.free(p2.old_refs);
    _ = heaps[1].reset(.free_all);
    // the previous old space is gone; poison it to be sure nothing reads it
    @memset(first, 0xaa);
    ta.free(first);

    try std.testing.expect(inRegion(second, try run(code.allocator(), &eval, "shared")));
    try std.testing.expect(inRegion(second, try run(code.allocator(), &eval, "young")));
    try std.testing.expectEqualStrings("made later", (try run(code.allocator(), &eval, "young")).string);
    try std.testing.expectEqual(@as(i64, 7), (try run(code.allocator(), &eval, "c <- :count")).integer);
    try std.testing.expectEqual(@as(i64, 40), (try run(code.allocator(), &eval, "head(held) <- :count")).integer);
    try checkProgramAfterPromotion(&eval, code.allocator());
}

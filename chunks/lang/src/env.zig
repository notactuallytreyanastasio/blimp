const std = @import("std");
const Value = @import("value.zig").Value;
const name_key = @import("name_key.zig");

/// Variable environment with lexical scope support.
/// Uses a stack of scopes, each mapping variable names to values.
/// Follows the same pattern as TypeEnv in types.zig.
/// A name and its `hashName`, the key of `Environment.globals`.
pub const GlobalKey = struct { name: []const u8, hash: u32 };

pub const GlobalCtx = struct {
    pub fn hash(_: GlobalCtx, k: GlobalKey) u64 {
        // The map takes the index from the low bits and a fingerprint from
        // the high ones; FNV is good in the low bits only.
        return @as(u64, k.hash) *% 0x9E3779B97F4A7C15;
    }
    pub fn eql(_: GlobalCtx, a: GlobalKey, b: GlobalKey) bool {
        return name_key.sameName(a.name, a.hash, b.name, b.hash);
    }
};

pub const Environment = struct {
    scopes: std.ArrayList(Scope),
    /// Binding lists left behind by popped scopes, kept for the next push.
    /// Every call pushes a scope and pops it again, and the evaluator runs on
    /// an arena that frees nothing, so without this list a call leaves its
    /// binding buffer in the allocator for the rest of the run.
    free_scopes: std.ArrayList(std.ArrayList(Binding)),
    allocator: std.mem.Allocator,
    /// The top-level scope by name: each name to the index of its latest
    /// binding in `scopes[0].bindings`.
    ///
    /// The top-level scope is where a program's every `def` lives, so it is
    /// the one scope that is large -- several thousand names once the site
    /// carries the Temper library -- and it is the scope every call of a
    /// global function resolves in. Scanning it from the end made a call
    /// cost time in proportion to how many definitions came after the one
    /// being called: 200k calls of a function followed by 3000 other defs
    /// took 1408ms, against 35ms with none. The name mask does not help
    /// there, because 3000 names set all 64 of its bits.
    ///
    /// Keyed by the name and its FNV hash (`name_key.hashName`), which the
    /// parser computed once per node and every Binding carries: a lookup
    /// from a node did not need `Wyhash` over the name's bytes on top of it
    /// (`hash.wyhash` was 3 percent of a Markdown run).  A name made at run
    /// time is hashed by the caller, once.
    globals: std.HashMapUnmanaged(GlobalKey, u32, GlobalCtx, 80) = .{},
    /// Bumped whenever a top-level binding is added or the index is
    /// rebuilt.  A call site that cached "this name is a builtin" checks it:
    /// a later top-level `def` of that name must win.
    globals_version: u32 = 1,
    /// For each binding in the top-level scope, the index of the binding of
    /// the same name before it, or `no_prev`. The top-level scope is
    /// append-only -- redefining a name adds a binding rather than
    /// overwriting one -- so a closure can see the top level as it was when
    /// the closure was made (Closure.globals_mark) by walking this chain.
    global_prev: std.ArrayList(u32) = .{ .items = &.{}, .capacity = 0 },
    /// Every name this environment has ever bound in a scope other than the
    /// top level, or lent to one as a capture or as actor state: one bit per
    /// value of the top 16 bits of `hashName`, set before the binding exists
    /// and never cleared.  A clear bit is certain: no frame now on the stack
    /// can hold the name.
    ///
    /// `bindsLocally` asks the same question of a 64-bit mask, and on a
    /// program the size of the site every bit of that mask is set somewhere
    /// on the stack: on rendering the posts, `builtinHit` fell through to
    /// `unbound` -- a walk of every frame and a probe of `globals` -- for most
    /// builtin calls.  A builtin's name is almost never a local's, so here it
    /// almost never shares a bit with one.
    ever_local: [1024]u64 = [_]u64{0} ** 1024,

    pub const no_prev: u32 = std.math.maxInt(u32);
    /// A `globals_mark` that reads the top-level scope as it is now.
    pub const live: u32 = std.math.maxInt(u32);

    pub const Binding = struct {
        name: []const u8,
        val: *const Value,
        /// `hashName(name)`.  A lookup or a redefinition compares this
        /// before the bytes.  Names a compiler generates are the same
        /// length and share a prefix (`best__2115`, `from__2111`,
        /// `blimp_branch_764`, `blimp_signal_765`), so `std.mem.eql`'s
        /// length check never ruled one out and every candidate in a scope
        /// cost a byte compare: `mem.eqlBytes` was the top frame of a
        /// native profile of a translated Temper program.
        hash: u32,
    };

    pub const Scope = struct {
        bindings: std.ArrayList(Binding),
        /// What a closure captured, borrowed from the closure rather than
        /// copied into `bindings`.
        ///
        /// Copying them in cost a `defineIn` each, and `defineIn` scans the
        /// scope for an existing name, so installing a closure's captures was
        /// quadratic in how many there were. Every translated Temper program
        /// carries the ~400-definition prelude, every one of those definitions
        /// captures every other, and so every call bound 400 names at a cost
        /// of 80,000 string comparisons. A bare 1600-iteration loop took 1ms
        /// on its own and 2409ms with the prelude in the file.
        ///
        /// Borrowing is safe because the closure outlives the call -- it is
        /// the callee -- and `gc.compact` runs only between REPL evaluations,
        /// when the only scope is the global one and it has no captures.
        captured: []const Value.CapturedBinding = &.{},
        /// The `names` mask for [captured], computed once when the closure was
        /// built rather than per call.
        captured_names: u64 = 0,
        /// Which closure this frame was last lent to (its address), so a
        /// tail-recursive call can be told from a call to another closure.
        /// It used to be told by the captured slice's address, but every
        /// top-level def now captures the same empty slice.
        lent_to: usize = 0,
        /// How much of the top-level scope the current callee sees, read
        /// right after its captures and before anything an earlier callee
        /// left in the frame. 0 is none.
        ///
        /// A top-level def (Closure.top_level) reads the top-level scope as
        /// it is now (`live`). Any other closure reads it as it was when the
        /// closure was made: the bindings below its Closure.globals_mark.
        /// That is exactly the snapshot it used to copy into its captures,
        /// without the copy -- and the copy was every top-level name, so a
        /// `fn(z) do z + 1 end` with 3000 defs in the file cost 410KB and
        /// 77us to make.
        globals_mark: u32 = 0,
        /// The globals_mark of callees that ran earlier in this frame (a tail
        /// call hands the frame on), read after everything they left behind.
        /// Their captures are folded into `bindings`; their view of the top
        /// level is kept as this mark instead of as thousands of bindings.
        left_mark: u32 = 0,
        /// Where the current callee's own bindings start.
        ///
        /// A tail call reuses its frame, so `bindings` below this index belong
        /// to a callee that has already returned. Those are the caller's
        /// locals, which a Blimp closure can see -- but they must not shadow
        /// the *current* callee's captures, which is what copying the captures
        /// in used to prevent: `defineIn` overwrote the stale entry.
        ///
        /// Dropping that gave the regex matcher a continuation from the wrong
        /// frame. `temper_rx_seq_at` ran off the end of its node list and kept
        /// going, because the `k` it called was a stale `k` rather than the
        /// one it had captured:
        ///
        ///     seq_at idx=2 pos=2 n=2
        ///     seq_at idx=3 pos=2 n=2
        ///     seq_at idx=4 pos=2 n=2
        own_base: usize = 0,
        /// One bit per name in this scope, by hash, maintained by `defineIn`.
        /// A lookup whose bit is clear skips the scope without comparing a
        /// single string.
        ///
        /// This is not a micro-optimisation.  A Blimp closure sees its
        /// caller's locals, so resolving a global from N frames deep walks
        /// all N scopes, and a recursion N deep does that N times: finding
        /// `fib` was a quarter of the time in fib(35).  A false positive
        /// costs a search that would have happened anyway; there are no
        /// false negatives, so what the walk finds does not change.
        names: u64 = 0,
        /// The OR of `names | captured_names` over this scope and every
        /// scope below it except the top level: what `bindsLocally` used to
        /// walk the whole stack to compute, on every builtin call (19 frames
        /// on average on the Markdown bench).  A scope takes its parent's
        /// value when it is pushed, and only the innermost scope's masks
        /// change after that (`collapseTo` changes `base`'s, and pops what
        /// was above it before anything reads), so every write to a mask
        /// below adds the same bits here.  Conservative like the masks it is
        /// made of: a set bit is a maybe.
        stack_names: u64 = 0,
    };

    /// The bit this name claims in a scope's `names`.  Public because anything
    /// that builds a Scope without going through `define` has to rebuild the
    /// mask itself — gc.zig does, and the gc tests fail loudly if it stops.  Two loads and three
    /// arithmetic ops: a real hash costs more than the string comparisons it
    /// saves, because most lookups hit the innermost scope on the first try.
    /// FNV-1a over the name's bytes.  Cheap enough to compute per lookup:
    /// a scope with a dozen same-length candidates cost a dozen
    /// `eqlBytes` calls, and one of these costs about one.
    pub const hashName = name_key.hashName;
    pub const nameBit = name_key.nameBit;
    pub const internName = name_key.intern;

    pub fn init(allocator: std.mem.Allocator) Environment {
        var env = Environment{
            .scopes = .{ .items = &.{}, .capacity = 0 },
            .free_scopes = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
        // Push the global scope
        env.pushScope();
        return env;
    }

    /// Record that `hash` names something bound below the top level.
    inline fn markLocal(self: *Environment, hash: u32) void {
        self.ever_local[hash >> 22] |= @as(u64, 1) << @as(u6, @truncate(hash >> 16));
    }

    /// False only if no scope but the top level has ever bound, captured or
    /// been lent a name with this `hashName`, so none on the stack holds it.
    pub inline fn everLocal(self: *const Environment, hash: u32) bool {
        return self.ever_local[hash >> 22] & (@as(u64, 1) << @as(u6, @truncate(hash >> 16))) != 0;
    }

    /// Push a new scope (entering a block), reusing a recycled binding list
    /// when one is going spare.
    pub fn pushScope(self: *Environment) void {
        const bindings = self.free_scopes.pop() orelse
            std.ArrayList(Binding){ .items = &.{}, .capacity = 0 };
        const outer: u64 = if (self.scopes.items.len >= 1) self.scopes.items[self.scopes.items.len - 1].stack_names else 0;
        self.scopes.append(self.allocator, .{ .bindings = bindings, .stack_names = outer }) catch {};
    }

    /// Lend the current scope a closure's captured bindings.
    ///
    /// They are visible to lookup but are not in `bindings`, so a parameter or
    /// a local defined afterwards shadows a capture of the same name, which is
    /// the order `define` gave before.
    pub fn lendCaptured(self: *Environment, captured: []const Value.CapturedBinding, names: u64, closure_id: usize, globals_mark: u32) void {
        if (self.scopes.items.len == 0) return;
        const index = self.scopes.items.len - 1;
        const existing = self.scopes.items[index].captured;
        const outgoing_mark = self.scopes.items[index].globals_mark;
        self.scopes.items[index].globals_mark = globals_mark;
        // A tail call reuses the frame, so the scope may already have been
        // lent the previous callee's captures. A Blimp closure sees its
        // caller's frame, so those cannot simply be dropped: they are folded
        // into the scope's own bindings first, where a name the scope already
        // binds wins. Self-recursion lends the same slice every time and skips
        // all of this.
        if (self.scopes.items[index].lent_to == closure_id) {
            // The same closure re-entering its own frame, which is what every
            // tail-recursive loop does. Its previous parameters and locals are
            // about to be replaced, so the region is reused rather than a
            // second copy appended -- otherwise a loop grows its frame once
            // per iteration, which `memory_test` measures and rejects.
            const scope = &self.scopes.items[index];
            // Not shrinkRetainingCapacity, which fills what it drops (see
            // `recycle`); every iteration of a tail-recursive loop comes here.
            std.debug.assert(scope.own_base <= scope.bindings.items.len);
            scope.bindings.items.len = scope.own_base;
            return;
        }
        // A different callee taking over the frame. Its view of the top level
        // stays visible below what it leaves, as its captured snapshot of the
        // top level used to. A live view is not kept: a top-level def's frame
        // never folded the top level into what it left, and keeping it would
        // put the top level ahead of the caller's frames.
        if (outgoing_mark != live and outgoing_mark > self.scopes.items[index].left_mark) {
            self.scopes.items[index].left_mark = outgoing_mark;
        }
        if (existing.len != 0) {
            // A different callee taking over the frame. What the last one
            // captured becomes part of what it leaves behind, since a Blimp
            // closure can see the frame it was called from. Dropping these
            // gets a continuation from the wrong closure, which the regex
            // engine reports as
            //
            //     Handler :fn expects 4 argument(s), got 2.
            //
            // Only the outgoing callee's *own* region is checked for a name
            // that would shadow one of these: names within `existing` are
            // unique, and anything below that region is older still, so a
            // capture appended here is right to win over it. Checking all of
            // `bindings` made this quadratic, which is the cost the rest of
            // this commit is about removing.
            const own_len = self.scopes.items[index].bindings.items.len;
            const own_base = self.scopes.items[index].own_base;
            outer: for (existing) |b| {
                for (self.scopes.items[index].bindings.items[own_base..own_len]) |binding| {
                    if (name_key.sameName(binding.name, binding.hash, b.name, b.hash)) continue :outer;
                }
                const sc = &self.scopes.items[index];
                sc.names |= nameBit(b.name);
                if (index != 0) sc.stack_names |= nameBit(b.name);
                sc.bindings.append(self.allocator, .{ .name = b.name, .val = b.val, .hash = b.hash }) catch {};
            }
        }
        // A closure may come from another environment (a message carries
        // it), so what it captured is marked here, where it is lent, not
        // where it was made.  Self-recursion returned above; a top-level
        // def lends an empty slice.
        if (index != 0) for (captured) |b| self.markLocal(b.hash);
        const scope = &self.scopes.items[index];
        scope.captured = captured;
        scope.captured_names = names;
        if (index != 0) scope.stack_names |= names;
        scope.lent_to = closure_id;
        // Everything already in the frame belongs to whoever ran here before.
        scope.own_base = scope.bindings.items.len;
    }

    /// Lend the current scope an actor's state fields as its captured tier.
    /// The scope is a fresh handler scope: nothing was lent to it before.
    pub fn lendState(self: *Environment, items: []const Value.CapturedBinding, names: u64) void {
        if (self.scopes.items.len == 0) return;
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        if (self.scopes.items.len > 1) for (items) |b| self.markLocal(b.hash);
        scope.captured = items;
        scope.captured_names = names;
        if (self.scopes.items.len > 1) scope.stack_names |= names;
    }

    /// The current top-level binding of `name`, the latest if it was defined
    /// more than once.
    pub fn lookupTop(self: *const Environment, name: []const u8) ?*const Value {
        return self.lookupTopAt(name, live);
    }

    /// The top-level binding of `name` among the first `mark` top-level
    /// bindings: what a closure made when there were `mark` of them saw.
    pub fn lookupTopAt(self: *const Environment, name: []const u8, mark: u32) ?*const Value {
        if (self.scopes.items.len == 0) return null;
        return self.topFrom(self.globals.get(.{ .name = name, .hash = name_key.hashName(name) }), mark);
    }

    /// The top-level binding at or before `mark`, walking the `global_prev`
    /// chain down from `start`, the latest binding of the name (null when
    /// the name has none).
    fn topFrom(self: *const Environment, start: ?u32, mark: u32) ?*const Value {
        var idx = start orelse return null;
        while (idx >= mark) {
            idx = self.global_prev.items[idx];
            if (idx == no_prev) return null;
        }
        return self.scopes.items[0].bindings.items[idx].val;
    }

    /// How many top-level bindings there are now: the mark for a closure
    /// being made, which sees these and no later ones.
    pub fn globalsMark(self: *const Environment) u32 {
        if (self.scopes.items.len == 0) return 0;
        return @intCast(self.scopes.items[0].bindings.items.len);
    }

    /// Rebuild `globals` and `global_prev` from the top-level scope, for
    /// anything that replaces `scopes` wholesale (gc.compact).
    pub fn reindexGlobals(self: *Environment) void {
        self.globals = .{};
        self.global_prev = .{ .items = &.{}, .capacity = 0 };
        self.globals_version +%= 1;
        if (self.scopes.items.len == 0) return;
        for (self.scopes.items[0].bindings.items, 0..) |b, i| {
            self.indexGlobal(b.name, b.hash, @intCast(i));
        }
    }

    fn indexGlobal(self: *Environment, name: []const u8, hash: u32, index: u32) void {
        self.globals_version +%= 1;
        const got = self.globals.getOrPut(self.allocator, .{ .name = name, .hash = hash }) catch {
            @panic("out of memory indexing a top-level binding");
        };
        const prev: u32 = if (got.found_existing) got.value_ptr.* else no_prev;
        got.value_ptr.* = index;
        self.global_prev.append(self.allocator, prev) catch {
            @panic("out of memory indexing a top-level binding");
        };
    }

    /// Pop the current scope (leaving a block).
    pub fn popScope(self: *Environment) void {
        if (self.scopes.pop()) |scope| self.recycle(scope);
    }

    /// Keep a popped scope's binding buffer for the next push.  Dropping it
    /// instead is what made a deep recursion grow without bound.
    fn recycle(self: *Environment, scope: Scope) void {
        // `names` belongs to the scope, not to the buffer being kept.
        // The length is set directly: `clearRetainingCapacity` fills the
        // dropped bindings with 0xAA in a safe build, and ReleaseSafe is what
        // ships, so every return from a call paid a memset of its frame.
        var bindings = scope.bindings;
        bindings.items.len = 0;
        self.free_scopes.append(self.allocator, bindings) catch {};
    }

    /// Number of scopes on the stack. Callers record this to pop back to it.
    pub fn depth(self: *const Environment) usize {
        return self.scopes.items.len;
    }

    /// Pop scopes until only `n` remain (no-op if already at or below n).
    pub fn popTo(self: *Environment, n: usize) void {
        while (self.scopes.items.len > n) {
            if (self.scopes.pop()) |scope| self.recycle(scope);
        }
    }

    /// Merge every scope above index `base` into scopes[base], inner bindings
    /// winning, then pop them. The visible bindings are unchanged, there is
    /// just one scope holding them. Used when a closure's frame is reused for
    /// a tail call so the callee still sees everything the caller could see.
    pub fn collapseTo(self: *Environment, base: usize) void {
        if (base + 1 >= self.scopes.items.len) return;
        var i: usize = base + 1;
        while (i < self.scopes.items.len) : (i += 1) {
            // A collapsed scope's captures are copied in, because the scope
            // they were lent to is about to go and `base` may have captures of
            // its own. This is the one place that still pays the old cost, and
            // it is per tail call rather than per call.
            const scope = self.scopes.items[i];
            for (scope.captured) |b| {
                self.defineIn(base, b.name, b.hash, nameBit(b.name), b.val);
            }
            // Only a call frame is lent a view of the top level, and a call
            // frame is popped before its caller collapses anything; were one
            // here, its snapshot view would go where its captures went.
            for ([_]u32{ scope.globals_mark, scope.left_mark }) |m| {
                if (m != live and m > self.scopes.items[base].left_mark) self.scopes.items[base].left_mark = m;
            }
            for (scope.bindings.items) |b| {
                self.defineIn(base, b.name, b.hash, nameBit(b.name), b.val);
            }
        }
        while (self.scopes.items.len > base + 1) {
            if (self.scopes.pop()) |scope| self.recycle(scope);
        }
    }

    /// Define (or update) a variable in the current scope.
    pub fn define(self: *Environment, name: []const u8, value: *const Value) void {
        self.defineKeyed(name, name_key.Key.of(name), value);
    }

    /// `define` for a caller that already has the name's key (the parser
    /// computed it), so no string is hashed here.  An unset key is computed.
    pub fn defineKeyed(self: *Environment, name: []const u8, key: name_key.Key, value: *const Value) void {
        if (self.scopes.items.len == 0) return;
        const k = if (key.isSet()) key else name_key.Key.of(name);
        self.defineIn(self.scopes.items.len - 1, name, k.hash, k.bit, value);
    }

    /// `defineKeyed` for an assignment or `given`, which carries a slot
    /// hint like an identifier does: where in the frame's own region this
    /// site's binding was last time, as an offset from `own_base`.  A loop
    /// body that rebinds `acc` finds it there without scanning.  The hint is
    /// trusted only after `sameName` agrees, and a callee's own region holds
    /// each name once, so a validated slot is the binding `defineIn` would
    /// have found.  Whatever happens, the hint is left pointing at the slot.
    pub fn defineHinted(self: *Environment, name: []const u8, key: name_key.Key, hint: ?*u32, value: *const Value) void {
        const h = hint orelse return self.defineKeyed(name, key, value);
        if (self.scopes.items.len < 2) return self.defineKeyed(name, key, value);
        const k = if (key.isSet()) key else name_key.Key.of(name);
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        const items = scope.bindings.items;
        if (scope.names & k.bit != 0) {
            const at = scope.own_base +% @as(usize, h.*);
            if (at < items.len and name_key.sameName(items[at].name, items[at].hash, name, k.hash)) {
                items[at].val = value;
                return;
            }
            var j: usize = items.len;
            while (j > scope.own_base) {
                j -= 1;
                if (name_key.sameName(items[j].name, items[j].hash, name, k.hash)) {
                    items[j].val = value;
                    h.* = @intCast(j - scope.own_base);
                    return;
                }
            }
        }
        scope.names |= k.bit;
        scope.stack_names |= k.bit;
        self.markLocal(k.hash);
        h.* = @intCast(items.len - scope.own_base);
        scope.bindings.append(self.allocator, .{ .name = name, .val = value, .hash = k.hash }) catch {};
    }

    /// Bind a parameter at call entry.  The callee's own region is empty
    /// here -- `lendCaptured` either truncated it to `own_base` (the same
    /// closure re-entering) or moved `own_base` to the end (another callee),
    /// and a fresh scope has nothing -- and parameters are bound first, so
    /// there is no existing binding to look for: append.
    ///
    /// A parameter list may repeat a name (`fn(x: Int, x: Int)` parses and
    /// the last argument wins).  The parser marks the earlier one
    /// `HandlerParam.shadowed` and the caller does not bind it, so the
    /// region keeps each name once, which `lookupHinted` and `defineHinted`
    /// rely on when they trust a validated slot.
    pub fn bindParam(self: *Environment, name: []const u8, key: name_key.Key, value: *const Value) void {
        if (self.scopes.items.len == 0) return;
        const k = if (key.isSet()) key else name_key.Key.of(name);
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        if (self.scopes.items.len == 1) return self.defineIn(0, name, k.hash, k.bit, value);
        scope.names |= k.bit;
        scope.stack_names |= k.bit;
        self.markLocal(k.hash);
        scope.bindings.append(self.allocator, .{ .name = name, .val = value, .hash = k.hash }) catch {};
    }

    fn defineIn(self: *Environment, index: usize, name: []const u8, hash: u32, bit: u64, value: *const Value) void {
        const scope = &self.scopes.items[index];
        if (index == 0) {
            // Appended, never overwritten, so closures made earlier still see
            // the value they were made with (see `global_prev`). And no scan
            // for an existing binding: that made loading N defs N^2/2 string
            // comparisons.
            scope.names |= bit;
            const at: u32 = @intCast(scope.bindings.items.len);
            scope.bindings.append(self.allocator, .{ .name = name, .val = value, .hash = hash }) catch return;
            self.indexGlobal(name, hash, at);
            return;
        }
        // A clear bit means no binding of this name is in the scope at all,
        // so the scan for one to overwrite is skipped.  Every assignment in a
        // loop body is a define, and each used to compare its name against
        // every local in the frame.
        self.markLocal(hash);
        if (scope.names & bit == 0) {
            scope.names |= bit;
            scope.stack_names |= bit;
            scope.bindings.append(self.allocator, .{ .name = name, .val = value, .hash = hash }) catch {};
            return;
        }
        scope.names |= bit;
        scope.stack_names |= bit;
        // Only the current callee's own region is searched for an existing
        // binding. Reaching below `own_base` would update an entry a previous
        // callee left in this frame, and it would stay at that low index --
        // where `lookup` reads it only *after* the captures, so the callee's
        // own parameter would lose to something it captured.
        for (scope.bindings.items[scope.own_base..]) |*binding| {
            if (name_key.sameName(binding.name, binding.hash, name, hash)) {
                binding.val = value;
                return;
            }
        }
        scope.bindings.append(self.allocator, .{ .name = name, .val = value, .hash = hash }) catch {};
    }

    /// Return all bindings visible from the current scope (innermost wins).
    /// `seen` is a hash set rather than a list that is searched.
    ///
    /// Every `def` and every `fn` literal snapshots the visible environment
    /// through here, and with the ~400-definition prelude in the file the
    /// linear search made one `fn(x) do x end` cost 3ms.
    pub fn allBindings(self: *const Environment, allocator: std.mem.Allocator) []const Binding {
        return self.bindingsDownTo(allocator, 0);
    }

    /// What a closure made here captures: every visible binding except the
    /// top-level ones. Those it reads in place, through Closure.globals_mark.
    /// With the top level in the snapshot, making a closure cost time and
    /// memory in proportion to the number of top-level definitions.
    pub fn capturableBindings(self: *const Environment, allocator: std.mem.Allocator) []const Binding {
        return self.bindingsDownTo(allocator, 1);
    }

    fn bindingsDownTo(self: *const Environment, allocator: std.mem.Allocator, lowest: usize) []const Binding {
        var seen: std.StringHashMapUnmanaged(void) = .{};
        var result = std.ArrayList(Binding){ .items = &.{}, .capacity = 0 };

        // Walk from innermost to outermost
        var i: usize = self.scopes.items.len;
        while (i > lowest) {
            i -= 1;
            const scope = self.scopes.items[i];
            if (i == 0) {
                // Append-only: only the latest binding of each name counts.
                for (scope.bindings.items, 0..) |binding, j| {
                    if (self.globals.get(.{ .name = binding.name, .hash = binding.hash }) != @as(u32, @intCast(j))) continue;
                    const got = seen.getOrPut(allocator, binding.name) catch continue;
                    if (!got.found_existing) result.append(allocator, binding) catch {};
                }
                continue;
            }
            // `seen` keeps the first of a name, so these are walked in the
            // order `lookup` resolves them: the callee's own bindings, then
            // what it captured, then what an earlier callee left behind.
            for (scope.bindings.items[scope.own_base..]) |binding| {
                const got = seen.getOrPut(allocator, binding.name) catch continue;
                if (!got.found_existing) {
                    result.append(allocator, binding) catch {};
                }
            }
            for (scope.captured) |binding| {
                const got = seen.getOrPut(allocator, binding.name) catch continue;
                if (!got.found_existing) {
                    result.append(allocator, .{ .name = binding.name, .val = binding.val, .hash = binding.hash }) catch {};
                }
            }
            for (scope.bindings.items[0..scope.own_base]) |binding| {
                const got = seen.getOrPut(allocator, binding.name) catch continue;
                if (!got.found_existing) {
                    result.append(allocator, binding) catch {};
                }
            }
        }
        return result.items;
    }

    /// Whether some frame other than the top level may bind a name with
    /// this `nameBit`.  Conservative: the masks are never cleared and
    /// several names share a bit, so a true may be a false alarm; a false
    /// is certain.
    pub fn bindsLocally(self: *const Environment, bit: u64) bool {
        const n = self.scopes.items.len;
        if (n < 2) return false;
        return self.scopes.items.ptr[n - 1].stack_names & bit != 0;
    }

    /// True only if `lookupKeyed(name, key)` is certain to find nothing.
    /// For a caller whose `bindsLocally` said maybe (a bit shared with
    /// some frame's other names) and who needs to know whether a binding
    /// really is there.  `lookupKeyed` answered that by walking all of the
    /// frames, 19 on average on the Markdown bench; this stops at the first
    /// frame whose `stack_names` says nothing at or below it can bind the
    /// name, and answers false ("maybe bound") for any top-level binding of
    /// the name without working out whether this frame's mark sees it.
    pub fn unbound(self: *const Environment, name: []const u8, key: name_key.Key) bool {
        const nk = if (key.isSet()) key else name_key.Key.of(name);
        var i: usize = self.scopes.items.len;
        while (i > 1) {
            i -= 1;
            const scope = &self.scopes.items[i];
            if (scope.stack_names & nk.bit == 0) break;
            if (scope.names & nk.bit != 0) {
                for (scope.bindings.items) |b| {
                    if (name_key.sameName(b.name, b.hash, name, nk.hash)) return false;
                }
            }
            if (scope.captured_names & nk.bit != 0) {
                for (scope.captured) |b| {
                    if (name_key.sameName(b.name, b.hash, name, nk.hash)) return false;
                }
            }
        }
        return self.globals.get(.{ .name = name, .hash = nk.hash }) == null;
    }

    /// Whether the top level binds `name` at all, at any mark.
    pub fn hasGlobal(self: *const Environment, name: []const u8, key: name_key.Key) bool {
        return self.globals.get(.{ .name = name, .hash = if (key.isSet()) key.hash else name_key.hashName(name) }) != null;
    }

    /// A call site's memory of a top-level binding.
    pub const TopSlot = struct {
        /// `globals_version` when it was filled; any later top-level define
        /// or reindex (gc compaction) makes it stale.
        version: u32 = 0,
        /// The binding's index in the top-level scope.
        index: u32 = 0,
        /// null: nothing remembered.
        val: ?*const Value = null,
        /// `nameBit(name)`, so a hit does not recompute it.
        bit: u64 = 0,
    };

    /// The remembered binding, if `lookup(name)` from the current stack is
    /// certain to return it; null means "ask `lookup`".
    ///
    /// The slot holds the *latest* top-level binding of the name.  `lookup`
    /// returns that binding when
    ///   1. the version is unchanged (a top-level define or a compaction
    ///      bumps it), and
    ///   2. walking out from the innermost frame, no frame binds or
    ///      captures the name (`names`/`captured_names` have no bit for it;
    ///      a set bit may be a false alarm and only means the slow path)
    ///      before the first frame that reads the top level at all, the
    ///      first with a nonzero `globals_mark`, else `left_mark`, and
    ///   3. that frame's mark is above the binding's index.  A top-level
    ///      def's frame has mark `live`.  A frame with a lower mark sees an
    ///      older binding; the slot cannot say which, so it is not used.
    /// `lookup` stops at that frame too, so nothing further out matters:
    /// the walk is as long as the run of block scopes above the call's own
    /// frame, not as long as the stack.
    pub fn topHit(self: *const Environment, slot: *const TopSlot) ?*const Value {
        const v = slot.val orelse return null;
        if (slot.version != self.globals_version) return null;
        var i: usize = self.scopes.items.len;
        while (i > 1) {
            i -= 1;
            const scope = &self.scopes.items[i];
            if ((scope.names | scope.captured_names) & slot.bit != 0) return null;
            const m = if (scope.globals_mark != 0) scope.globals_mark else scope.left_mark;
            if (m != 0) return if (slot.index < m) v else null;
        }
        return v;
    }

    /// Remember the name's latest top-level binding if `topHit` would
    /// return it from here.  Independent of how `lookup` found its answer:
    /// `topHit` holding is what makes the slot sound.
    pub fn fillTop(self: *const Environment, slot: *TopSlot, name: []const u8, key: name_key.Key) void {
        if (self.scopes.items.len == 0) return;
        const idx = self.globals.get(.{ .name = name, .hash = if (key.isSet()) key.hash else name_key.hashName(name) }) orelse return;
        slot.version = self.globals_version;
        slot.index = idx;
        slot.val = self.scopes.items[0].bindings.items[idx].val;
        slot.bit = if (key.isSet()) key.bit else nameBit(name);
        if (self.topHit(slot) == null) slot.val = null;
    }

    /// Look up a variable, searching from innermost to outermost scope.
    pub fn lookup(self: *const Environment, name: []const u8) ?*const Value {
        return self.lookupKeyed(name, name_key.Key.of(name));
    }

    /// `lookup` for a caller holding the name's key.  An unset key is computed.
    pub fn lookupKeyed(self: *const Environment, name: []const u8, key: name_key.Key) ?*const Value {
        return self.lookupHinted(name, key, null);
    }

    /// One frame out is this much in a hint.
    pub const hint_frame_unit: u32 = 1 << 24;

    fn setHint(hint: *u32, frames_out: usize, offset: usize) void {
        if (frames_out >= 255 or offset >= hint_frame_unit) return;
        hint.* = @intCast(frames_out << 24 | offset);
    }

    /// The hot case of `lookupHinted`, small enough to inline into the
    /// evaluator: the hint names a slot in the innermost frame's own region
    /// and the slot holds this very name (the same interned bytes).  Nothing
    /// else is looked at: a name in that region is the first thing `lookup`
    /// would find, whatever the masks or marks say.  A hint that points
    /// outward is a number too large for the slot test, so it falls through
    /// like every other miss.
    pub inline fn lookupFast(self: *const Environment, name: []const u8, key: name_key.Key, hint: ?*u32) ?*const Value {
        if (hint) |h| {
            const n = self.scopes.items.len;
            if (n >= 2) {
                const scope = &self.scopes.items.ptr[n - 1];
                const at = scope.own_base +% @as(usize, h.*);
                if (at < scope.bindings.items.len) {
                    const b = &scope.bindings.items.ptr[at];
                    if (b.name.ptr == name.ptr and b.name.len == name.len) return b.val;
                }
            }
        }
        return self.lookupHinted(name, key, hint);
    }

    /// A hint that points `frames_out` scopes out, checked.  The scan would
    /// reach that frame only if every scope above it fails to bind or
    /// capture the name and reads no top-level mark, which is what is tested
    /// here; a clear bit is certain, a set one is a false alarm at worst and
    /// sends the read to the scan.
    noinline fn outerHint(self: *const Environment, name: []const u8, bit: u64, h: u32) ?*const Value {
        const frames_out: usize = h >> 24;
        const n = self.scopes.items.len;
        if (frames_out + 2 > n) return null;
        const base = self.scopes.items.ptr;
        var k: usize = n - 1;
        const target = n - 1 - frames_out;
        while (k > target) : (k -= 1) {
            const s = &base[k];
            if ((s.names | s.captured_names) & bit != 0) return null;
            if (s.globals_mark | s.left_mark != 0) return null;
        }
        const scope = &base[target];
        const at = scope.own_base +% @as(usize, h & (hint_frame_unit - 1));
        if (at >= scope.bindings.items.len) return null;
        const b = &scope.bindings.items.ptr[at];
        if (b.name.ptr == name.ptr and b.name.len == name.len) return b.val;
        return null;
    }

    /// `lookupKeyed` with an inline cache: `hint` says where this read found
    /// its name last time.  It is only a guess to try first, validated on
    /// every use, so a stale hint costs the scan and nothing else.
    ///
    /// The hint is `frames_out << 24 | offset`.  `offset` is the slot's
    /// distance from that frame's `own_base`, so a tail call that reuses the
    /// frame, and moves `own_base`, still hits.  `frames_out` is how many
    /// scopes above that frame the read stood in: a `case` arm or a `for`
    /// body pushes a scope, and a parameter read there lives one or two
    /// scopes down.  Within a callee's own region a name appears once
    /// (`defineIn` overwrites in place), so a validated slot is the binding
    /// the scan would find, provided the scan would have reached that frame:
    /// `outerHint` checks that no scope in between binds, captures or reads
    /// the top level through a mark.
    ///
    /// The common case, the slot in the innermost frame, is `lookupFast`;
    /// this function is what it falls back to.
    pub fn lookupHinted(self: *const Environment, name: []const u8, key: name_key.Key, hint: ?*u32) ?*const Value {
        const nk = if (key.isSet()) key else name_key.Key.of(name);
        const bit = nk.bit;
        const hash = nk.hash;
        if (hint) |h| {
            if (h.* >= hint_frame_unit) {
                if (self.outerHint(name, bit, h.*)) |v| return v;
            }
        }
        const top_i = self.scopes.items.len -% 1;
        // True while every scope walked so far reads no top-level mark, so
        // a hint written for a later frame can validate (`outerHint`).
        var clean = true;
        var top: ?u32 = null;
        var top_known = false;
        var i: usize = self.scopes.items.len;
        while (i > 1) {
            i -= 1;
            const scope = &self.scopes.items[i];
            // Three tiers, in the order copying the captures in used to
            // produce: what the current callee bound, then what it captured,
            // then what an earlier callee left in a reused frame.
            if (scope.names & bit != 0) {
                const items = scope.bindings.items;
                if (hint != null and i == top_i) {
                    const at = scope.own_base +% @as(usize, hint.?.*);
                    if (at < items.len and name_key.sameName(items[at].name, items[at].hash, name, hash)) {
                        return items[at].val;
                    }
                }
                var j: usize = items.len;
                while (j > scope.own_base) {
                    j -= 1;
                    if (name_key.sameName(items[j].name, items[j].hash, name, hash)) {
                        if (hint != null and clean) setHint(hint.?, top_i - i, j - scope.own_base);
                        return items[j].val;
                    }
                }
            }
            if (scope.captured_names & bit != 0) {
                var k: usize = scope.captured.len;
                while (k > 0) {
                    k -= 1;
                    if (name_key.sameName(scope.captured[k].name, scope.captured[k].hash, name, hash)) {
                        return scope.captured[k].val;
                    }
                }
            }
            if (scope.globals_mark != 0) {
                if (!top_known) {
                    top = self.globals.get(.{ .name = name, .hash = hash });
                    top_known = true;
                }
                if (self.topFrom(top, scope.globals_mark)) |v| return v;
            }
            if (scope.names & bit != 0) {
                var j: usize = scope.own_base;
                while (j > 0) {
                    j -= 1;
                    if (name_key.sameName(scope.bindings.items[j].name, scope.bindings.items[j].hash, name, hash)) {
                        return scope.bindings.items[j].val;
                    }
                }
            }
            if (scope.left_mark != 0) {
                if (!top_known) {
                    top = self.globals.get(.{ .name = name, .hash = hash });
                    top_known = true;
                }
                if (self.topFrom(top, scope.left_mark)) |v| return v;
            }
            if (scope.globals_mark | scope.left_mark != 0) clean = false;
        }
        if (self.scopes.items.len == 0) return null;
        if (!top_known) top = self.globals.get(.{ .name = name, .hash = hash });
        return self.topFrom(top, live);
    }
};

// ============================================================
// Tests
// ============================================================

test "define and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 42 };
    env.define("x", val);

    const result = env.lookup("x");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.eql(Value{ .integer = 42 }));
}

test "lookup missing returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    try std.testing.expect(env.lookup("missing") == null);
}

test "nested scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val_x = try alloc.create(Value);
    val_x.* = Value{ .integer = 1 };
    env.define("x", val_x);

    env.pushScope();
    const val_y = try alloc.create(Value);
    val_y.* = Value{ .integer = 2 };
    env.define("y", val_y);

    // Inner scope sees both x and y
    try std.testing.expect(env.lookup("x") != null);
    try std.testing.expect(env.lookup("y") != null);

    env.popScope();
    // After pop, y is gone
    try std.testing.expect(env.lookup("x") != null);
    try std.testing.expect(env.lookup("y") == null);
}

test "collapseTo keeps the visible bindings in one scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const one = try alloc.create(Value);
    one.* = Value{ .integer = 1 };
    const two = try alloc.create(Value);
    two.* = Value{ .integer = 2 };
    const three = try alloc.create(Value);
    three.* = Value{ .integer = 3 };

    env.define("g", one);
    const base = env.depth();
    env.pushScope();
    env.define("x", one);
    env.define("y", one);
    env.pushScope();
    env.define("x", two);
    env.pushScope();
    env.define("z", three);

    env.collapseTo(base);
    try std.testing.expectEqual(base + 1, env.depth());
    try std.testing.expect(env.lookup("x").?.eql(Value{ .integer = 2 }));
    try std.testing.expect(env.lookup("y").?.eql(Value{ .integer = 1 }));
    try std.testing.expect(env.lookup("z").?.eql(Value{ .integer = 3 }));
    try std.testing.expect(env.lookup("g").?.eql(Value{ .integer = 1 }));

    env.popTo(base);
    try std.testing.expectEqual(base, env.depth());
    try std.testing.expect(env.lookup("x") == null);
    try std.testing.expect(env.lookup("g") != null);
}

test "a pushed and popped scope costs nothing the second time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 1 };

    // Let the scope stack and the first binding list reach their size.
    for (0..64) |_| {
        env.pushScope();
        env.define("x", val);
        env.popScope();
    }
    const settled = arena.queryCapacity();

    for (0..10_000) |_| {
        env.pushScope();
        env.define("x", val);
        env.popScope();
    }

    // Every call pushes a scope.  If popping dropped the binding list, this
    // loop would leave 10_000 of them in the arena.
    try std.testing.expectEqual(settled, arena.queryCapacity());
}

test "a name in an outer scope is found through many inner ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const target = try alloc.create(Value);
    target.* = Value{ .integer = 99 };
    const noise = try alloc.create(Value);
    noise.* = Value{ .integer = 1 };

    env.define("target", target);
    for (0..64) |i| {
        env.pushScope();
        // Names chosen to land on assorted bits, including whatever `target`
        // hashes to: a scope that claims the bit must still be searched, and
        // one that does not must still be skipped correctly.
        const name = try std.fmt.allocPrint(alloc, "n{d}", .{i});
        env.define(name, noise);
    }

    try std.testing.expectEqual(@as(i64, 99), env.lookup("target").?.integer);
    try std.testing.expect(env.lookup("absent") == null);

    // And still after the frames above it are collapsed into one.
    env.collapseTo(1);
    try std.testing.expectEqual(@as(i64, 99), env.lookup("target").?.integer);
    try std.testing.expectEqual(@as(i64, 1), env.lookup("n7").?.integer);
}

test "inner scope shadows outer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val1 = try alloc.create(Value);
    val1.* = Value{ .integer = 1 };
    env.define("x", val1);

    env.pushScope();
    const val2 = try alloc.create(Value);
    val2.* = Value{ .string = "shadowed" };
    env.define("x", val2);
    try std.testing.expect(env.lookup("x").?.eql(Value{ .string = "shadowed" }));

    env.popScope();
    try std.testing.expect(env.lookup("x").?.eql(Value{ .integer = 1 }));
}

test "a call does not pay for what the closure captured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 7 };

    // A closure that captured four hundred names, which is the shape every
    // translated Temper program has: the prelude defines that many and each
    // definition captures all of them.
    var captured = try alloc.alloc(Value.CapturedBinding, 400);
    var names: u64 = 0;
    for (0..400) |i| {
        const name = try std.fmt.allocPrint(alloc, "prelude_helper_{d}", .{i});
        captured[i] = .{ .name = name, .val = val, .hash = Environment.hashName(name) };
        names |= Environment.nameBit(name);
    }

    env.pushScope();
    env.lendCaptured(captured, names, @intFromPtr(captured.ptr), 0);
    // Lending is what a call does. Nothing was written into the scope, so the
    // cost does not grow with how much was captured.
    try std.testing.expectEqual(@as(usize, 0), env.scopes.items[env.scopes.items.len - 1].bindings.items.len);
    try std.testing.expect(env.lookup("prelude_helper_399") != null);
    try std.testing.expect(env.lookup("prelude_helper_0") != null);
    try std.testing.expect(env.lookup("never_defined") == null);
}

test "a parameter shadows a capture of the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const captured_val = try alloc.create(Value);
    captured_val.* = Value{ .integer = 1 };
    const param_val = try alloc.create(Value);
    param_val.* = Value{ .integer = 2 };

    const captured = try alloc.alloc(Value.CapturedBinding, 1);
    captured[0] = .{ .name = "x", .val = captured_val, .hash = Environment.hashName("x") };

    env.pushScope();
    env.lendCaptured(captured, Environment.nameBit("x"), @intFromPtr(captured.ptr), 0);
    try std.testing.expect(env.lookup("x").?.eql(Value{ .integer = 1 }));
    // A call lends the captures and then binds its parameters, so the
    // parameter has to win -- which it does because lookup reads `bindings`
    // before `captured`.
    env.define("x", param_val);
    try std.testing.expect(env.lookup("x").?.eql(Value{ .integer = 2 }));
}

test "collapsing a scope keeps what it was lent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 42 };
    const captured = try alloc.alloc(Value.CapturedBinding, 1);
    captured[0] = .{ .name = "helper", .val = val, .hash = Environment.hashName("helper") };

    const base = env.depth();
    env.pushScope();
    env.lendCaptured(captured, Environment.nameBit("helper"), @intFromPtr(captured.ptr), 0);
    env.pushScope();
    // A tail call collapses the frames it is leaving. A capture that only the
    // collapsed scope was lent has to survive, or the callee cannot see what
    // its caller could.
    env.collapseTo(base);
    try std.testing.expect(env.lookup("helper") != null);
}

test "a callee's capture beats what an earlier callee left in the frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const stale = try alloc.create(Value);
    stale.* = Value{ .integer = 1 };
    const mine = try alloc.create(Value);
    mine.* = Value{ .integer = 2 };

    const first = try alloc.alloc(Value.CapturedBinding, 1);
    first[0] = .{ .name = "other", .val = stale, .hash = Environment.hashName("other") };
    const second = try alloc.alloc(Value.CapturedBinding, 1);
    second[0] = .{ .name = "k", .val = mine, .hash = Environment.hashName("k") };

    env.pushScope();
    // One callee runs in the frame and binds `k`...
    env.lendCaptured(first, Environment.nameBit("other"), @intFromPtr(first.ptr), 0);
    env.define("k", stale);
    // ...then tail-calls another, which captured its own `k`. The one left
    // behind must not shadow it. This is the regex engine's continuation:
    // when it did, `temper_rx_seq_at` ran off the end of its node list and
    // kept calling itself, because the `k` it reached was the wrong one.
    env.lendCaptured(second, Environment.nameBit("k"), @intFromPtr(second.ptr), 0);
    try std.testing.expect(env.lookup("k").?.eql(Value{ .integer = 2 }));
    // What the outgoing callee captured is still reachable, below both.
    try std.testing.expect(env.lookup("other") != null);
}

test "the same closure re-entering its frame does not grow it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 5 };
    const captured = try alloc.alloc(Value.CapturedBinding, 1);
    captured[0] = .{ .name = "g", .val = val, .hash = Environment.hashName("g") };

    env.pushScope();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        // What a tail-recursive loop does: lend the same captures, bind the
        // same parameter names again.
        env.lendCaptured(captured, Environment.nameBit("g"), @intFromPtr(captured.ptr), 0);
        env.define("n", val);
        env.define("acc", val);
    }
    const scope = env.scopes.items[env.scopes.items.len - 1];
    try std.testing.expectEqual(@as(usize, 2), scope.bindings.items.len);
}

test "the top level is found by name, not by scanning it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const first = try alloc.create(Value);
    first.* = Value{ .integer = 1 };
    const second = try alloc.create(Value);
    second.* = Value{ .integer = 2 };

    env.define("called", first);
    for (0..5000) |i| {
        env.define(try std.fmt.allocPrint(alloc, "def_{d}", .{i}), first);
    }
    try std.testing.expectEqual(@as(usize, 5001), env.globals.count());
    try std.testing.expectEqual(@as(i64, 1), env.lookup("called").?.integer);

    // Redefining appends, and the latest wins for a live read...
    const before = env.globalsMark();
    env.define("called", second);
    try std.testing.expectEqual(@as(i64, 2), env.lookup("called").?.integer);
    // ...while a read at an earlier mark sees the value it had then.
    try std.testing.expectEqual(@as(i64, 1), env.lookupTopAt("called", before).?.integer);
    try std.testing.expect(env.lookupTopAt("def_10", 1) == null);
    // allBindings reports a redefined name once, with its latest value.
    var n_called: usize = 0;
    for (env.allBindings(alloc)) |b| {
        if (std.mem.eql(u8, b.name, "called")) {
            n_called += 1;
            try std.testing.expectEqual(@as(i64, 2), b.val.integer);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), n_called);
}

test "what a closure captures does not include the top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 3 };
    for (0..3000) |i| {
        env.define(try std.fmt.allocPrint(alloc, "def_{d}", .{i}), val);
    }
    env.pushScope();
    env.define("local", val);
    // A closure made here used to copy 3001 bindings; it needs one.
    const got = env.capturableBindings(alloc);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("local", got[0].name);
}

test "a stale hint is validated, never trusted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const one = try alloc.create(Value);
    one.* = Value{ .integer = 1 };
    const two = try alloc.create(Value);
    two.* = Value{ .integer = 2 };
    const key = name_key.Key.of("b");

    var hint: u32 = 0;
    env.pushScope();
    env.define("a", one);
    env.define("b", two);
    try std.testing.expectEqual(@as(i64, 2), env.lookupHinted("b", key, &hint).?.integer);
    try std.testing.expectEqual(@as(u32, 1), hint);
    env.popScope();

    // A frame with a different layout: the hint points at a slot that holds
    // another name, then past the end, then at the right slot.
    env.pushScope();
    env.define("b", one);
    env.define("c", two);
    hint = 1;
    try std.testing.expectEqual(@as(i64, 1), env.lookupHinted("b", key, &hint).?.integer);
    try std.testing.expectEqual(@as(u32, 0), hint);
    hint = 9;
    try std.testing.expectEqual(@as(i64, 1), env.lookupHinted("b", key, &hint).?.integer);
    // A name the frame does not bind falls through, whatever the hint says.
    hint = 0;
    try std.testing.expect(env.lookupHinted("zz", name_key.Key.of("zz"), &hint) == null);
    env.popScope();
}

test "defineHinted validates its slot and leaves the hint pointing at the binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Environment.init(alloc);
    var vals: [4]*const Value = undefined;
    for (&vals, 0..) |*v, i| {
        const p = try alloc.create(Value);
        p.* = Value{ .integer = @intCast(i) };
        v.* = p;
    }
    const key = name_key.Key.of("acc");

    // A fresh name is appended and the hint records where.
    var hint: u32 = 0;
    env.pushScope();
    env.define("a", vals[0]);
    env.defineHinted("acc", key, &hint, vals[1]);
    try std.testing.expectEqual(@as(u32, 1), hint);
    // Rebinding goes straight to the slot, with no growth of the frame.
    env.defineHinted("acc", key, &hint, vals[2]);
    try std.testing.expectEqual(@as(usize, 2), env.scopes.items[1].bindings.items.len);
    try std.testing.expectEqual(@as(i64, 2), env.lookup("acc").?.integer);
    env.popScope();

    // Another frame layout: a stale hint (wrong name in the slot, then past
    // the end) is corrected, not trusted, and never makes a second binding.
    env.pushScope();
    env.define("acc", vals[0]);
    env.define("b", vals[1]);
    hint = 1;
    env.defineHinted("acc", key, &hint, vals[3]);
    try std.testing.expectEqual(@as(u32, 0), hint);
    hint = 9;
    env.defineHinted("acc", key, &hint, vals[2]);
    try std.testing.expectEqual(@as(usize, 2), env.scopes.items[1].bindings.items.len);
    try std.testing.expectEqual(@as(i64, 2), env.lookup("acc").?.integer);
    env.popScope();

    // A hint must not reach below own_base: a binding an earlier callee left
    // in a reused frame is not overwritten, a new one is appended.
    env.pushScope();
    env.define("acc", vals[0]);
    env.scopes.items[1].own_base = 1;
    hint = 0;
    env.defineHinted("acc", key, &hint, vals[3]);
    try std.testing.expectEqual(@as(usize, 2), env.scopes.items[1].bindings.items.len);
    try std.testing.expectEqual(@as(i64, 0), env.scopes.items[1].bindings.items[0].val.integer);
    try std.testing.expectEqual(@as(i64, 3), env.lookup("acc").?.integer);
    env.popScope();
}

test "bindParam appends without looking for an existing binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Environment.init(alloc);
    const one = try alloc.create(Value);
    one.* = Value{ .integer = 1 };
    const two = try alloc.create(Value);
    two.* = Value{ .integer = 2 };
    env.pushScope();
    env.bindParam("x", name_key.Key.of("x"), one);
    env.bindParam("y", name_key.Key.of("y"), two);
    try std.testing.expectEqual(@as(usize, 2), env.scopes.items[1].bindings.items.len);
    try std.testing.expectEqual(@as(i64, 1), env.lookup("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), env.lookup("y").?.integer);
    env.popScope();
}

// A hint that points outward: the read stands in a block scope and the name
// lives in the frame below it.  Each test sets the hint by a first read, then
// changes the stack so that using it would be wrong.
fn testVal(alloc: std.mem.Allocator, n: i64) !*const Value {
    const v = try alloc.create(Value);
    v.* = Value{ .integer = n };
    return v;
}

test "an outward hint is written by the scan and answered without it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Environment.init(alloc);
    const key = name_key.Key.of("x");
    const captured: []const Value.CapturedBinding = &.{};

    env.pushScope();
    env.lendCaptured(captured, 0, 1, Environment.live);
    env.define("p", try testVal(alloc, 0));
    env.define("x", try testVal(alloc, 7));
    env.pushScope(); // a case arm
    env.pushScope(); // and a for body inside it
    var hint: u32 = 0;
    try std.testing.expectEqual(@as(i64, 7), env.lookupFast("x", key, &hint).?.integer);
    try std.testing.expectEqual(@as(u32, 2 << 24 | 1), hint);
    // Second read: answered by outerHint from the validated slot alone.
    try std.testing.expectEqual(@as(i64, 7), env.lookupFast("x", key, &hint).?.integer);

    // The inner scope now binds x: the hint would be wrong, and is refused.
    env.define("x", try testVal(alloc, 8));
    try std.testing.expectEqual(@as(i64, 8), env.lookupFast("x", key, &hint).?.integer);
    env.popScope();
    // The scan rewrote the hint to the inner scope's own slot.  One scope
    // out that slot does not exist: refused, scanned, rewritten for this
    // depth.
    try std.testing.expectEqual(@as(i64, 7), env.lookupFast("x", key, &hint).?.integer);
    try std.testing.expectEqual(@as(u32, 1 << 24 | 1), hint);
    env.popScope();
    // In the frame itself the hint is the plain slot again.
    try std.testing.expectEqual(@as(i64, 7), env.lookupFast("x", key, &hint).?.integer);
    try std.testing.expectEqual(@as(u32, 1), hint);
    env.popScope();
}

test "an outward hint never crosses a frame that reads the top level, binds, or captures the name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Environment.init(alloc);
    const key = name_key.Key.of("x");
    env.define("x", try testVal(alloc, 100)); // top level
    const mark = env.globalsMark();

    // Frame A binds x = 1 and reads it from a block scope: hint 1 out.
    env.pushScope();
    env.lendCaptured(&.{}, 0, 1, Environment.live);
    env.define("x", try testVal(alloc, 1));
    env.pushScope();
    var hint: u32 = 0;
    // Frame A is a top-level def (mark live), but its own x is found first.
    try std.testing.expectEqual(@as(i64, 1), env.lookupFast("x", key, &hint).?.integer);
    try std.testing.expectEqual(@as(u32, 1 << 24), hint);
    env.popScope();

    // Frame B, called from A, reads the top level (mark live) and does not
    // bind x.  A hint of 2 out, from B's block scope, would reach A's x;
    // lookup stops at B's mark and returns the global.
    env.pushScope();
    env.lendCaptured(&.{}, 0, 2, Environment.live);
    env.pushScope();
    hint = 2 << 24;
    try std.testing.expectEqual(@as(i64, 100), env.lookupFast("x", key, &hint).?.integer);
    env.popScope();
    env.popScope();
    env.popScope();

    // A frame whose view of the top level ends before the redefinition
    // sees the old global.
    env.define("x", try testVal(alloc, 200));
    env.pushScope();
    env.lendCaptured(&.{}, 0, 5, Environment.live);
    env.define("x", try testVal(alloc, 1));
    env.pushScope();
    env.lendCaptured(&.{}, 0, 3, mark);
    env.pushScope();
    hint = 2 << 24;
    try std.testing.expectEqual(@as(i64, 100), env.lookupFast("x", key, &hint).?.integer);
    env.popScope();
    env.popScope();
    env.popScope();

    // A block scope that was lent the name (a state field) wins too.
    env.pushScope();
    env.lendCaptured(&.{}, 0, 4, Environment.live);
    env.define("x", try testVal(alloc, 2));
    env.pushScope();
    const cap = [_]Value.CapturedBinding{.{ .name = "x", .val = try testVal(alloc, 3), .hash = key.hash }};
    env.lendState(&cap, key.bit);
    hint = 1 << 24;
    try std.testing.expectEqual(@as(i64, 3), env.lookupFast("x", key, &hint).?.integer);
    env.popScope();
    env.popScope();
}

test "an outward hint survives a tail call that moves own_base, and compaction's reindex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Environment.init(alloc);
    const key = name_key.Key.of("n");
    env.define("g", try testVal(alloc, 5));
    env.pushScope();
    var hint: u32 = 0;
    var round: i64 = 0;
    while (round < 4) : (round += 1) {
        // Another callee takes the frame each round, so own_base moves.
        env.lendCaptured(&.{}, 0, @intCast(9 + round), Environment.live);
        env.define("pad", try testVal(alloc, 0));
        env.define("n", try testVal(alloc, round));
        env.pushScope();
        try std.testing.expectEqual(round, env.lookupFast("n", key, &hint).?.integer);
        try std.testing.expectEqual(round, env.lookupFast("n", key, &hint).?.integer);
        env.popScope();
        if (round == 2) env.reindexGlobals();
        try std.testing.expectEqual(@as(i64, 5), env.lookup("g").?.integer);
    }
    env.popScope();
}

test "lookupFast takes a slot only for the same name, and defers to the scan otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Environment.init(alloc);
    env.pushScope();
    env.define("x", try testVal(alloc, 1));
    env.define("y", try testVal(alloc, 2));
    var hint: u32 = 1; // the slot of y
    // x asked for y's slot: refused, scanned, rewritten.
    try std.testing.expectEqual(@as(i64, 1), env.lookupFast("x", name_key.Key.of("x"), &hint).?.integer);
    try std.testing.expectEqual(@as(u32, 0), hint);
    // A copy of the name at another address is the same name.
    const copy = try alloc.dupe(u8, "y");
    try std.testing.expectEqual(@as(i64, 2), env.lookupFast(copy, name_key.Key.of("y"), &hint).?.integer);
    // No hint at all.
    try std.testing.expectEqual(@as(i64, 2), env.lookupFast("y", name_key.Key.of("y"), null).?.integer);
    env.popScope();
    // Only the top level on the stack: nothing to take a slot from.
    try std.testing.expect(env.lookupFast("x", name_key.Key.of("x"), &hint) == null);
}

test "stack_names answers bindsLocally as the walk did, and unbound settles a shared bit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Environment.init(alloc);
    // `size` and `sire` share a bit (same first byte, last byte, length).
    const size_key = name_key.Key.of("size");
    try std.testing.expectEqual(name_key.Key.of("sire").bit, size_key.bit);
    try std.testing.expect(!env.bindsLocally(size_key.bit));
    env.define("size", try testVal(alloc, 1)); // top level: not local
    try std.testing.expect(!env.bindsLocally(size_key.bit));

    env.pushScope();
    env.define("sire", try testVal(alloc, 2));
    env.pushScope();
    env.pushScope();
    try std.testing.expect(env.bindsLocally(size_key.bit)); // from two scopes up
    try std.testing.expect(!env.unbound("size", size_key)); // the top level has one
    env.popTo(1);

    // A fresh stack, no top-level size: the shared bit is a false alarm.
    var env2 = Environment.init(alloc);
    env2.pushScope();
    env2.define("sire", try testVal(alloc, 2));
    env2.pushScope();
    try std.testing.expect(env2.bindsLocally(size_key.bit));
    try std.testing.expect(env2.unbound("size", size_key));
    // A real binding in the inner scope, then after it is popped.
    env2.define("size", try testVal(alloc, 3));
    try std.testing.expect(!env2.unbound("size", size_key));
    env2.popScope();
    try std.testing.expect(env2.unbound("size", size_key));
    env2.popScope();
    try std.testing.expect(!env2.bindsLocally(size_key.bit));
    env2.pushScope();
    try std.testing.expect(!env2.bindsLocally(size_key.bit)); // a popped scope leaves nothing
    const cap = [_]Value.CapturedBinding{.{ .name = "size", .val = try testVal(alloc, 4), .hash = size_key.hash }};
    env2.lendCaptured(&cap, size_key.bit, 5, Environment.live);
    try std.testing.expect(env2.bindsLocally(size_key.bit));
    try std.testing.expect(!env2.unbound("size", size_key));
    env2.pushScope();
    try std.testing.expect(!env2.unbound("size", size_key));
    env2.popTo(1);
}

test "everLocal: set by every way a name reaches a frame, never by the top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Environment.init(alloc);
    const names = [_][]const u8{ "by_define", "by_param", "by_hint", "by_capture", "by_state", "top_only" };
    for (names) |n| try std.testing.expect(!env.everLocal(name_key.hashName(n)));

    env.define("top_only", try testVal(alloc, 0));
    env.bindParam("top_only", name_key.Key.of("top_only"), try testVal(alloc, 0)); // one scope: top level
    try std.testing.expect(!env.everLocal(name_key.hashName("top_only")));

    env.pushScope();
    env.define("by_define", try testVal(alloc, 1));
    env.bindParam("by_param", name_key.Key.of("by_param"), try testVal(alloc, 2));
    var hint: u32 = 0;
    env.defineHinted("by_hint", name_key.Key.of("by_hint"), &hint, try testVal(alloc, 3));
    const cap = [_]Value.CapturedBinding{.{ .name = "by_capture", .val = try testVal(alloc, 4), .hash = name_key.hashName("by_capture") }};
    env.lendCaptured(&cap, name_key.nameBit("by_capture"), 9, Environment.live);
    env.pushScope();
    const st = [_]Value.CapturedBinding{.{ .name = "by_state", .val = try testVal(alloc, 5), .hash = name_key.hashName("by_state") }};
    env.lendState(&st, name_key.nameBit("by_state"));
    env.popTo(1);

    // Popping does not clear them: a clear bit must be certain, not current.
    for (names[0..5]) |n| try std.testing.expect(env.everLocal(name_key.hashName(n)));
    try std.testing.expect(!env.everLocal(name_key.hashName("top_only")));
}

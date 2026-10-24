const std = @import("std");
const Value = @import("value.zig").Value;
const NameKey = @import("name_key.zig").Key;
const Environment = @import("env.zig").Environment;

/// Source location for error reporting.
pub const Loc = struct {
    line: u32,
    col: u32,
};

/// A Blimp AST node. Tagged union of all possible node kinds.
pub const Node = struct {
    kind: Kind,
    loc: Loc,

    pub const Kind = union(enum) {
        // Top-level
        actor_def: ActorDef,
        state_def: StateDef,
        message_handler: MessageHandler,

        // Statements
        become_stmt: BecomeStmt,
        reply_stmt: ReplyStmt,
        assign_stmt: AssignStmt,

        // Expressions
        integer_lit: IntegerLit,
        float_lit: FloatLit,
        string_lit: StringLit,
        atom_lit: AtomLit,
        bool_lit: BoolLit,
        nil_lit: void,
        identifier: Identifier,
        binary_op: BinaryOp,
        unary_op: UnaryOp,
        func_call: FuncCall,
        pipe_expr: PipeExpr,
        list_lit: ListLit,
        tuple_lit: TupleLit,
        map_lit: MapLit,
        dot_access: DotAccess,
        hole: Hole,
        situation: Situation,
        case_expr: CaseExpr,
        message_send: MessageSend,
        orelse_expr: OrElseExpr,
        spawn_expr: SpawnExpr,
        struct_lit: StructLit,
        try_catch: TryCatch,
        fn_expr: FnExpr,
        call_expr: CallExpr,
        def_stmt: DefStmt,
        bubble_stmt: BubbleStmt,
        range_expr: RangeExpr,
        for_expr: ForExpr,
        spread_map: SpreadExpr,   // ...list, fn -> map
        spread_each: SpreadExpr,  // ..list, fn -> each
        self_ref: void,
        test_def: TestDef,
        property_def: PropertyDef,
        given_stmt: GivenStmt,
    };

    pub const ActorDef = struct {
        name: []const u8,
        body: []const Node,
    };

    pub const StateDef = struct {
        fields: []const KeyValue,
    };

    pub const MessageHandler = struct {
        name: []const u8, // atom name without colon
        params: []const HandlerParam,
        return_type: ?[]const u8 = null, // e.g. "Receipt", "[Item]"
        guard: ?*const Node = null,
        bubble_strategy: ?[]const u8 = null,
        body: []const Node,
    };

    pub const HandlerParam = struct {
        name: []const u8,
        key: NameKey = .{},
        type_name: ?[]const u8 = null, // null = untyped (legacy, checker will reject)
        /// `type_name` resolved once, by the parser, to what a call checks
        /// an argument against.  No default: a HandlerParam built anywhere
        /// must say, so one built without it fails to compile rather than
        /// skipping its check.  The evaluator used to resolve the string on
        /// every call -- up to ten `std.mem.eql` per typed parameter, 6% of
        /// rendering the site's posts.
        check: TypeCheck,
        /// A later parameter of the same name wins, so this one is not bound
        /// (it is still type-checked).  Set by the parser.
        shadowed: bool = false,

        /// Mark every parameter that a later one of the same name shadows.
        pub fn markShadowed(params: []HandlerParam) void {
            for (params, 0..) |*p, i| {
                for (params[i + 1 ..]) |q| {
                    if (std.mem.eql(u8, p.name, q.name)) p.shadowed = true;
                }
            }
        }
    };

    /// What a typed parameter accepts, from its annotation.
    pub const TypeCheck = enum {
        /// No annotation, `Any`, or a name that is neither a builtin type
        /// nor (at call time) compared against an actor reference: accepts
        /// everything, as the string comparison did.
        any,
        int,
        float,
        string,
        atom,
        boolean,
        nil,
        list,
        tuple,
        map,
        function,
        /// `[T]`: any list; element types are not checked.
        list_of,
        /// Any other name: an actor reference must carry this type name;
        /// every other value is let through.
        named,

        pub fn of(type_name: ?[]const u8) TypeCheck {
            const t = type_name orelse return .any;
            const table = .{
                .{ "Any", TypeCheck.any },        .{ "Int", TypeCheck.int },
                .{ "Float", TypeCheck.float },    .{ "String", TypeCheck.string },
                .{ "Atom", TypeCheck.atom },      .{ "Bool", TypeCheck.boolean },
                .{ "Nil", TypeCheck.nil },        .{ "List", TypeCheck.list },
                .{ "Tuple", TypeCheck.tuple },    .{ "Map", TypeCheck.map },
                .{ "Function", TypeCheck.function },
            };
            inline for (table) |e| {
                if (std.mem.eql(u8, t, e[0])) return e[1];
            }
            if (t.len > 2 and t[0] == '[' and t[t.len - 1] == ']') return .list_of;
            return .named;
        }
    };

    pub const BecomeStmt = struct {
        fields: []const KeyValue,
    };

    pub const ReplyStmt = struct {
        value: *const Node,
    };

    pub const AssignStmt = struct {
        name: []const u8,
        key: NameKey = .{},
        value: *const Node,
        /// Slot hint, as `Identifier.hint` (see `Environment.defineHinted`).
        hint: ?*u32 = null,
    };

    // A literal's Value is built once by the parser, in the parser's own
    // allocator, so it lives exactly as long as the node that points at it:
    // the code arena in a plain run, the heap in the wasm `send` path (where
    // the AST dies with it).  It is never in the heap a compaction replaces
    // unless its node is too.  A node built by hand, as the tests do, has
    // `prebuilt == null` and the evaluator builds the Value as it always did.
    pub const IntegerLit = struct {
        value: i64,
        prebuilt: ?*const Value = null,
    };

    pub const FloatLit = struct {
        value: f64,
        prebuilt: ?*const Value = null,
    };

    /// `value` is the lexeme as written, quotes and escapes included (the
    /// checker reads it).  The parser classifies it once: no interpolation
    /// and the unescaped text is in `prebuilt`; interpolation and the parts
    /// are in `interp`.
    pub const StringLit = struct {
        value: []const u8,
        prebuilt: ?*const Value = null,
        interp: ?*const Interp = null,
    };

    pub const InterpPart = union(enum) {
        /// Literal text, already unescaped.
        text: []const u8,
        /// The expression inside `#{...}`, parsed once.
        expr: *const Node,
    };

    pub const Interp = struct {
        parts: []const InterpPart,
        /// An unbalanced `#{` or an expression that does not parse.  It is
        /// an error when the literal is evaluated, as it was when the
        /// expression was parsed at every evaluation.
        bad: bool = false,
    };

    pub const AtomLit = struct {
        name: []const u8,
        prebuilt: ?*const Value = null,
    };

    pub const BoolLit = struct {
        value: bool,
    };

    pub const Identifier = struct {
        name: []const u8,
        key: NameKey = .{},
        /// Inline cache: where in the frame this read found its name last
        /// time (see `Environment.lookupHinted`).  Null for a node built by
        /// hand.
        hint: ?*u32 = null,
    };

    pub const BinaryOp = struct {
        op: Op,
        left: *const Node,
        right: *const Node,

        pub const Op = enum {
            add,
            concat, // ++ for list concatenation
            sub,
            mul,
            div,
            eq,
            neq,
            lt,
            gt,
            lte,
            gte,
            and_op,
            or_op,
        };
    };

    pub const UnaryOp = struct {
        op: Op,
        operand: *const Node,

        pub const Op = enum {
            negate,
            not,
        };
    };

    pub const FuncCall = struct {
        name: []const u8,
        key: NameKey = .{},
        args: []const Node,
        /// What this call site resolved to last time, when the parser gave
        /// it a slot.  A node built by hand (the checker's tests) has none
        /// and takes the slow path every time.
        cache: ?*CallCache = null,
    };

    /// A call site's memory of the builtin it resolved to.  Valid while no
    /// top-level definition has been added since (`globals_version`) and
    /// no frame on the stack binds the name (`Environment.bindsLocally`).
    /// A builtin's name has no top-level binding, so resolving it used to
    /// miss at every frame on the way out, then hash the name twice.
    pub const CallCache = struct {
        builtin: ?*const anyopaque = null,
        globals_version: u32 = 0,
        /// The name had no top-level binding when `builtin` was filled; with
        /// `globals_version` unchanged it still has none.  What `unbound`
        /// would answer once no frame can hold the name.
        no_global: bool = false,
        /// The top-level closure this site resolved to; see
        /// `Environment.topHit` for when it may be used again.
        top: Environment.TopSlot = .{},
    };

    pub const PipeExpr = struct {
        left: *const Node,
        right: *const Node,
    };

    pub const ListLit = struct {
        elements: []const Node,
        /// If non-null, this is a cons expression: [head | tail]
        tail: ?*const Node,
    };

    pub const TupleLit = struct {
        elements: []const Node,
    };

    pub const MapLit = struct {
        entries: []const KeyValue,
    };

    pub const DotAccess = struct {
        object: *const Node,
        field: []const u8,
        /// Set by the parser (`flat_checked`): the chain flattened to
        /// "App.Shop.Checkout" when the object is an identifier chain whose
        /// every part starts with an upper-case letter, the only names
        /// `actor` binds.  Null means "do not look it up, read the field".
        flat: ?[]const u8 = null,
        flat_checked: bool = false,
    };

    pub const Hole = struct {
        directive: ?[]const u8,
    };

    pub const Situation = struct {
        subject: *const Node,
        branches: []const Branch,
    };

    pub const CaseExpr = struct {
        subject: *const Node,
        branches: []const Branch,
    };

    pub const Branch = struct {
        pattern: ?*const Node,
        guard: ?*const Node = null, // optional when guard
        body: []const Node,
        /// Set by the parser; a Branch built by hand is `.general`, which
        /// is the old path exactly.
        mode: Mode = .general,
        /// Whether taking the branch needs a scope of its own: its pattern
        /// binds a name, or something it evaluates may define one in the
        /// current scope (an assignment would otherwise leak into the
        /// enclosing frame).  Only read when `mode` is not `.general`.
        scoped: bool = true,

        pub const Mode = enum {
            general,
            /// `_ ->` whose body is not a lone hole.
            wild,
            /// `true ->` and `false ->`.
            is_true,
            is_false,
        };
    };

    /// Does matching this pattern bind a name?  Only the literal patterns
    /// are known not to.
    pub fn patternBinds(pattern: Node) bool {
        return switch (pattern.kind) {
            .integer_lit, .float_lit, .string_lit, .atom_lit, .bool_lit, .nil_lit, .hole => false,
            else => true,
        };
    }

    /// False only when evaluating `node` provably defines nothing in the
    /// current scope.  A whitelist: every kind not named here may define (an
    /// assignment, a def, a destructuring, a pipe's temporary), so a branch
    /// containing one keeps its scope.
    pub fn mayDefine(node: Node) bool {
        switch (node.kind) {
            .integer_lit, .float_lit, .string_lit, .atom_lit, .bool_lit, .nil_lit, .identifier => return false,
            .binary_op => |b| return mayDefine(b.left.*) or mayDefine(b.right.*),
            .unary_op => |u| return mayDefine(u.operand.*),
            .func_call => |c| {
                for (c.args) |a| if (mayDefine(a)) return true;
                return false;
            },
            .dot_access => |d| return mayDefine(d.object.*),
            .list_lit => |l| {
                for (l.elements) |e| if (mayDefine(e)) return true;
                if (l.tail) |t| return mayDefine(t.*);
                return false;
            },
            .tuple_lit => |t| {
                for (t.elements) |e| if (mayDefine(e)) return true;
                return false;
            },
            .case_expr => |c| return situationMayDefine(c.subject.*, c.branches),
            .situation => |c| return situationMayDefine(c.subject.*, c.branches),
            else => return true,
        }
    }

    fn situationMayDefine(subject: Node, branches: []const Branch) bool {
        if (mayDefine(subject)) return true;
        for (branches) |b| {
            if (b.guard) |g| if (mayDefine(g.*)) return true;
            for (b.body) |stmt| if (mayDefine(stmt)) return true;
        }
        return false;
    }

    pub const MessageSend = struct {
        target: *const Node,
        message: []const u8, // atom name without :
        args: []const Node,
        is_async: bool = false, // <-- (async) vs <- (sync)
    };

    pub const OrElseExpr = struct {
        try_expr: *const Node,
        fallback: *const Node,
    };

    pub const SpawnExpr = struct {
        actor_name: []const u8,
        overrides: []const KeyValue,
    };

    /// Try/catch: try do ... catch var do ... end
    pub const TryCatch = struct {
        try_body: []const Node,
        catch_var: ?[]const u8, // variable name for the error, or null
        catch_body: []const Node,
    };

    /// Struct literal: %Counter{count: 42}
    pub const StructLit = struct {
        type_name: []const u8,
        fields: []const KeyValue,
    };

    /// Range expression: 1..10
    pub const RangeExpr = struct {
        start: *const Node,
        end_val: *const Node,
    };

    /// Bubble statement: bubble or bubble reason: "msg"
    pub const BubbleStmt = struct {
        reason: ?*const Node, // optional reason expression
    };

    /// Named function definition: def name(params) do ... end
    pub const DefStmt = struct {
        name: []const u8,
        params: []const HandlerParam,
        return_type: ?[]const u8 = null, // -> Type
        body: []const Node,
    };

    /// Test block: test "name" do ... end
    pub const TestDef = struct {
        name: []const u8, // test description string
        body: []const Node,
    };

    /// Property test: property "name" do given x: gen ... assert ... end
    pub const PropertyDef = struct {
        name: []const u8, // property description
        body: []const Node, // contains given_stmt + assertions
    };

    /// given x: generator -- binds a generated value
    pub const GivenStmt = struct {
        name: []const u8, // variable name
        key: NameKey = .{},
        generator: *const Node, // generator expression (func_call)
        hint: ?*u32 = null,
    };

    /// For loop: for x in list do ... end
    pub const ForExpr = struct {
        var_name: []const u8,
        key: NameKey = .{},
        iterable: *const Node,
        body: []const Node,
    };

    /// Spread expression: ...list, fn (map) or ..list, fn (each)
    pub const SpreadExpr = struct {
        iterable: *const Node,
        func: *const Node,
    };

    /// Anonymous function: fn(x, y) do ... end
    pub const FnExpr = struct {
        params: []const HandlerParam,
        return_type: ?[]const u8 = null, // -> Type
        body: []const Node,
    };

    /// Calling an expression as a function: expr.(args) or just expr(args)
    pub const CallExpr = struct {
        callee: *const Node, // the expression being called
        args: []const Node,
    };

    /// Key-value pair for state, become, and map literals.
    /// For state declarations: key, optional type_name, optional default_value.
    /// For become/maps: key, value (type_name is null, default_value is null).
    pub const KeyValue = struct {
        key: []const u8,
        type_name: ?[]const u8 = null,
        value: Node,
        default_value: ?*const Node = null,
    };
};

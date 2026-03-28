const std = @import("std");

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
        type_name: ?[]const u8 = null, // null = untyped (legacy, checker will reject)
    };

    pub const BecomeStmt = struct {
        fields: []const KeyValue,
    };

    pub const ReplyStmt = struct {
        value: *const Node,
    };

    pub const AssignStmt = struct {
        name: []const u8,
        value: *const Node,
    };

    pub const IntegerLit = struct {
        value: i64,
    };

    pub const FloatLit = struct {
        value: f64,
    };

    pub const StringLit = struct {
        value: []const u8,
    };

    pub const AtomLit = struct {
        name: []const u8,
    };

    pub const BoolLit = struct {
        value: bool,
    };

    pub const Identifier = struct {
        name: []const u8,
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
        args: []const Node,
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
    };

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
        generator: *const Node, // generator expression (func_call)
    };

    /// For loop: for x in list do ... end
    pub const ForExpr = struct {
        var_name: []const u8,
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

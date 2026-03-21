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
        list_lit: ListLit,
        tuple_lit: TupleLit,
        map_lit: MapLit,
        dot_access: DotAccess,
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
        params: []const []const u8,
        body: []const Node,
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

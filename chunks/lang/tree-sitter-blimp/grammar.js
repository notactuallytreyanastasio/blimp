/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: "blimp",

  extras: ($) => [/\s/, $.comment],

  word: ($) => $.identifier,

  conflicts: ($) => [
    [$.spawn_expression],
  ],

  rules: {
    // Top level: a source file is a sequence of definitions and statements
    source_file: ($) => repeat($._definition),

    _definition: ($) =>
      choice(
        $.actor_definition,
        $.def_statement,
        $._statement,
      ),

    // ============================================================
    // Actor definition
    // ============================================================

    actor_definition: ($) =>
      seq("actor", $.actor_name, "do", repeat($._actor_body), "end"),

    // Actor names can be dotted: Shop, Shop.Checkout, Shop.Checkout.Tax
    actor_name: ($) =>
      prec.left(10, seq($.upper_identifier, repeat(seq(".", $.upper_identifier)))),

    _actor_body: ($) =>
      choice(
        $.state_definition,
        $.message_handler,
        $._statement,
      ),

    // ============================================================
    // State definition
    // ============================================================

    state_definition: ($) =>
      seq("state", $.typed_field_list),

    typed_field_list: ($) => commaSep1($.typed_field),

    typed_field: ($) =>
      choice(
        // name: Type :: default
        prec(2, seq($.identifier, ":", $.type_name, "::", $._expression)),
        // name: Type (no default)
        prec(1, seq($.identifier, ":", $.type_name)),
        // name: value (untyped, backwards compat)
        seq($.identifier, ":", $._expression),
      ),

    type_name: ($) =>
      prec(10, choice(
        $.upper_identifier,
        seq("[", $.type_name, "]"),                           // [Item], [Int]
        seq("{", commaSep1($.type_name), "}"),                // {Atom, Int}
        seq("%", "{", $.type_name, "=>", $.type_name, "}"),   // %{String => Int}
      )),

    // ============================================================
    // Message handler
    // ============================================================

    message_handler: ($) =>
      seq(
        "on",
        $.atom,
        optional($.parameter_list),
        optional($.return_type),
        optional($.when_guard),
        optional($.bubbles_annotation),
        "do",
        repeat($._statement),
        "end",
      ),

    when_guard: ($) => seq("when", $._expression),

    bubbles_annotation: ($) => seq("bubbles", "(", $.upper_identifier, ")"),

    return_type: ($) => seq("->", $.type_name),

    parameter_list: ($) =>
      seq("(", commaSep1($.handler_param), ")"),

    handler_param: ($) =>
      choice(
        seq($.identifier, ":", $.type_name),  // typed: name: Type
        $.identifier,                          // untyped (legacy, checker rejects)
      ),

    // ============================================================
    // Named function definition: def name(params) do ... end
    // ============================================================

    def_statement: ($) =>
      seq(
        "def",
        $.identifier,
        "(", commaSep($.identifier), ")",
        "do",
        repeat($._statement),
        "end",
      ),

    // ============================================================
    // Statements
    // ============================================================

    _statement: ($) =>
      choice(
        $.become_statement,
        $.reply_statement,
        $.bubble_statement,
        $.situation_expression,
        $.case_expression,
        $.for_expression,
        $.assignment,
        $._expression,
      ),

    become_statement: ($) => seq("become", $.key_value_list),

    reply_statement: ($) => seq("reply", $._expression),

    bubble_statement: ($) =>
      prec.right(0, choice(
        seq("bubble", $.atom),          // bubble :reason (atom only)
        seq("bubble", $.string),        // bubble "reason message"
        "bubble",                       // bubble (no reason)
      )),

    assignment: ($) => seq($.identifier, "=", $._expression),

    // ============================================================
    // For loop: for x in expr do ... end
    // ============================================================

    for_expression: ($) =>
      seq("for", $.identifier, "in", $._expression, "do", repeat($._statement), "end"),

    // ============================================================
    // Expressions
    // ============================================================

    _expression: ($) =>
      choice(
        $.orelse_expression,
        $.pipe_expression,
        $.message_send,
        $.spread_map,
        $.spread_each,
        $.concat_expression,
        $.binary_expression,
        $._unary_expression,
      ),

    orelse_expression: ($) =>
      prec.right(0, seq($._expression, "orelse", $._expression)),

    pipe_expression: ($) =>
      prec.left(0, seq($._expression, "|>", $._expression)),

    // ...list, fn  (map)
    spread_map: ($) =>
      prec.right(8, seq("...", $._expression, ",", $._expression)),

    // ..list, fn  (each)
    spread_each: ($) =>
      prec.right(8, seq("..", $._expression, ",", $._expression)),

    message_send: ($) =>
      choice(
        prec.left(1, seq(
          $._expression,
          token(prec(10, "<-")),
          $.atom,
          "(",
          commaSep($._expression),
          ")",
        )),
        prec.left(0, seq(
          $._expression,
          token(prec(10, "<-")),
          $.atom,
        )),
      ),

    // ++ for list/string concatenation
    concat_expression: ($) =>
      prec.left(4, seq($._expression, "++", $._expression)),

    binary_expression: ($) =>
      choice(
        // Precedence from lowest to highest
        prec.left(1, seq($._expression, "||", $._expression)),
        prec.left(2, seq($._expression, "&&", $._expression)),
        prec.left(3, seq($._expression, choice("==", "!=", "<", ">", "<=", ">="), $._expression)),
        prec.left(4, seq($._expression, choice("+", "-"), $._expression)),
        prec.left(5, seq($._expression, choice("*", "/"), $._expression)),
      ),

    _unary_expression: ($) => choice($.unary_expression, $._postfix_expression),

    unary_expression: ($) =>
      choice(
        prec(6, seq("-", $._postfix_expression)),
        prec(6, seq("!", $._postfix_expression)),
      ),

    _postfix_expression: ($) => choice($.dot_access, $.function_call, $._primary),

    dot_access: ($) => prec.left(7, seq($._postfix_expression, ".", $.identifier)),

    function_call: ($) =>
      prec(7, seq($.identifier, "(", commaSep($._expression), ")")),

    // ============================================================
    // Primary expressions
    // ============================================================

    _primary: ($) =>
      choice(
        $.spawn_expression,
        $.fn_expression,
        $.self_ref,
        $.integer,
        $.float,
        $.string,
        $.atom,
        $.boolean,
        $.nil,
        $.hole,
        $.identifier,
        $.upper_identifier,
        $.list,
        $.tuple,
        $.map,
        $.parenthesized_expression,
      ),

    // spawn Counter or spawn Shop.Checkout or spawn Counter(count: 10)
    spawn_expression: ($) =>
      choice(
        prec(12, seq("spawn", $.spawn_target, "(", $.key_value_list, ")")),
        prec(12, seq("spawn", $.spawn_target)),
      ),

    // Spawn target greedily consumes dot notation: Shop.Checkout
    spawn_target: ($) =>
      prec.left(15, seq($.upper_identifier, repeat(seq(".", $.upper_identifier)))),

    // fn(x, y) do ... end
    fn_expression: ($) =>
      seq("fn", "(", commaSep($.identifier), ")", "do", repeat($._statement), "end"),

    // self reference inside handler
    self_ref: (_) => "self",

    parenthesized_expression: ($) => seq("(", $._expression, ")"),

    // ============================================================
    // Collection literals
    // ============================================================

    list: ($) =>
      seq(
        "[",
        choice(
          // Empty list
          seq(),
          // Regular list: [a, b, c]
          commaSep1($._expression),
          // Cons list: [head | tail]
          seq(commaSep1($._expression), "|", $._expression),
        ),
        "]",
      ),

    tuple: ($) => seq("{", commaSep($._expression), "}"),

    map: ($) => seq("%", "{", commaSep($.key_value_pair), "}"),

    // ============================================================
    // Situation expression (pattern matching)
    // ============================================================

    situation_expression: ($) =>
      seq("situation", $._expression, "do", repeat1($.situation_branch), "end"),

    situation_branch: ($) =>
      prec(8, seq(choice($.hole, $._expression), "->", repeat1($._statement))),

    // ============================================================
    // Case expression (exhaustive pattern matching)
    // ============================================================

    case_expression: ($) =>
      seq("case", $._expression, "do", repeat1($.case_branch), "end"),

    case_branch: ($) =>
      prec(8, seq(choice($.hole, $._expression), "->", repeat1($._statement))),

    // ============================================================
    // Hole (wildcard/identity)
    // ============================================================

    hole: (_) => "_",

    // ============================================================
    // Key-value pairs (used by state, become, map)
    // ============================================================

    key_value_list: ($) => commaSep1($.key_value_pair),

    key_value_pair: ($) => seq($.identifier, ":", $._expression),

    // ============================================================
    // Terminals
    // ============================================================

    integer: (_) => /\d+/,

    float: (_) => /\d+\.\d+/,

    string: (_) => seq('"', /[^"\\]*(?:\\.[^"\\]*)*/, '"'),

    atom: (_) => /:[a-zA-Z_][a-zA-Z0-9_]*[?!]?/,

    boolean: (_) => choice("true", "false"),

    nil: (_) => "nil",

    identifier: (_) => /[a-z_][a-zA-Z0-9_]*[?!]?/,

    upper_identifier: (_) => /[A-Z][a-zA-Z0-9_]*/,

    comment: (_) => /#[^\n]*/,
  },
});

// Helper: comma-separated list (0 or more)
function commaSep(rule) {
  return optional(commaSep1(rule));
}

// Helper: comma-separated list (1 or more)
function commaSep1(rule) {
  return seq(rule, repeat(seq(",", rule)));
}

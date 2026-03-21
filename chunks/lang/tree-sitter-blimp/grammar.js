/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: "blimp",

  extras: ($) => [/\s/, $.comment],

  word: ($) => $.identifier,

  conflicts: () => [],

  rules: {
    // Top level: a source file is a sequence of definitions
    source_file: ($) => repeat($._definition),

    _definition: ($) => choice($.actor_definition),

    // ============================================================
    // Actor definition
    // ============================================================

    actor_definition: ($) =>
      seq("actor", $.upper_identifier, "do", repeat($._actor_body), "end"),

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
        seq("[", $.upper_identifier, "]"),  // [Item]
      )),

    // ============================================================
    // Message handler
    // ============================================================

    message_handler: ($) =>
      seq(
        "on",
        $.atom,
        optional($.parameter_list),
        "do",
        repeat($._statement),
        "end",
      ),

    parameter_list: ($) =>
      seq("(", commaSep1($.identifier), ")"),

    // ============================================================
    // Statements
    // ============================================================

    _statement: ($) =>
      choice(
        $.become_statement,
        $.reply_statement,
        $.situation_expression,
        $.assignment,
        $._expression,
      ),

    become_statement: ($) => seq("become", $.key_value_list),

    reply_statement: ($) => seq("reply", $._expression),

    assignment: ($) => seq($.identifier, "=", $._expression),

    // ============================================================
    // Expressions
    // ============================================================

    _expression: ($) => choice($.pipe_expression, $.binary_expression, $._unary_expression),

    pipe_expression: ($) =>
      prec.left(0, seq($._expression, "|>", $._expression)),

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

// External scanner for tree-sitter-blimp: the tokens whose meaning depends
// on whether a newline comes before them.
//
// parser.zig's lexer emits newline tokens, and its infix loops (parseAddSub,
// parsePipe, the call check in parsePrimary, the send-argument check in
// parseSendExpr) look at the very next token without skipping them. So an
// operator at the start of a line never continues the line above:
//
//   x          two statements: x, then -1
//   -1
//
//   f          two statements: f, then (1)
//   (1)
//
// The grammar ignores whitespace, so without this scanner tree-sitter read
// both as one expression (x - 1, f(1)) and reported no error. Each token
// here is the infix reading of its character, and the scanner gives it only
// when no newline was skipped on the way to it. When there was one it
// returns false, and the internal lexer reads the character as whatever
// else it can be: `-` as unary minus, `(` as an opening parenthesis, and
// `|>` as nothing at all, which is an ERROR, as it is in the interpreter.
//
// SAME_LINE is zero-width. It stands between `bubble` or `reply` and its
// operand, which parser.zig only takes from the same line (parseBubbleStmt
// checks for the newline; parseReplyStmt fails on it).

#include "tree_sitter/parser.h"

#include <stdbool.h>

enum TokenType {
  BINARY_MINUS,
  CALL_PAREN,
  PIPE_ARROW,
  SAME_LINE,
  ERROR_SENTINEL,
};

void *tree_sitter_blimp_external_scanner_create(void) { return NULL; }
void tree_sitter_blimp_external_scanner_destroy(void *payload) { (void)payload; }
unsigned tree_sitter_blimp_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0;
}
void tree_sitter_blimp_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

static bool is_word_char(int32_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
         c == '?' || c == '!';
}

bool tree_sitter_blimp_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  (void)payload;

  // During error recovery every symbol is valid. None of these tokens is
  // ever needed to recover, and offering them there only makes the
  // recovery stranger.
  if (valid_symbols[ERROR_SENTINEL]) return false;

  bool newline = false;
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' || lexer->lookahead == '\r' ||
         lexer->lookahead == '\n') {
    if (lexer->lookahead == '\n') newline = true;
    lexer->advance(lexer, true);
  }
  if (newline) return false;

  if (valid_symbols[SAME_LINE]) {
    lexer->mark_end(lexer);
    if (lexer->eof(lexer) || lexer->lookahead == '#') return false;
    // `bubble end`: parseBubbleStmt takes no reason when `end` follows.
    if (lexer->lookahead == 'e') {
      lexer->advance(lexer, false);
      if (lexer->lookahead == 'n') {
        lexer->advance(lexer, false);
        if (lexer->lookahead == 'd') {
          lexer->advance(lexer, false);
          if (!is_word_char(lexer->lookahead)) return false;
        }
      }
    }
    lexer->result_symbol = SAME_LINE;
    return true;
  }

  switch (lexer->lookahead) {
    case '-':
      if (!valid_symbols[BINARY_MINUS]) return false;
      lexer->advance(lexer, false);
      if (lexer->lookahead == '>') return false;  // `->`
      lexer->mark_end(lexer);
      lexer->result_symbol = BINARY_MINUS;
      return true;
    case '(':
      if (!valid_symbols[CALL_PAREN]) return false;
      lexer->advance(lexer, false);
      lexer->mark_end(lexer);
      lexer->result_symbol = CALL_PAREN;
      return true;
    case '|':
      if (!valid_symbols[PIPE_ARROW]) return false;
      lexer->advance(lexer, false);
      if (lexer->lookahead != '>') return false;  // `|` or `||`
      lexer->advance(lexer, false);
      lexer->mark_end(lexer);
      lexer->result_symbol = PIPE_ARROW;
      return true;
    default:
      return false;
  }
}

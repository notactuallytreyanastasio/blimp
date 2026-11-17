# Two parsers, one answer per file

*November 16, 2026*

Blimp has two parsers. parser.zig is the one that runs programs. The tree-sitter grammar in `chunks/lang/tree-sitter-blimp` is the one your editor uses to colour them. Until this branch nobody had checked them against each other, and the check turned up two kinds of disagreement. The loud kind is a file the interpreter runs and tree-sitter marks with an ERROR node. The quiet kind is a file both accept and read differently.

The quiet kind first, because it is worse. `test/diff/corpus/arith_negate.blimp` is two lines:

```blimp
x = 5
-x
```

The interpreter reads `(= x 5)` and then `(negate x)`. tree-sitter on the parent branch read this:

```
(source_file
  (assignment
    (identifier)
    (binary_expression
      (integer)
      (identifier))))
```

That is `x = 5 - x`, with no ERROR anywhere, so an editor showed no squiggle and no check in the repository flagged it.

## How far apart they were

The loud kind is easy to count. We ran the parent's grammar over the 230 `.blimp` files tracked on this branch:

```
Total parses: 230; successful parses: 134; failed parses: 96; success percentage: 58.26%
```

The interpreter parses 93 of those 96. On this branch:

```
Total parses: 230; successful parses: 227; failed parses: 3; success percentage: 98.70%
```

and the three left are `examples/bank_account.blimp`, `examples/checkout.blimp` and `examples/errors/05_js_triple_equals.blimp`, which the interpreter refuses too.

Most of the misses were ordinary forms. A typed `def`, which is the only kind the checker accepts, came back with two ERROR nodes (chapter 70 ended on that). `spawn Account, balance: 1000` was an ERROR at the comma. `spawn Shop.Checkout` stopped at the dot, because `spawn_target` was `prec.left`, and left associativity settles a shift/reduce conflict by reducing. `and` and `or` were not in the grammar at all, so every `when x < 0 or x > 9` in the Tetris exercises broke.

## Files that looked fine

The string rule was a `seq` of a quote, a body and a quote. tree-sitter applies its extras, whitespace and comments, between the parts of a `seq`, so in `"#{a}"` the `#` after the opening quote started a comment that ran to the end of the line, taking the closing quote with it. The string then ended at the next quote in the file. Given

```blimp
x = "#{a}"
y = "a # b"
z = 1
```

the parent produced `(assignment (identifier) (string (comment)))`, a loose `(identifier)`, a `(comment)`, and the `z` assignment, and no ERROR. `y` had lost its assignment. The string is now a single `token(...)`, so nothing can be lexed inside it.

`test "name" do ... end` had no rule either. tree-sitter read `test` as a name, the string as a string, and `do` as another name, and then the test's `end` closed the enclosing actor. We compared every tracked file's tree before and after the commit that added the rule: 44 files changed with no ERROR on either side. Those 44 files hold 1167 test blocks, and all of them had been read as something else.

Then there was the keyword problem. `examples/bank_account.blimp` has

```blimp
target <- :deposit(amount) orelse bubble
```

which the interpreter refuses at line 50, column 39, because `bubble` is a statement and cannot be orelse's fallback. tree-sitter gave it a clean tree, an orelse whose right side is a variable called `bubble`. With `word: $.identifier`, tree-sitter will lex a keyword as a name wherever the keyword itself is not valid. The grammar now reserves the exact list in `Token.keyword` in `src/token.zig`, using the `reserved` field that the 0.25 CLI supports.

## Newlines

The `-x` bug is about whitespace. parser.zig's lexer emits newline tokens, and its infix loops look at the next token without skipping them, so an operator at the start of a line never continues the line above. tree-sitter grammars ignore whitespace.

A precedence in `grammar.js` that preferred two statements for `-` looks like the fix, and would have been wrong. `case 1 do _ -> 3 end - 1` on one line is a subtraction to parser.zig, and chapter 74 made it one. The newline is the only difference between that and the two-statement version, and `grammar.js` cannot see newlines. So this branch adds an external scanner, `src/scanner.c`, which hands out the infix reading of `-`, `(` and `|>` only when no newline came before them. Every input in the new `test/corpus/newlines.txt` was run through `blimp FILE --ast` first:

```
x = 5~-x        (= x 5)  (negate x)
x -1            (sub x 1)
f~(1)           f  1
print (1)       (print 1)
x~|> print(_)   Parse error: error.UnexpectedToken at line 2, col 1
```

(`~` is a newline.) The same scanner keeps `bubble` and `reply` on their operand's line, which reversed two readings on the parent: `bubble` followed by `:later` on the next line had been a bubble with reason `:later`, and `bubble why` had been a bubble and a separate `why`.

## Keeping them together

`tree-sitter-blimp/scripts/disagreements.sh` runs both parsers over every tracked file and prints each file one accepts and the other refuses. Against each commit's grammar in turn it printed 93, 93, 59, 47, 43, 42, 35, 18, 13, 11, 5, 1 and 0 lines. Laid on top of chapters 70 to 81, it failed on a file chapter 78 added, `0 - 9223372036854775808`. No grammar can tell 2^63 from 2^63 - 1, so that refusal is about range. The next commit leaves out the two out-of-range messages by their text and puts the script in `make check`:

```
-- tree-sitter test: ok
-- tree-sitter and parser.zig accept the same files: ok
```

Our first run of that `make check` failed with three `ts-clean` lines, the same three that `TREE_SITTER=false` produces. tree-sitter had printed nothing, its stderr went to `/dev/null`, and the script took the silence to mean no file had an ERROR. With no file refused by the interpreter, that would have been a pass. The last commit counts what tree-sitter parsed:

```
$ TREE_SITTER=false sh tree-sitter-blimp/scripts/disagreements.sh; echo $?
tree-sitter parsed 0 of 230 files; nothing was compared. Its stderr:
2
```

We made the failure happen again by running tree-sitter several times at once, which is likely what happened the first time but not proven. Four `tree-sitter parse` runs started together, each with its own fresh `TREE_SITTER_LIBDIR`, gave one success and three `Error opening dynamic library .../lib/blimp.dylib`. A private libdir does not stop concurrent CLIs from breaking each other's build of the parser, so two `make check` runs in different checkouts can still fail. Now the failure says that tree-sitter did not run.

One commit message is wrong about its own alternative. It says `token(prec(10, choice("<-", "<--")))` would silently stop `"<-" @operator` from matching. We built it, and `tree-sitter test` exits 1 with `Query error at 75:2. Invalid node type <-`. Two named tokens are still the right fix, since one token over a choice leaves no `"<-"` node to name.

## What still differs

The script only catches the loud kind, and none of these are in a tracked file:

- A line that starts with `+` or another operator that cannot begin an expression is a parse error in the interpreter and a continuation in tree-sitter. So is a trailing `-`.
- `def f(n: Int) -> [Int] do n end` is clean here and an error at column 18 in the interpreter, whose `def` takes only one upper-case name after `->`.
- `actor A do x = 1 end` is refused by the interpreter and accepted by the grammar.
- In a branch body, a line that starts with an atom ends the body for parser.zig and does not for tree-sitter.

For the quiet kind there is no automatic check yet, because `blimp --ast` prints `???` for def, case and bubble, so there is no interpreter tree to compare against.

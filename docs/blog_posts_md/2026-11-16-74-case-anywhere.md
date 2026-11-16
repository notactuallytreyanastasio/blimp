# A case that goes anywhere an expression goes

*November 16, 2026*

Until this branch, parser.zig accepted `case` and `situation` in three places: as a statement, as a branch body, and on the right of `x =`, which commit a496725 patched in as a special case back in March. Anywhere else the parser stopped. If you wanted to reply with a case, you got this:

```
Parse error: error.UnexpectedToken at line 6, col 11
```

The workaround was to bind the case to a temporary first. `try`, `for` and `fn` never had the restriction, because they were in `parsePrimary` all along.

On the `05-case-anywhere` branch, this program runs:

```blimp
actor Counter do
  state n: Int :: 0

  on :bump(by: Int) do
    become n: n + by
    reply case n + by do
      1 -> :first
      _ -> :more
    end
  end
end

c = spawn Counter
print(c <- :bump(1))
print(c <- :bump(2))
print([0, case 2 do 1 -> 10 _ -> 20 end, 3])
print(1 + case 1 do 1 -> 10 _ -> 20 end * 2)
y = case 1 do 1 -> 10 _ -> 20 end + 1
print(y)
```

```
:first
:more
[0, 20, 3]
21
11
```

The parent branch fails on line 6, the `reply case`. The `1 + case ... end * 2` line gives 21 because a case binds like any other primary, so the `* 2` multiplies the whole case and the addition comes last.

## The minus sign

Every one of those positions was a loud failure before, except one. The assignment special case returned as soon as it reached `end`, and parser.zig treats a leading `-` as a negation that can start a new statement. So this parsed on the old build:

```blimp
z = case 1 do _ -> 3 end - 1
print(z)

def h() do
  case 1 do _ -> 10 end - 1
end
print(h())
```

The old build prints `3` and `-1`: it assigned 3 to `z` and then evaluated `-1` on its own, and `h` returned that `-1` because it was the last statement. This branch prints `2` and `9`. With `+ 1` in the same spot, the old parser at least said `UnexpectedToken`. With `- 1` it printed a wrong number and kept going. The first commit's message says nothing that parsed before parses differently, which is true for the 105 `.blimp` files in the repo. These two lines sit outside that set, and parsing them differently is the point.

## Why the restriction was there

The first commit found no syntactic ambiguity behind the restriction. Both forms close with `end`, so a case in operand position can't run on into whatever follows. The obstacle was parse time. The parser tries every line of a branch body as a pattern first (`looksLikeBranch`), to see whether it starts the next branch. If the line starts with a block, that trial parses the whole block, and the block's own body lines run their own trials. Nesting d deep costs 2^d parses. `for` already paid this on main, and we measured it on both builds with `case x do _ -> for v in [1] do` nested d deep:

```
depth   before                               after
18      0.20s                                0.00s
20      0.79s                                0.00s
40      1.69s, then error.OutOfMemory        0.00s
```

Making case a primary would have put every nested case on that curve as well. The fix is a short check at the top of `looksLikeBranch`: a line that starts with `case`, `situation`, `for`, `fn` or `try` can't be a pattern, so the parser skips the trial for it.

## The first version was slower

The first commit made a statement that starts with `case` go through the general expression parser, which means about ten nested calls down to `parsePrimary` and back up, all for the rare case followed by `+ 1`. The second commit measured that on a 217,801-line file with 26,700 statement-level cases: 75.8ms on origin/main, 77.0ms after the first commit, 74.6ms after the second. That's about 67ns per case. Those numbers come from the commit message; rerunning the same file on this stack, before against after, we got medians of 76.4ms and 76.2ms.

The second commit parses a statement-level case on its own and hands it back at `end`, unless the next token is one that continues an expression (`.`, an infix operator, a send, `|>`, `orelse`). Then the finished node goes to the expression parser as its first operand, so the parser never reads the case twice.

The tempting version saves the lexer, parses the case, and on seeing an operator rewinds and parses the whole thing again as an expression. Nest the cases and each rewind of the outer case re-parses every inner case that also had an operator after it, which is 2^depth again. A test nests 40 of them, each followed by `+ 1`, so a regression shows up as a test that never finishes.

## Where tree-sitter now disagrees

The tree-sitter grammar was narrower than parser.zig: even `r = case a do _ -> 1 end` came out as an ERROR. With case, situation and for moved into `_primary`, all 68 case and situation probes from the interpreter matrix parse without an ERROR or MISSING node, where 56 were ERROR before.

The grammar ignores whitespace, and parser.zig does not. Give both of them this:

```blimp
def g() do
  case 1 do _ -> 10 end
  -1
end
print(g())
```

The interpreter prints `-1`, because parser.zig sees two statements in the body and the second is the negation. tree-sitter on this branch reads the body as one subtraction:

```
(def_statement
  (identifier)
  (binary_expression
    (case_expression (integer) (case_branch (hole) (integer)))
    (integer)))
```

On the parent branch it gave `(case_expression ...)` followed by `(unary_expression (integer))`, the same reading as the interpreter, but only because a case could not be an operand there at all.

A grammar-level preference for the two-statement reading would break the one-line `case ... end - 1`, which parser.zig does read as a subtraction, because tree-sitter can't see the newline that tells them apart. The commit names the fix, an external scanner that makes infix `-` newline-aware for every expression, and leaves it unwritten. tree-sitter already read `x` followed by a line `-1` as `x - 1` before this branch, so case is the newest form with the bug, and tree-sitter reports no ERROR node for any of them.

## The self-hosted parser had it all along

`lib/parser.blimp` has had case in `parse_primary` since it was written. Three new bootstrap tests pin that down. A fourth pins that situation is still missing from it, on purpose, and all four pass on the old interpreter too. Adding it would give `lib/codegen.blimp` a node kind it doesn't handle, and its `compile_node` ends like this:

```blimp
    _ ->
  # Unsupported node: return 0
  [op_i32_const(), 0]
```

A situation would compile to the constant 0 without a word. For now the self-hosted parser refuses it with `unexpected token: kw_situation`, and Blimp has no raise to replace that fallback with yet.

`make check` passes on the branch, with 17 new tests in `test/case_anywhere_test.blimp` and 8 in the tree-sitter corpus.

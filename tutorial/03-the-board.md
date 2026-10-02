# Chapter 3: The board

The whole game rests on one question: do these four cells fit?
By the end of this chapter `Tetris.Board` answers it, and remembers every piece that has landed.

## A grid is a list of rows

The well is 10 columns by 20 rows.
The Board keeps it as a list of 20 rows, each a list of 10 numbers: `0` for empty, `1` to `7` for a square left behind by a piece of that kind, so the Screen can colour it later.
Open `exercises/ch03_board/01_board.blimp`; the Shapes and Piece from chapter 2 are at the top, finished, and the Board is below them:

```blimp
actor Tetris.Board do
  state rows: List :: for y in range(1, 20) do for x in range(1, 10) do 0 end end

  on :rows do reply rows end
```

That default is chapter 2's `for` again: the inner `for` makes one row of ten zeros, the outer one makes twenty of those.
Smaller, so you can see it:

```blimp
print(for y in range(1, 2) do for x in range(1, 3) do 0 end end)
```

```
[[0, 0, 0], [0, 0, 0]]
```

A cell is found row first: `elem(elem(rows, y), x)`.
`y` counts down from the top (row 0) to the floor (row 19), and `x` from the left wall (column 0) to the right (column 9).
The Piece already speaks in these coordinates; a T at spawn covers `{4, 0}, {3, 1}, {4, 1}, {5, 1}`.

You saw in chapter 2 that a state default runs once, when the actor is defined, so every Board starts from the same list.
That is harmless here, because a list is a value and nobody can change it.
A Board that locks a piece `become`s a new list, and the other Boards keep the old one:

```blimp
b1 = spawn Tetris.Board
b2 = spawn Tetris.Board
b1 <- :lock([{0, 19}], 5)
print(elem(elem(b1 <- :rows, 19), 0))
print(elem(elem(b2 <- :rows, 19), 0))
```

```
5
0
```

"starts as 20 rows of 10 zeros" is green before you write anything, since `:rows` and the default are given.

## Why the obvious `:blocked?` is wrong

A cell is blocked when there is something in it.
The one-line version is:

```blimp
on :blocked?(x: Int, y: Int) do reply elem(elem(rows, y), x) != 0 end
```

Here is what it says about the four edges of the well, on an empty board:

```blimp
print(b <- :blocked?(-1, 5))    # left of the left wall
print(b <- :blocked?(10, 5))    # right of the right wall
print(b <- :blocked?(4, -1))    # above the top
print(b <- :blocked?(4, 20))    # below the floor
```

```
false
true
false

-- RUNTIME ERROR ─────────────────────────────────

  TypeError while evaluating this.

3|   on :blocked?(x: Int, y: Int) do reply elem(elem(rows, y), x) != 0 end
                                             ^
```

Every one of those is wrong or right by accident, and the reason is `elem` from chapter 2.
A negative position gives the first element, so column -1 reads column 0: the left wall is invisible whenever column 0 is empty, and pieces slide out of the well.
A position past the end gives `nil`, and `nil != 0` is true, so the right wall works, but only by luck.
Row -1 reads row 0, so a cell above the top is as blocked as whatever sits in the top row.
Row 20 is `nil`, and taking column 4 of `nil` crashes, so the floor is a crash instead of a wall.

The well has edges, and `elem` does not know about them.
The Board has to say what they mean before it ever looks inside the list.

## Several clauses, tried in order

You can write `on :blocked?` more than once, and add a guard to a clause with `when`:

```blimp
on :blocked?(x: Int, y: Int) when x < 0 or x > 9 or y > 19 do reply :TODO end
on :blocked?(x: Int, y: Int) when y < 0 do reply :TODO end
on :blocked?(x: Int, y: Int) do reply :TODO end
```

When `:blocked?` arrives, Blimp tries the clauses top to bottom and runs the first whose guard is true.
A clause with no `when` always matches, so it goes last as the catch-all.
If you have written Erlang or Elixir function heads, this is the same thing.

The guard can use the message's arguments and the actor's state, and it can call builtins: `when elem(elem(rows, 0), x) != 0` is a legal guard.
Do not lean on `or` and `and` stopping early. The native `blimp` short-circuits them, so `true or (1 / 0 == 1)` is `true`; the browser build that runs the Play tab evaluates both sides and stops with `DIVISION BY ZERO`. A single guard like `when x >= 0 and elem(elem(rows, y), x) != 0` would pass `--test` on your machine and misbehave in the page. Separate clauses work the same in both.
If no clause matches at all, the send fails loudly with `NO MATCHING HANDLER` rather than replying something plausible, which is why the catch-all matters.

Putting the edges in the dispatch means the third clause only ever sees a cell that is really inside the well, and it can use `elem` without worrying.

### Order is part of the meaning

The three rules are: walls and floor are blocked, above the top is open, inside depends on the cell.

The middle rule needs a word, because in this game nothing ever goes above the top.
Pieces spawn in row 0, every offset in the shape table is 0 or more, and every move is sideways or down.
Most Tetris games spawn pieces partly above the visible well, though, and it is one of the easier changes to try once yours works.
One clause now makes the Board ready for that, and it is where the order of clauses starts to matter.

Swap the first two clauses and ask about a cell that is both left of the wall and above the top:

```blimp
on :blocked?(x: Int, y: Int) when y < 0 do reply false end
on :blocked?(x: Int, y: Int) when x < 0 or x > 9 or y > 19 do reply true end
```

```blimp
print(b <- :blocked?(-1, -1))    # => false
print(b <- :blocked?(-1, 3))     # => true
```

The wall stops at the top of the well, and a piece spawned up against it could hang one cell outside it.
First match wins, so the walls must be checked before the sky.

## Step 1: `:blocked?`

**Your task:** fill in the three clauses.
The first replies `true`, the second `false`, the third compares the cell with `0`.
Each is one short line; the stub keeps them on one line apiece, `on ... do reply ... end`, and that is fine.

## Step 2: `:fits?`

`:fits?(cells)` takes a list of `{x, y}` tuples, usually straight from `piece <- :cells_for(...)`, and replies `true` when none of them is blocked.
Two new builtins do the work.

`filter(list, f)` keeps the elements for which `f` returns true:

```blimp
filter([1, 5, 2, 8], fn(n: Int) do n > 3 end)    # => [5, 8]
```

`empty?(list)` is true for `[]` and false for anything longer.

So: filter the cells down to the blocked ones, and the piece fits when that list is empty.
The test for each cell is a question the Board already knows how to answer, so ask yourself, as the Piece did in chapter 2: inside the `fn`, `case` the tuple open into `{x, y}` and send `self <- :blocked?(x, y)`.

Why not write the bounds checks again inside `:fits?`?
Because then the rules of the well live in two places.
Every other question about the board (the ghost piece, the hard drop, wall kicks) comes through `:fits?`, and `:fits?` comes through `:blocked?`, so the three clauses you just wrote are the only place the edges are defined.

**Your task:** fill in `:fits?`.
"fits inside, above the top, but not through the walls or floor" and "a piece fits where it spawns, and not through the floor" should go green.
The second one uses a real Piece: a T moved down 18 rows fits, and 19 rows puts its bottom in row 20.

## Step 3: `:lock`

When a piece lands, the Board writes its kind into each of its cells.
`:lock(cells, colour)` does that and replies `:ok`.
This is the first handler where the new state is built from a list rather than handed in, and it needs two more builtins.

### `set_at` returns a new list

`set_at(list, i, value)` gives back a copy of the list with position `i` replaced.
The original is untouched:

```blimp
row = [0, 0, 0]
row2 = set_at(row, 1, 7)
print(row)
print(row2)
```

```
[0, 0, 0]
[0, 7, 0]
```

To change one cell of a grid you replace the cell in its row, then replace the row in the grid:

```blimp
grid = [[0, 0, 0], [0, 0, 0]]
print(set_at(grid, 1, set_at(elem(grid, 1), 2, 7)))
```

```
[[0, 0, 0], [0, 0, 7]]
```

`set_at` past the end is a `TypeError`.
`set_at` at a negative position is not: `set_at([0, 0, 0], -1, 9)` is `[9, 0, 0]`, the same first-element rule as `elem`.
That is why `:lock` has to skip cells above the top itself.
A piece that locks with a cell at `{5, -1}` would otherwise paint a square into row 0, column 5, where nothing ever was.

### `reduce` carries a value through a list

You have four cells and one grid, and each cell changes the grid.
`reduce(list, start, f)` calls `f(acc, element)` for each element in turn, passing each call's result to the next, and gives back the last one:

```blimp
reduce([1, 2, 3], 100, fn(acc: Int, n: Int) do acc + n end)    # => 106
```

Start with `rows`, and for each cell return the grid with that cell painted.
What comes out the end is the new grid, and one `become rows: ...` commits it.

### Choosing without `if`

Blimp has no `if`; `if 1 < 2 do ... end` is a parse error.
To choose between two results, `case` on the boolean:

```blimp
y = -1
what = case y < 0 do
  true -> :skip
  _ -> :paint
end
print(what)
```

```
:skip
```

`_` matches anything, so it is the "otherwise" clause.
Inside the `reduce`'s `fn`, a cell above the top returns `acc` unchanged, and any other cell returns `acc` with the cell set to `colour`.

**Your task:** fill in `:lock`.
"lock fills cells and blocks them" and "lock ignores cells above the top" should go green, which is all five.
The second one locks a cell above the top and checks that row 0 has not been painted where that cell would have landed.

## The exercise

`exercises/ch03_board/01_board.blimp`, five handler bodies on `Tetris.Board`:

- the three `:blocked?` clauses, which decide the edges of the well;
- `:fits?`, which is `filter` and `empty?` over `self <- :blocked?`;
- `:lock`, which is `reduce` and `set_at` over the cells, skipping any above the top, then one `become`.

The tests check a fresh board is 20 rows of 10 zeros, that cells fit inside and above the top but not through either wall or the floor, that locking fills cells and blocks them afterwards, that locking ignores cells above the top, and that a real T piece fits where it spawns and not one row too low.
Run them with Run Tests, or `blimp exercises/ch03_board/01_board.blimp --test`.

## What you learned

A grid is a list of lists, built with nested `for` and read with nested `elem`.
A handler can have several clauses with `when` guards, tried in order; the first match wins and a missing match is a loud error, so edge cases belong in the dispatch, ahead of the code that would get them silently wrong.
`filter` and `empty?` turn "none of these is blocked" into one expression.
Nothing is changed in place: `set_at` returns a new list, `reduce` threads the grid through each cell, and the handler `become`s the result once.
Blimp has no `if`; a `case` on `true` and `_` does the job.

The Board fills up, and nothing ever empties it.
[Chapter 4](#ch04) clears full lines and starts keeping score.

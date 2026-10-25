# Chapter 4: Lines and score

By the end of this chapter a full row disappears and everything above it falls, and a new actor, `Tetris.Score`, keeps the points, the line count and the level.
It also answers the question the whole game's speed hangs on: how many milliseconds until the piece drops another row.

Open `exercises/ch04_lines_and_score/01_score.blimp`.
The Board from Chapter 3 is at the top of "This chapter", with one new handler, `:sweep`, stubbed.
Below it is `Tetris.Score`, with four handlers stubbed.

## Sweep by keeping, not by removing

The obvious way to clear lines is a loop.
Walk the rows from the bottom up, and when a row is full, delete it and shift everything above it down one.
That version has a bug every Tetris programmer has written once.
When row 19 is deleted, row 18 slides into slot 19, and the loop moves on to look at slot 18.
The row that just fell into 19 is never looked at, and if it was full too, it stays on the board.

Look at the first test in the file.
It stacks a half-full row on 17 and two full rows on 18 and 19:

```blimp
stacked = for y in range(0, 19) do
  case y do
    17 -> part
    18 -> full
    19 -> full
    _ -> [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  end
end
```

Two adjacent full rows are there to catch exactly that loop.

In Blimp you can't write that loop anyway, because `rows` never changes under you.
So turn the question around.
Don't ask which rows to remove; ask which rows to keep.
A row is kept if it has at least one empty cell in it, and `filter` over `rows` answers that in one pass without moving anything while it looks.

### A row with a zero in it

You know `filter` and `empty?` from the Board's `:fits?`.
Filtering a single row for its zeros gives you a list that is empty exactly when the row is full:

```blimp
row = [1, 1, 0, 1]
print(filter(row, fn(v: Int) do v == 0 end))
print(empty?(filter(row, fn(v: Int) do v == 0 end)))
```

```
[0]
false
```

You want the opposite of `empty?` here: keep the row when its zero list is *not* empty.
Blimp spells "not" two ways, `!x` and `not(x)`.
The one it does not accept is the English-looking `not x`, which is an error, because `not` is a function and needs its parentheses:

```
-- UNDEFINED VARIABLE ────────────────────────────

  I can't find a variable called `not`.
```

That gives you the outer filter: over `rows`, with a `fn(row: List)` whose body is "this row's zeros are not empty".
Call the result `kept`.

### How many went

The board is always 20 rows tall, so the number cleared is `20 - length(kept)`.
That is also what `:sweep` replies.

### New rows on top

Those rows have to come back as empty ones at the top, or the board shrinks.
You built rows of zeros with a nested `for` in Chapter 3; this time the outer range is the number cleared:

```blimp
for i in range(1, cleared) do for x in range(1, 10) do 0 end end
```

Most sweeps clear nothing.
You don't need a special case for that, because `range(1, 0)` is the empty list, and a `for` over it builds nothing:

```blimp
print(range(1, 0))
print(for i in range(1, 0) do 7 end)
```

```
[]
[]
```

### Joining them

Row 0 is the top, so the empty rows go at the front and `kept` goes after them.
`append(list, x)` returns a new list with `x` added at the end.
When `x` is itself a row, you get one more row, not a flattened list:

```blimp
print(append([1, 2], 3))
print(append([[1], [2]], [3]))
```

```
[1, 2, 3]
[[1], [2], [3]]
```

So start from the empty rows and `reduce` over `kept`, appending each kept row to the accumulator.
The solution does exactly that.
If you prefer, `empties ++ kept` does the same join in one expression; `++` concatenates two lists.
What does not work is `concat`, which is for strings and throws a `TypeError` when handed lists.

`become rows:` the joined list, and reply the count.

### Why it replies a number

`:sweep` could reply `:ok` like `:lock` does.
It replies the count because somebody else needs it.
In Chapter 7 the Game locks a piece and then does this, in one line:

```blimp
score <- :cleared(board <- :sweep)
```

The Board doesn't know a score exists.
It knows cells.
The Score doesn't know a board exists.
It knows points.
The Game is the only one that knows both, and it passes a number from one to the other.

**Your task:** fill in `:sweep`.
Both Board tests should go green.

## `Tetris.Score`

```blimp
actor Tetris.Score do
  state score: Int :: 0
  state lines: Int :: 0
  state level: Int :: 1
```

`:summary` and `:reset` are written for you, which is why "starts at zero on level 1" and "reset goes back to zero" already pass.
The other four are yours.

### A list is a lookup table

Clearing one row at once pays 100, two pay 300, three 500, four (a Tetris) 800, all times the current level.
Clearing zero pays zero.
That is five numbers indexed by 0 to 4, which is a list and `elem`:

```blimp
elem([0, 100, 300, 500, 800], n)
```

No `case`, no chain of guards.
The zero at the front is doing real work: it makes `n` the index directly, and it means `:cleared(0)` after a sweep that cleared nothing scores nothing without a special case.

What if `n` is 5?
`elem` past the end of a list returns `nil`, not an error.
Multiplying that `nil` by the level is where it stops:

```
-- TYPE MISMATCH ─────────────────────────────────

  I can't do this operation because the types don't match.
```

Loud, which is what you want: a board can't clear five rows, and if it ever claims to, the game should stop rather than score something plausible.

### Integer division is the level

A level is every 10 lines, starting at 1.
Given the total line count, that is `total / 10 + 1`.
`/` on two `Int`s is integer division, it throws the remainder away:

```blimp
print(7 / 2)
print(19 / 10 + 1)
```

```
3
2
```

Nineteen lines is level 2, twenty-nine is still level 2, thirty is level 3.

### Which level multiplies

Read the third test carefully:

```blimp
score <- :cleared(4)
score <- :cleared(4)
assert_eq(score <- :cleared(2), 1900)
assert_eq(lookup(score <- :summary, :level), 2)
assert_eq(score <- :cleared(1), 2100)
```

800 + 800 + 300 is 1900.
That third clear takes the total from 8 lines to 10, so it moves you to level 2, but it is paid at level 1.
The next single row is paid at level 2: 200, for 2100.
So the handler works out what this clear is worth using the `level` it has now, then works out the new total and the new level, and `become`s all three at once.

### `become` does not change the names you are reading

Here is the trap in every one of these handlers.
After `become score: score + 1`, the name `score` in the rest of the handler still means the old score.
`become` sets the state the *next* message will see; it doesn't reassign anything in the handler that is running:

```blimp
actor Counter do
  state score: Int :: 0
  on :bump do
    become score: score + 1
    reply score
  end
end
c = spawn Counter
print(c <- :bump)
print(c <- :bump)
```

```
0
1
```

Each reply is one behind.
If you write `:soft_drop` that way, the drop test tells you so:

```
Assertion failed: values not equal
  left:  0
  right: 1
```

So reply the same expression you gave `become`, or bind it to a name first and use the name in both places.

This is the same rule that makes one-message-at-a-time safe.
The handler sees one consistent version of the actor from its first line to its last.

**Your task:** fill in `:cleared(n)`.
Reply with the new score.
"line values on level 1" and "level climbs every 10 lines and multiplies" should go green.

### Drops

A soft drop (pressing down) pays one point per row it moves.
A hard drop (space) pays two points per row it falls, and the Game tells the Score how many rows that was.
Both reply the new score.
Nothing new here except remembering the trap above.

**Your task:** fill in `:soft_drop` and `:hard_drop(rows)`.
"drops pay 1 and 2 per row" should go green: one point, then ten more, for 11.

## How fast it falls

`:drop_interval` is the number of milliseconds between gravity ticks.
Level 1 is 800.
Each level takes 70 off.
It never goes below 120, or the game turns into a wall of pieces nobody can steer.

Before level 1 there is nothing to take off, so the reduction is `(level - 1) * 70`.
Keep the parentheses.
`*` binds tighter than `-`, so without them you are subtracting 1 and then 70 times the level:

```blimp
print(800 - 2 - 1 * 70)
```

```
728
```

That is 800 minus 2 minus 70, not 800 minus 70.

The floor is `max`, which returns the larger of two numbers:

```blimp
print(max(120, 800 - (5 - 1) * 70))
print(max(120, -300))
```

```
520
120
```

Level 10 is 170.
Level 11 would be 100, so it is 120 from level 11 on.
The last test clears 132 lines, level 14, where the formula alone gives -110.
Without `max` you would hand the Game a negative timer.

Notice what `Tetris.Score` doesn't store: the interval.
It is worked out from `level` every time someone asks, so there is no second field that can drift out of step with the first.
If a number can be computed from state you already have, compute it.

**Your task:** fill in `:drop_interval`.

## The exercise

Four `Score` handlers and one `Board` handler, in this order:

- `Tetris.Board` `:sweep`: keep the rows with a zero, count the rest, put that many empty rows on top, reply the count.
- `Tetris.Score` `:cleared(n)`: look the value up by `n`, multiply by the level you are on, then update score, lines and level together. Reply the new score.
- `:soft_drop`: one point. Reply the new score.
- `:hard_drop(rows)`: two points a row. Reply the new score.
- `:drop_interval`: 800, 70 fewer per level after the first, never under 120.

Run the tests with **Run Tests** or ⌘⏎, or locally:

```
blimp exercises/ch04_lines_and_score/01_score.blimp --test
```

All eight should go green.
If you get stuck, the **Cheat** tab has the full solution.

## What you learned

Sweeping lines is a `filter`, not a loop that deletes, and that sidesteps the classic skipped-row bug instead of fixing it.
`range(1, 0)` is empty, so "zero of something" needs no special case.
`append` adds one element, `++` joins two lists, `concat` is for strings.
A list with a zero at the front is a lookup table indexed by count, and `elem` past its end is `nil`, which fails loudly the moment you do arithmetic with it.
`/` on integers truncates.
`become` changes what the next message sees, not what the current handler sees.
And a value you can compute from state doesn't need to be state.

Chapter 5 answers the question the Board and the Score never ask: which piece comes next.

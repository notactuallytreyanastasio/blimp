# Chapter 7: Gravity, landing, game over

A tick is one row of gravity.
The Game has no clock, and doesn't need one: something sends it `:tick` every so often, and each `:tick` moves the piece down a row or, if it can't move, lands it.

By the end of this chapter pieces fall, land, clear lines, pay out, and the next piece comes in.
Stack them to the top and the game ends.

In the tests you are the clock and send `:tick` by hand.
In chapter 8 the Screen sets a timer that sends it every `score <- :drop_interval` milliseconds, the number chapter 4's Score works out from the level.

Open `exercises/ch07_gravity/01_gravity.blimp`.
Chapter 6's Game is finished above; four new handlers are marked `# Exercise:`.

## Given: `:tick` and `:drop`

Two new inputs are already written, in the shape you know:

```blimp
on :drop when over or paused do reply :ok end
on :drop do reply self <- :hard_drop end
```

```blimp
on :tick when over or paused do reply :ok end
on :tick do reply self <- :gravity end
```

That guard is all pausing takes.
A paused game drops the clock's ticks on the floor the same way it drops key presses.

The four exercises are in the file in this order: `:hard_drop`, `:drop_distance`, `:gravity`, `:lock_piece`.
This chapter takes them in that order too, top-down.
`:hard_drop` is written in terms of the other three, so its test won't pass until all four are done.

## Step 1: `:hard_drop`

Hard drop, the space bar, slams the piece down as far as it goes and locks it there at once.
It's four lines and one `reply`:

1. find out how many rows the piece can fall: `self <- :drop_distance(0)`,
2. move the piece down that many rows,
3. pay two points a row with chapter 4's `score <- :hard_drop(rows)`,
4. lock the piece: `self <- :lock_piece`,

and reply `:ok`.

Why not send `:gravity` over and over until it locks?
Because you need the distance anyway, for the score.
And chapter 8's Screen needs the same number to draw the ghost piece, the outline of where the piece would land, without moving anything.
One handler that answers "how far" serves both.

## Step 2: `:drop_distance`, a loop without a loop

`:drop_distance(dy)` answers: starting `dy` rows below where the piece is, how many rows can it fall?
You call it with 0.

Blimp has no `while`.
Writing one is a parse error:

```blimp
n = 0
while n < 3 do
  n = n + 1
end
```

```
Parse error: error.UnexpectedToken at line 2, col 13
```

`for` needs its list up front, and here you don't know how many steps there are until you've taken them.

### Why the `for` version is wrong

The tempting shortcut is to try every distance at once and keep the largest that fits:

```blimp
fitting = filter(range(0, 19), fn(dy: Int) do
  board <- :fits?(piece <- :cells_for(0, dy, 0))
end)
```

Run that against an I piece at the top of an empty board with one block at row 5, column 4, sitting right under the piece's path, and compare it with the real answer:

```blimp
print(game <- :drop_distance(0))
print(fitting)
```

```
3
[0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]
```

The piece fits at 18, below the block.
It can't get there, because it would have to pass through the block at 4.
"Fits at distance d" is not "can fall to distance d"; falling needs every row on the way to fit.
So you have to step, one row at a time, and stop at the first row that doesn't.

### Stepping with a self-send

A handler can send to itself with a bigger `dy`.
That's the loop:

- ask the board whether the piece fits at `dy + 1` (`piece <- :cells_for(0, dy + 1, 0)` and `board <- :fits?`),
- if it does, reply whatever `self <- :drop_distance(dy + 1)` replies,
- if it doesn't, `dy` is the answer.

`dy` is the counter and the answer at once, so nothing gets added up on the way back out.

A self-send doesn't queue behind the message being handled.
If it did, the handler would wait for a reply from a message stuck behind itself, forever.
It runs straight away, nested inside the current handler, like a function call, and like a function call it uses up stack:

```blimp
actor R do
  on :count(n: Int) when n == 0 do reply 0 end
  on :count(n: Int) do reply 1 + (self <- :count(n - 1)) end
end
r = spawn R
print(r <- :count(20))
print(r <- :count(1000))
print(r <- :count(100000))
```

```
20
1000
Bus error at address 0x300003f80
```

That last line is the interpreter itself dying, followed by a stack trace.
The board is 20 rows tall, so `:drop_distance` never goes deeper than 20.

Note the brackets in `1 + (self <- :count(n - 1))`.
`<-` binds more loosely than arithmetic and comparison, so without them `1 + self <- :count(...)` parses as `(1 + self) <- ...`, and Blimp stops with TYPE MISMATCH.
`5 == a <- :five` is the same trap and gives NOT AN ACTOR.
When a send's reply goes into an expression, bracket it or put it in a variable first.

## Step 3: `:gravity`

One row of gravity is chapter 6's `:nudge(0, 1)` with a different ending.
Ask whether the piece fits one row down.
If it does, `piece <- :move(0, 1)`.
If it doesn't, the piece has landed, and the answer is `self <- :lock_piece`.
Reply whatever that `case` gave you.

A falling piece doesn't lock on the tick it touches down; it locks on the next tick, when it tries to move and can't.
That gap is when the player can still slide it sideways along the floor.

## Step 4: `:lock_piece`

Locking is the longest handler in the game, and the order of the lines is most of the work.

1. Read the piece's cells, `piece <- :cells`, and keep them in a variable.
2. Paint them into the board: `board <- :lock(cells, kind)`, where the colour is the piece's kind, `lookup(piece <- :info, :kind)`.
3. Sweep, and pay for what was swept: `:sweep` replies how many rows it cleared, and `score <- :cleared(n)` takes exactly that number.
4. Work out whether any locked cell was above the top (see below).
5. Spawn the next piece: `piece <- :spawn(next_kind)`.
6. Draw the kind after that from the bag.
7. Check whether the new piece fits where it spawned.
8. `become` the new `next_kind`, and `over` if either check says so. Reply `:ok`.

Steps 1 and 2 have to happen before step 5.
There is one Piece actor for the whole game; `:spawn` resets it to a new kind at the top.
After that, `piece <- :cells` and `piece <- :info` describe the new piece, not the one that landed.

### Two ways to lose

The obvious game-over check is step 7 alone: the new piece doesn't fit, the game is over.
It misses a case.

Chapter 3's `:lock` skips cells with `y < 0`, because they have no row to go in.
So a piece that lands with part of itself above the top loses those cells silently.
If the new piece spawns somewhere else and fits, the game carries on with a board missing half a piece.

Here is that happening with step 7 as the only check.
The board has columns 7 and 8 filled from row 1 down; an O piece sits on top of them with its upper half at row -1:

```blimp
piece <- :spawn(2)
piece <- :move(3, -1)
print(piece <- :cells)
print(game <- :tick)
print(elem(board <- :rows, 0))
print(game <- :over?)
```

```
[{7, -1}, {8, -1}, {7, 0}, {8, 0}]
:ok
[0, 0, 0, 0, 0, 0, 0, 2, 2, 0]
false
```

Two of the four cells made it into row 0.
The other two are gone, and the game isn't over.
With both checks, the same run ends in `true`.

The above-the-top check is a `filter` over the cells you saved in step 1: keep the ones whose `y` is below 0.
The game is over if that list is not empty, or the new piece doesn't fit:

```blimp
over: not(landed) or not(empty?(above))
```

`not` is a function in Blimp, which is why it has brackets.

## `become` and self-sends

`:gravity` and `:hard_drop` both self-send `:lock_piece`, and `:lock_piece` does a `become`.
It's worth knowing exactly what the sender sees afterwards:

```blimp
actor C do
  state a: Int :: 0
  state b: Int :: 0

  on :outer do
    become a: 1
    seen = self <- :inner
    become b: b + 10
    reply {seen, a, b}
  end

  on :inner do
    become b: 5
    reply a
  end

  on :both do reply {a, b} end
end

c = spawn C
print(c <- :outer)
print(c <- :both)
```

```
{1, 0, 0}
{1, 10}
```

Three things in that output.
`:inner` saw `a` as 1: a `become` takes effect straight away for any handler that runs after it, self-sends included.
`:outer`'s own `a` and `b` were still 0 at the end: inside a handler, the state names keep the values they had when the handler started, whatever `become` did since.
And the final `b` is 10, not 15: `:outer` computed `b + 10` from its stale `b`, and its `become` overwrote the 5 that `:inner` had written.

A `become` only writes the fields it names, so if `:outer` had become `a` alone, `:inner`'s `b: 5` would have survived.

For the Game this means: let `:lock_piece` do all the becoming.
`:hard_drop` and `:gravity` don't `become` anything, which is correct.
Add `become next_kind: next_kind` to `:hard_drop` after the self-send, which looks like it changes nothing, and it writes back the `next_kind` from before the lock.
The queued kind never advances: three hard drops in a row print the piece's kind and `next_kind` as `{5, 5}`, `{5, 5}`, `{5, 5}`, the same piece forever.

## The exercise

Fill in `:hard_drop`, `:drop_distance`, `:gravity`, `:lock_piece`.

The tests:

- "tick drops one row": a tick moves the piece from `y` 0 to 1, then down moves it to 2 and scores 1.
- "hard drop locks the piece and spawns the next one": after `:drop`, the piece is the kind that was queued, back at `y` 0, the board has exactly four filled cells, and the score is above 0.
- "stacking to the top ends the game, restart clears it": sixty hard drops fill the board, the game is over, `:left` replies `:ok` and changes nothing, and `:restart` empties the board.
- "a paused game ignores the clock": paused, a tick does nothing; unpaused, the next one moves the piece.
- "a piece that locks above the top ends the game": the O piece from the example above.
- "dropping into a gap clears the row and scores it": an I piece dropped into a four-wide gap in the bottom row clears it. The score is 136: it fell 18 rows at two points a row, plus 100 for one line at level 1.

```
blimp exercises/ch07_gravity/01_gravity.blimp --test
```

## What you learned

- A loop is a handler sending itself the next step, with the answer carried in the argument.
- Why "fits at distance d" isn't "can fall to d".
- A self-send runs nested, like a call, and uses stack.
- `<-` binds loosely: bracket a send inside arithmetic or a comparison.
- Inside a handler, state names are a snapshot; a `become` after a self-send can overwrite what the self-send wrote.
- The order of sends in `:lock_piece`, and the second way to lose.

You can play the game now, in the sense that every rule is there.
You just can't see it.
Chapter 8 builds the Screen.

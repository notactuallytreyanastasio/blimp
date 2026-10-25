# Chapter 6: The game takes input

The actor that runs the game owns almost nothing.
Of its seven state fields, four are other actors, and the rest are one number and two booleans.

By the end of this chapter you'll have a `Tetris.Game` that holds the bag, the board, the piece and the score from chapters 1 to 5, and turns left, right, rotate, down and pause into messages to them.
Gravity and landing are chapter 7.

Open `exercises/ch06_game/01_game.blimp`.
Everything above the line "This chapter" is finished work from earlier chapters.
Four handlers below it are marked `# Exercise:` and reply `:TODO`.

## Actors in state

Here is the top of the Game:

```blimp
actor Tetris.Game do
  state bag: Tetris.Bag :: nil
  state board: Tetris.Board :: nil
  state piece: Tetris.Piece :: nil
  state score: Tetris.Score :: nil
  state next_kind: Int :: 1
  state over: Bool :: false
  state paused: Bool :: false
```

The type of a state field can be an actor type.
You've seen this once already: in chapter 2 the Piece got `state shapes: Tetris.Shapes :: spawn Tetris.Shapes`, and spawned its own table.

The Game does not spawn its parts.
Its defaults are `nil`, and whoever spawns the Game hands the parts in:

```blimp
game = spawn Tetris.Game, bag: bag, board: board, piece: piece, score: score
```

`spawn Actor, key: value, ...` starts the actor with those fields set instead of their defaults.
Fields you don't name keep their default, so `next_kind`, `over` and `paused` start at `1`, `false`, `false`.

Handing the parts in means the thing that builds the game decides what the parts are.
The tests use that: they get the board back with `game <- :board` and `:load` a half-full grid into it, and the Game can't tell the difference.

The tests build a game with a helper at the bottom of the file:

```blimp
def new_game() -> Any do
  bag = spawn Tetris.Bag
  board = spawn Tetris.Board
  piece = spawn Tetris.Piece
  score = spawn Tetris.Score
  game = spawn Tetris.Game, bag: bag, board: board, piece: piece, score: score
  game <- :start
  game
end
```

`def` is a named function, the top-level cousin of `fn`.
Parameters are typed like handler parameters, `-> Any` is the return type, and the last expression is the value, with no `reply`.

A `def` exists once top-level code has run past it.
Calling `twice(4)` on the line above `def twice` fails with `I don't know a function called 'twice'`.
The tests can call `new_game()` although it sits at the very bottom because tests run after the whole file has loaded.

### What does not get checked

The keys after `spawn` are not checked against the actor's fields.
Misspell one and the spawn succeeds, the field keeps its default, and you find out at the first send that uses it:

```blimp
game = spawn Tetris.Game, bag: bag, bord: board, piece: piece, score: score
print("spawned")
game <- :start
```

```
"spawned"

-- NOT AN ACTOR ──────────────────────────────────

  Message send target is not an actor.

215|     board <- :reset
         ^

  Hint: The left side of <- must be an actor instance.
```

The types are not checked either: `spawn` with `label: 5` into a `String` field is accepted and `5` comes back out.
If you see NOT AN ACTOR on a line that sends to one of the Game's parts, look at the `spawn` first.

## Step 1: `:start`

`:start` gets a fresh game going on parts that may have been used before:

1. reset the board, the score and the bag,
2. spawn a piece of the bag's next kind,
3. draw one more kind and remember it as `next_kind`,
4. `become` not over and not paused, and reply `:ok`.

Every one of those is a send to a handler you wrote in an earlier chapter (`:reset` on three actors, `:spawn` on the Piece, `:next` on the Bag).
A send can sit anywhere a value can, including inside another send's arguments:

```blimp
piece <- :spawn(bag <- :next)
```

The inner send runs first and its reply becomes the argument.

Order matters in one place.
Reset the bag before you draw from it, or the first piece of a new game comes out of whatever was left of the old game's bag.

`:restart` is already written, and it is one line: `reply self <- :start`.

The test "start spawns a piece at the top" checks the piece is at `y` 0, not over, not paused, and that the piece's kind and `next_kind` differ.
Two draws from a fresh bag are never the same kind, and a `:start` that does nothing leaves both at their default `1`.

## Inputs are guarded one-liners

The input handlers are already written.
Each input is two clauses:

```blimp
on :left when over or paused do reply :ok end
on :left do reply self <- :nudge(-1, 0) end
```

This is chapter 3's rule: clauses are tried top to bottom and the first whose guard holds runs.
While the game is over or paused the first clause catches `:left` and does nothing.
Otherwise the second hands the real work to a small handler, `:nudge`, by sending to `self`.

An ignored key replies `:ok`, not an error.
Pressing left during a pause is not a mistake the sender can do anything about.

Pause has three clauses, and their order is the logic:

```blimp
on :pause when over do reply :ok end
on :pause when paused do
  become paused: false
  reply :ok
end
on :pause do
  become paused: true
  reply :ok
end
```

A finished game can't be paused, a paused game unpauses, anything else pauses.
Put the unguarded clause first and it would match every time and the other two would never run.

## Step 2: `:nudge`

`:nudge(dx, dy)` moves the piece if it fits there, and replies `:blocked` if it doesn't.

You have both halves already.
The Piece can tell you where its cells would be without moving (chapter 2), and the Board can tell you whether a list of cells fits (chapter 3):

```blimp
fits = board <- :fits?(piece <- :cells_for(dx, dy, 0))
```

That line is the first line of the answer.
The rest is a `case` on `fits` whose value you keep: `true` sends `:move(dx, dy)` to the piece, anything else is `:blocked`.
Reply what the `case` gave you, so a successful nudge replies whatever `:move` replied, which is `:ok`.

The obvious version is to move the piece, ask the board whether it fits, and move it back if it doesn't.
It's wrong because the Piece is its own actor and anyone holding it can ask it where it is; the tests do, with `piece <- :info`.
Move-then-undo leaves a window where the Piece reports cells inside a wall.
Asking first means the piece is never anywhere it doesn't fit.

The Piece also can't do this check itself.
It doesn't know the board, and giving it one would make two actors responsible for the same rule.
The Game is the one actor that knows both, so the rule lives there.

## Step 3: `:soft_drop`

Pressing down moves the piece one row and scores a point, but only if it moved.

`self <- :nudge(0, 1)` does the moving, and its reply tells you whether it happened: `:ok` or `:blocked`.
A `case` on that reply can be used just for its effect, with the value thrown away: on `:ok` send `score <- :soft_drop`, on anything else do nothing (write `_ -> :ok`).
Then reply what the nudge replied.

Nothing locks yet.
A piece that has hit the floor stays there, and pressing down replies `:blocked` forever.
Chapter 7 is where a blocked fall means landing.

## Step 4: `:turn` and wall kicks

Rotation has the same shape as a nudge: ask with `piece <- :cells_for(dx, dy, drot)`, then act.
The difference is what happens when the answer is no.

Stand an I piece up against the right wall and rotate it.
Lying flat, it is four wide, and at least one cell ends up past column 9.
Refusing the turn feels broken to a player.
Real Tetris "kicks" the piece: it tries the rotation shifted sideways a little and takes the first shift that fits.

Here the shifts are `0, -1, 1, -2, 2`, in that order.
`filter` gives you the ones that fit, in the order you listed them:

```blimp
kicks = filter([0, -1, 1, -2, 2], fn(k: Int) do
  board <- :fits?(piece <- :cells_for(k, 0, dir))
end)
```

`filter` checks all five even when the first one fits.
It has no early exit, and Blimp has no `break`.
Five questions to the board is cheap, so this doesn't matter here.

What you want is the first element of `kicks`, or to know there isn't one.
A list pattern does both:

```blimp
def first_or_none(xs: List) -> Any do
  case xs do
    [k | _] -> k
    _ -> :none
  end
end

print(first_or_none([-1, 1, 2]))
print(first_or_none([]))
print(first_or_none([5]))
```

```
-1
:none
5
```

`[k | _]` matches any list with at least one element, binds the first to `k`, and ignores the rest.
It does not match `[]`, which falls through to `_`.
(Chapter 5's Bag used `head` and `tail` for this; the pattern does the emptiness check for you.)

In `:turn`, the `[k | _]` arm sends `self <- :kick(k, dir)`, and the fallback is `:blocked`.
`:kick` is already written: it moves the piece `k` columns and rotates it, then replies `:ok`.

It's its own handler for a reason beyond tidiness.
A multi-line `case` arm can't end with a bare atom:

```blimp
x = 1
r = case x do
  1 ->
    a = 2
    :one
  _ -> :other
end
print(r)
```

```
Parse error: error.UnexpectedToken at line 5, col 9
```

The parser reads `:one` at the start of a line as the pattern of a new clause and wants a `->` after it.
Two sends followed by `:ok` inside the arm would hit exactly that.

The test "rotating against the wall kicks the piece back in" does the I piece example.
It stands the piece up (rotation 1, one column wide at `x + 2`), pushes it right until `x` is 7, and rotates.
Flat, rotation 2 covers `x` to `x + 3`, which is columns 7 to 10: column 10 is off the board.
Shift 0 fails, shift -1 fits, and the piece ends up at `x` 6.

## One message at a time, again

Every input the player gives is one message to the Game: `:left`, `:rotate`, `:down`.
In chapter 7 the clock's tick becomes one more.

The Game handles one message at a time, and a handler runs to completion before the next message is taken from the mailbox.
So the question and the move in `:nudge` happen together.
A tick that arrives while `:rotate` is asking about kicks waits in the mailbox until the rotation has replied.

Nothing in this chapter took a lock to get that.
The only rule you followed is that nobody but the Game moves the Piece.

## The exercise

Fill in, in order: `:start`, `:nudge`, `:soft_drop`, `:turn`.

The six tests check:

- start puts a piece at the top, not over, not paused, with a different kind queued next
- left and right move the piece, and a piece pushed into the left wall replies `:blocked` and still fits
- rotate turns the piece to rotation 1
- down moves the piece one row and the score becomes 1
- rotating the I piece against the right wall kicks it back to `x` 6, rotation 2
- while paused, left and down do nothing, and after unpausing left works again

Run with the **Run Tests** button or ⌘⏎, or locally:

```
blimp exercises/ch06_game/01_game.blimp --test
```

## What you learned

- A state field can hold an actor, and `spawn Actor, key: value` hands it one.
- Spawn keys are not checked; a typo shows up later as NOT AN ACTOR.
- `def` for named functions, available once top-level code has passed it.
- Guarded clauses that swallow input, and why their order matters.
- Ask the board first, then tell the piece.
- `[k | _]` to take the first element of a list, or learn it's empty.

Chapter 7 makes the piece fall on its own, land, and eventually fill the board.

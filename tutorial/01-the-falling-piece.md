# Chapter 1: The falling piece

By the end of this chapter you'll have `Tetris.Piece`: an actor that knows which kind of piece is falling, which way it is turned, and where it is, and that can move, turn, and start over as a new piece.
Four handlers, four tests.

The surprising part is how little it knows.
A falling piece in Tetris looks like four coloured squares, but this actor holds four numbers and no squares at all.
What the squares are is chapter 2's job, and deciding whether a move is allowed belongs to the board and the game.
The piece only remembers.

## What an actor is

An actor is three things: private state that nothing outside can touch, a mailbox of messages other parts of the program have sent it, and handlers that take those messages off the mailbox one at a time.
That's the whole model.

Blimp's actors are Carl Hewitt's, from 1973: a process that owns its state, reads its mail one message at a time, and in answer to each message can compute, send messages, and decide what it will be next.
Hewitt's word for that last move is "become": an actor does not mutate its state, it *becomes* its next state.
Blimp keeps the word, and you will write it in three of this chapter's four handlers.

## The shape of `Tetris.Piece`

Open the Editor tab.
The file starts with this:

```blimp
actor Tetris do
  state name: String :: "blimp tetris"
end

actor Tetris.Piece do
  state kind: Int :: 1
  state rot: Int :: 0
  state x: Int :: 3
  state y: Int :: 0
```

`actor Tetris.Piece do ... end` defines a kind of actor, a template, not a live piece.
Names that start with a capital letter are types; lowercase names are variables and functions.
The dot is part of one name.
It groups all seven of the game's actors under `Tetris`, which is why the small `actor Tetris` sits above it; `Tetris.Piece` runs the same with or without it.

Each `state` line is a field with three parts: a name, a type, and a default.
The type is required, and it means you can't spawn a piece and find out three messages later that its `x` is a string.
The default is not required, and that is the trap: `state x: Int` with no default parses, starts as `nil`, and the first `x + 1` stops with `I can't use + with Nil on the left and Int on the right`.
Every field in this game has a default, so `spawn Tetris.Piece` with no arguments gives you a piece that works.

The `::` is two colons because one colon already means something.
A colon in front of a name makes an atom, so defaults got their own operator.

What the four fields mean:

- `kind` is which of the seven pieces this is, numbered 1 to 7 in the order I O T S Z J L. The default, 1, is the I.
- `rot` is which of four rotations it is in, 0 to 3.
- `x` is the column of the piece's 4x4 box, counting from 0 at the left wall of a 10-wide well.
- `y` is the row of that box, counting from 0 at the top and growing downwards.

Column 3 puts the 4x4 box roughly in the middle of the well; row 0 is the top.
Every new piece starts there.

## Atoms, messages and handlers

**Atoms** look like `:ok`, `:info`, `:TODO`.
An atom is a constant whose identity is its name, like a Ruby symbol or an Elixir atom.
Two atoms with the same name are equal, and that is all there is to them.
Messages are atoms, and so are most simple replies.

A handler says what to do when a message arrives:

```blimp
on :info do
  reply :TODO
end
```

`on :info do ... end` means "when I receive `:info`, run this block".
Inside it, the state fields are ordinary variables: `kind`, `rot`, `x` and `y`, no `self.` in front.
`reply` sends a value back to whoever sent the message.

A message can carry arguments, and each one is typed:

```blimp
on :move(dx: Int, dy: Int) do
```

The types are checked before anything runs.
This probe, below a copy of `Tetris.Piece`, prints before it sends a string, and the print never happens:

```blimp
print("running")
piece = spawn Tetris.Piece
piece <- :move("left", 0)
```

```
Type error at line 13, col 16: argument 1 to :move expected Int, got String
1 type error(s) found.
```

## Spawning and sending

`spawn Tetris.Piece` makes a live piece from the template and gives you a reference to it.
`<-` sends a message and evaluates to the reply:

```blimp
piece = spawn Tetris.Piece
piece <- :info
```

Every send waits for its reply, so `piece <- :info` reads like a function call that happens to go through a mailbox.
Each spawn is a separate actor with its own state, and you can override any default when you spawn:

```blimp
piece = spawn Tetris.Piece
other = spawn Tetris.Piece, x: 7
print(piece)
print(other)
```

```
ref<Tetris.Piece:1>
ref<Tetris.Piece:2>
```

Sending a message the actor has no handler for is loud, not a silent `nil`:

```
-- NO MATCHING HANDLER ───────────────────────────

  I tried to send :spin to this actor, but it doesn't know how to handle it.

6| piece <- :spin
     ^
```

## Tests live in the actor

The bottom of `Tetris.Piece` is four `test` blocks.
A test spawns what it needs, sends messages, and checks the replies:

```blimp
test "move adds to x and y" do
  piece = spawn Tetris.Piece
  assert_eq(piece <- :move(-2, 5), :ok)
  info = piece <- :info
  assert_eq(lookup(info, :x), 1)
  assert_eq(lookup(info, :y), 5)
end
```

`assert_eq(a, b)` fails the test unless the two are equal.
There is also `assert(v)`, which wants something true, and `refute(v)`, which wants something false; you will use those from chapter 3 on.

Press **Run Tests** now.
All four fail, and three of them tell you why: the handler replied `:TODO` where the test wanted something else.
The fourth, "rotate wraps both ways", fails without showing two values (the terminal prints only `assertion failed`), because it calls `lookup` on the reply to `:info`, and `lookup` on the atom `:TODO` is a type error rather than a wrong answer.
It will start saying something useful once `:info` works.

## Step 1: `:info`

The stub lists `:spawn` first, but every test reads the piece through `:info`, so start there.
`:info` replies with a map of the four fields.

A map is written `%{key: value, ...}`.
`lookup(map, :key)` reads one entry, and a key that isn't there gives `nil`:

```blimp
info = %{kind: 1, x: 3}
print(lookup(info, :x))
print(lookup(info, :rot))
```

```
3
nil
```

One trap.
Two maps with the same keys and values are not equal if the keys are written in a different order:

```blimp
print(%{kind: 1, x: 3} == %{kind: 1, x: 3})
print(%{kind: 1, x: 3} == %{x: 3, kind: 1})
```

```
true
false
```

The first test compares the whole reply against `%{kind: 1, x: 3, y: 0, rot: 0}`, so write your keys in that order: kind, x, y, rot.
Any other order fails with a diff that shows the same four numbers on both sides.

**Your task:** make `:info` reply with that map, using the state fields as the values.
Run the tests; "a new piece is an I at the top, column 3, rotation 0" goes green.

## Step 2: `:spawn`, and what `become` means

The rest of the handlers change the piece.
In most languages that is an assignment, `piece.x = 3`, and Blimp has none.
Instead a handler says what the actor becomes next:

```blimp
become y: y + 1
```

Fields you list get new values; fields you leave out keep theirs.
List several with commas: `become a: 1, b: 2`.

The new values take effect when the handler finishes, not on the next line.
Inside the handler, the fields keep the values they had when the message arrived.
This probe adds a `:fall` handler that becomes one row lower and replies with `y`:

```blimp
on :fall do
  become y: y + 1
  reply y
end
```

```blimp
piece = spawn Tetris.Piece
print(piece <- :fall)
print(piece <- :fall)
```

```
0
1
```

The first `:fall` replies 0, the row it started on, though the piece is now on row 1.
Keep that in mind whenever a handler both becomes and replies: if the caller wants the new value, compute it and reply with that.

Now `:spawn`.
When a piece lands, the game doesn't make a new piece actor; it tells the same one to start over as the next kind.
Starting over means all four fields: the new kind, rotation 0, column 3, row 0.
The test moves and rotates the piece first, so a `:spawn` that only sets `kind` leaves the piece where the last one landed, and the test says so.

Reply `:ok`.
That is the convention for "done, nothing else to say", and it's what the test checks.
Naming a message `:spawn` is fine even though `spawn` is a keyword; the colon makes it an atom.

**Your task:** fill in `:spawn` with one `become` that sets all four fields, then `reply :ok`.
"spawn starts over as the given kind" goes green.

## Step 3: `:move`

`:move(dx, dy)` shifts the piece.
`dx` is added to `x` and `dy` to `y`, and either can be negative: the game sends `:move(-1, 0)` for left, `:move(1, 0)` for right and `:move(0, 1)` for one row down.

The piece does not check the walls.
Moving it to column -5 works, and that is on purpose.
Whether a move is allowed depends on the board, which the piece doesn't know about; in chapter 6 the game asks the board first and only sends `:move` when the answer is yes.

**Your task:** fill in `:move`: one `become` with both fields, then `reply :ok`.
"move adds to x and y" goes green.

## Step 4: `:rotate`, and why `rem` is not enough

`:rotate(dir)` turns the piece: 1 is clockwise, -1 is anticlockwise.
There are four rotations, 0 to 3, and turning past either end wraps round.
Clockwise from 3 is 0; anticlockwise from 0 is 3.

The obvious version is `rot + dir` and then the remainder after dividing by 4, with `rem`.
It works clockwise and fails anticlockwise:

```blimp
print(rem(3 + 1, 4))
print(rem(0 - 1, 4))
```

```
0
-1
```

`rem` keeps the sign of the number you divide, so 0 turned anticlockwise is rotation -1, which doesn't exist.
The test catches exactly this: its first move is `:rotate(-1)` from 0, and it expects 3.

The fix is to add 4 before taking the remainder, so the number is never negative:

```blimp
print(rem(0 - 1 + 4, 4))
print(rem(3 + 1 + 4, 4))
```

```
3
0
```

Adding 4 changes nothing for the clockwise case, because 4 is a whole turn.
It only rescues one step backwards, though: `rem(0 - 5 + 4, 4)` is still -1.
That is fine here because the game only ever sends 1 or -1.

The last part of the test turns the piece five times in a row:

```blimp
for i in range(1, 5) do piece <- :rotate(1) end
```

`range(1, 5)` is the list `[1, 2, 3, 4, 5]`, both ends included, and `for` runs its body once for each.
Five clockwise turns from 0 end on 1.

**Your task:** fill in `:rotate` with a `become` of `rot` using `rem`, then `reply :ok`.
All four tests go green.

## The exercise

In `exercises/ch01_piece/01_piece.blimp`, fill in the four handlers marked `# Exercise:`: `:info`, `:spawn`, `:move` and `:rotate`.
The tests check that a new piece is an I at column 3, row 0, rotation 0, with the map's keys in the order kind, x, y, rot; that `:spawn` resets all four fields after a move and a turn; that `:move` handles a negative `dx`; and that rotation wraps backwards from 0 and forwards past 3.
Every handler but `:info` replies `:ok`.
In a terminal: `blimp exercises/ch01_piece/01_piece.blimp --test`.

## What you learned

An actor is a template with typed state and defaults, and `spawn` makes a live one.
Messages are atoms, possibly with typed arguments, and `<-` sends one and waits for the reply.
`become` names the next state and takes effect when the handler ends.
Maps compare in key order, `rem` keeps the sign, and `range` includes both ends.

The piece has a position and a rotation, but still no shape.
Chapter 2 writes the seven shapes down as a table in a second actor, and the piece asks it where its four cells are.

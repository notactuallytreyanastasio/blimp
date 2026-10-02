# Chapter 2: Shapes are data

The Piece from chapter 1 knows its kind, rotation and position, but not which squares it covers.
By the end of this chapter a second actor, `Tetris.Shapes`, holds every shape in the game, and the Piece asks it where its own four cells are.

## Nobody rotates anything

The obvious way to rotate a Tetris piece is to take its four cells and turn them 90 degrees about a centre with a little trigonometry or a rotation matrix.
That is not how Tetris rotates.
Try it on the O piece, cells `{1, 0} {2, 0} {1, 1} {2, 1}`, turned about the cell `{1, 1}`: you get `{2, 1} {2, 2} {1, 1} {1, 2}`, a square that has slid down a row.
In the real game the O does not move at all when you rotate it, and the I piece turns about a point between cells rather than on one.
Every rule you could write for this has exceptions.

So the game does not compute rotations.
It looks them up.
Seven kinds of piece, four rotations each, four cells per rotation: 112 coordinates, written out once.
Open `exercises/ch02_shapes/01_shapes.blimp` in the editor and the table is already there:

```blimp
# Kinds 1..7 are I O T S Z J L. Each is a list of 4 rotations, and each
# rotation is a list of 4 {x, y} offsets inside a 4x4 box.
actor Tetris.Shapes do
  state table: List :: [
    [[{0, 1}, {1, 1}, {2, 1}, {3, 1}], [{2, 0}, {2, 1}, {2, 2}, {2, 3}], [{0, 2}, {1, 2}, {2, 2}, {3, 2}], [{1, 0}, {1, 1}, {1, 2}, {1, 3}]],
    [[{1, 0}, {2, 0}, {1, 1}, {2, 1}], [{1, 0}, {2, 0}, {1, 1}, {2, 1}], [{1, 0}, {2, 0}, {1, 1}, {2, 1}], [{1, 0}, {2, 0}, {1, 1}, {2, 1}]],
    ...
  ]
```

The first row is the I: lying flat in row 1 of its box, then standing up in column 2, then flat in row 2, then standing in column 1.
The second row is the O, four identical rotations.
Once the shapes are data, "rotate" is "use the next entry", and the Piece already knows how to count rotations from chapter 1.

## Tuples and lists

`{0, 1}` is a tuple: a fixed number of values in curly braces.
Here it is always two, an `x` and a `y`.
`[a, b, c]` is a list, which can be any length.
The table is a list of seven kinds, each a list of four rotations, each a list of four tuples.

You get things out of both with `elem`, and `elem` counts from 0:

```blimp
table = [[{0, 1}, {1, 1}, {2, 1}, {3, 1}], [{1, 0}, {2, 0}, {1, 1}, {2, 1}]]
print(elem(table, 1))
print(elem(elem(table, 1), 0))
print(elem(table, -1))
print(elem(table, 5))
```

```
[{1, 0}, {2, 0}, {1, 1}, {2, 1}]
{1, 0}
[{0, 1}, {1, 1}, {2, 1}, {3, 1}]
nil
```

The first two lines are the useful ones.
Position 1 is the second kind, and position 0 of that is its first rotation.
`elem` works on a tuple the same way: `elem({7, 8}, 1)` is `8`.

The last two lines are the ones to remember.
A negative position does not crash; it gives you the first element.
A position past the end does not crash either; it gives you `nil`.

That matters here because kinds count from 1 (I is 1, L is 7) and list positions count from 0.
Kind 3 lives at position 2.
Forget the `- 1` and asking for kind 7 gets you `nil`, which crashes one step later when you try to take a rotation out of it.
Subtract 1 twice and asking for kind 1 gets you position -1, which is the I piece, which is what you asked for, so nothing tells you anything is wrong until kind 2 comes out as an I too.

`length` counts the elements of a list:

```blimp
length([[1], [2], [3]])    # => 3
```

## Step 1: `:offsets` and `:kinds`

Two handlers on `Tetris.Shapes`.
`:offsets(kind, rot)` replies with the list of four `{x, y}` offsets for that kind in that rotation: one `elem` to pick the kind, another to pick the rotation.
`:kinds` replies with how many kinds the table has, which is its length.

**Your task:** fill in both, then Run Tests.
"seven kinds", "I stands up in rotation 1" and "every rotation of every kind is 4 cells inside the 4x4 box" should go green.

One test, "O looks the same in every rotation", was green before you started.
It compares `shapes <- :offsets(2, 0)` with `shapes <- :offsets(2, 3)`, and on the stub both reply `:TODO`, which equals `:TODO`.
A test that passes on a stub is only telling you the two sides agree, not that either is right.

## `for` is an expression

The biggest test reads like a loop, but it is building a value:

```blimp
counts = for kind in range(1, 7) do
  for rot in range(0, 3) do
    offs = shapes <- :offsets(kind, rot)
    inside = filter(offs, fn(o: Tuple) do
      case o do
        {x, y} -> x >= 0 and x <= 3 and y >= 0 and y <= 3
      end
    end)
    length(inside)
  end
end
assert_eq(flat(counts), for i in range(1, 28) do 4 end)
```

`range(1, 7)` is `[1, 2, 3, 4, 5, 6, 7]`: both ends included.
`range(1, 0)` is `[]`, not a countdown.
`for` runs its body once per element and collects the last value of each run into a list, so `for k in range(1, 3) do k * 10 end` is `[10, 20, 30]`.
Two `for`s nested give a list of lists, one inner list per kind, and `flat` squashes that into one list of 28 counts.
The right-hand side builds 28 fours the same way.
The `filter` and `fn` in the middle keep only the offsets inside the box; you will write both yourself in the next two steps and in chapter 3.

## An actor in another actor's state

Now the Piece.
It has one new state field:

```blimp
actor Tetris.Piece do
  state kind: Int :: 1
  state rot: Int :: 0
  state x: Int :: 3
  state y: Int :: 0
  state shapes: Tetris.Shapes :: spawn Tetris.Shapes
```

The type of `shapes` is the actor's name, and its value is a reference to a running `Tetris.Shapes`.
A reference is a small handle, not a copy of the actor: you can store it, pass it in a message, hand it to someone else, and every holder is talking to the same actor with the same mailbox.

The surprising part is when that default runs.
Defining an actor runs its state defaults, once, at the point in the file where the definition sits, and every spawn after that starts from those values.
So every Piece gets the same Shapes:

```blimp
actor Tetris.Shapes do
  on :hi do reply :hi end
end

actor Tetris.Piece do
  state shapes: Tetris.Shapes :: spawn Tetris.Shapes
  on :shapes do reply shapes end
end

a = spawn Tetris.Piece
b = spawn Tetris.Piece
print(a <- :shapes)
print(b <- :shapes)
```

```
ref<Tetris.Shapes:1>
ref<Tetris.Shapes:1>
```

Two pieces, one Shapes, and here that is exactly what you want.
The table never changes, nobody ever sends Shapes a message that `become`s, so one copy serves every piece in the game.
(An actor whose default spawned something that *did* change would share that state across every instance, and that would be a bug. If you need a fresh one, pass it in: `spawn Tetris.Piece, shapes: spawn Tetris.Shapes`.)

It also explains the order of the file.
If `Tetris.Piece` came before `Tetris.Shapes`, its default would try to spawn something that does not exist yet:

```
-- TEMPLATE NOT FOUND ────────────────────────────

  No actor template called `Tetris.Shapes` is defined.

2|   state shapes: Tetris.Shapes :: spawn Tetris.Shapes
                                      ^
```

That is why every exercise file from here on puts the finished actors at the top.

Why an actor for a table that never changes, rather than a `table` field on the Piece?
Because the Piece is not the only thing that needs shapes.
The Screen in chapter 8 draws the next piece in a preview box, and it asks a `Tetris.Shapes` for the offsets too (its own, from its own state default).
The Piece owns where it is; Shapes owns what every piece looks like; neither can reach into the other's state, and the only way across is a message.

## Asking another actor, from inside a handler

A send works inside a handler exactly as it does in a test:

```blimp
offs = shapes <- :offsets(kind, rot)
```

The Piece's handler stops at that line, Shapes handles `:offsets`, and its reply becomes the value of the expression.
Then the Piece carries on.
One outside message to the Piece has turned into two messages, one of them between actors, and nothing outside the Piece can tell.

## Step 2: `:cells_for`

`:cells_for(dx, dy, drot)` answers a hypothetical: which board cells would the piece cover if it were shifted by `dx` and `dy` and turned by `drot`?
It does not move the piece.
In chapter 6 the Game asks this before every move ("would it fit one column to the left?") and only moves the piece if the answer is yes.

Three pieces go into it.

**The rotation.** The turned rotation is `rem(rot + drot + 4, 4)`, the same wrap-around you wrote for `:rotate` in chapter 1, so `drot = -1` from rotation 0 asks for rotation 3.

**`map` and `fn`.** `map(list, f)` applies `f` to every element and gives back a new list of the results.
`fn` makes the function inline, and its parameter must have a type:

```blimp
map([1, 2, 3], fn(n: Int) do n * 2 end)    # => [2, 4, 6]
```

Leave the type off and Blimp refuses the whole file before running a line of it: `lambda parameter 'n' is missing a type annotation`.
Tuples are typed `Tuple`.

**`case` to take a tuple apart.** You cannot write `fn({ox, oy})`, and you cannot write `{a, b} = o`; both are parse errors.
The way into a tuple is `case`, whose clause pattern names the parts:

```blimp
offs = [{1, 0}, {0, 1}]
print(map(offs, fn(o: Tuple) do
  case o do
    {ox, oy} -> {ox + 10, oy + 20}
  end
end))
```

```
[{11, 20}, {10, 21}]
```

Inside the `fn` you can use the handler's own names.
The Piece's `x` and `y`, and the message's `dx` and `dy`, are all in scope, so each offset `{ox, oy}` becomes a board cell by adding the piece's position and the shift to it.

One warning: a `case` where no clause matches does not crash.
It quietly produces `nil`.
If your pattern is wrong you will see a list of `nil`s in a failing test, not an error pointing at the `case`.

**Your task:** fill in `:cells_for`.
Ask `shapes` for the offsets of `kind` in the turned rotation, then `map` them to board cells and reply with the result.
"cells_for shifts and rotates without moving the piece" should go green; it also checks that `x`, `y` and `rot` are unchanged afterwards, so no `become` belongs in this handler.

## Step 3: `:cells`, by asking yourself

`:cells` is "where the piece is now", which is `:cells_for` with no shift and no turn.
You could copy the body of `:cells_for` and delete the `dx`, `dy` and `drot`.
Then there are two copies of the offset arithmetic, and the day one of them changes (a spawn row above the top, say) the other one is silently wrong, and the piece draws in one place while the game checks collisions in another.

Instead, an actor can send to itself:

```blimp
self <- :cells_for(0, 0, 0)
```

`self` is the reference to the actor whose handler is running.
You might expect that to deadlock, since the actor is busy handling `:cells` and cannot pick up `:cells_for` until it finishes.
It does not: a send to `self` runs the other handler immediately and hands back its reply.

There is one subtlety worth seeing now, because chapter 7 leans on it.
If the handler you call `become`s, that change is committed, but the handler that called it keeps reading the state it started with:

```blimp
actor Counter do
  state n: Int :: 0

  on :bump do
    become n: n + 1
    reply :ok
  end

  on :bump_twice do
    self <- :bump
    self <- :bump
    reply n
  end

  on :get do reply n end
end

c = spawn Counter
print(c <- :bump_twice)
print(c <- :get)
```

```
0
2
```

`:cells` changes nothing, so none of that bites here.

**Your task:** fill in `:cells` with a self-send.
"T cells at spawn" and "the cells follow the piece when it moves" should go green, which is all seven.

## The exercise

`exercises/ch02_shapes/01_shapes.blimp`, four handlers:

- `Tetris.Shapes` `:offsets` and `:kinds`: the table has seven kinds, the I stands up in rotation 1, the O is the same in every rotation, and every rotation of every kind is four cells inside the 4x4 box.
- `Tetris.Piece` `:cells_for` and `:cells`: a T at spawn covers `[{4, 0}, {3, 1}, {4, 1}, {5, 1}]`, the cells follow the piece when it moves, and `:cells_for(1, 2, 1)` answers without moving it.

Run it locally with `blimp exercises/ch02_shapes/01_shapes.blimp --test`, or with the Run Tests button.

## What you learned

Shapes are a table, not a formula, and the table is a list of lists of tuples that you read with `elem`, counting from 0, with no complaint if you count wrong.
An actor can hold a reference to another actor in its state; a state default runs once when the actor is defined, so every instance shares whatever it spawned.
A handler can ask another actor a question in the middle of its work, and can ask itself one with `self <-`.
`map` with an `fn` transforms a list, and `case` is how you get inside a tuple.

The Piece now knows where its cells are, but nothing knows whether those cells are free.
[Chapter 3](#ch03) builds the board they land on.

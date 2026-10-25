# Chapter 8: The screen, and playing it

By the end of this chapter the game you built in chapters 1 to 7 draws itself, listens to your keyboard and falls on its own, and you play it in the Play tab.
The last actor is `Tetris.Screen`, and it does not draw anything: it replies with a value that describes the screen, and the page draws that.

## A view is a value

Blimp has a handful of builtins that build pieces of a page.
`text`, `heading`, `code_block`, `row`, `stack` and `button` are the ones this chapter uses, and each returns a value like any other builtin.
Printing a few of them from the command line shows what they are:

```blimp
print(type_of(text("hi")))
print(heading("game over", 2))
print(row(button("◀", :left)))
print(stack(text("a"), [text("b"), text("c")], []))
```

```
:view_node
<heading level=2>"game over"</heading>
<row><button sends=:left>"◀"</button></row>
<stack><text>"a"</text><text>"b"</text><text>"c"</text></stack>
```

A view node is data.
You can put one in a list, pass it in a message, return it from a handler, and compare two of them with `==`.
Nothing appears anywhere until something outside the program decides to render it.

`row` lays its children out side by side and `stack` one above the other.
Look at the last line: a list inside a `stack` is spliced in, and an empty list disappears.
That is what lets a handler reply "zero, one or two lines of banner" as a list and have the caller drop it straight into a `stack`.
Only one level is spliced, and that matters later in this chapter.

`button("◀", :left)` is a button that, when clicked, sends `:left`; to whom is the next section.

## How the page draws it

The Play tab runs your file with the host in `blimp-view.js`, which is about 240 lines of JavaScript and contains no Tetris at all.
It does three things.

1. **Mount.** It evaluates the whole file once. The value of the file's last expression has to be a view, or the Play tab says so: "mount: the last expression of the source did not produce a view (expected game <- :view)". It renders that view.
2. **Send.** Every button click, key press and timer firing becomes two more evaluations in the same interpreter: `game <- :left`, then `game <- :view`. The new view replaces the old one.
3. **Effects.** After each render it walks the view for two kinds of node that draw nothing, `key` and `timer`, and makes the page's key listener and intervals match them.

Two consequences are easy to miss.

The host only ever talks to a top-level variable called `game`.
It builds the source text `game <- :left` and evaluates it, so if your startup block says `g = spawn Tetris.Game` and ends `g <- :view`, the mount works and the first key press stops the game with an `UNDEFINED VARIABLE` error: "I can't find a variable called game".

And the messages the page sends are bare atoms.
`button("◀", :left)` works; there is no way for a button or a key to send `:move(-1, 0)`.
That is why chapter 6 gave the Game one argument-free handler per input (`:left`, `:right`, `:rotate`, `:down`, `:drop`, `:pause`, `:restart`) and had them self-send to `:nudge` and `:turn`.

So between any two frames, the whole loop is: one message to the Game, one `:view` to the Game, one render.
The Game runs one message at a time, so a frame can never show a piece halfway through a move.

## The frame

The Screen does not hold the Game's actors and ask them questions.
It gets one map, the frame, that the Game builds in one handler:

```blimp
frame = %{rows: board <- :rows, piece: [{4, 0}, {3, 1}, {4, 1}, {5, 1}], ghost: [{4, 18}, {3, 19}, {4, 19}, {5, 19}], kind: 3}
```

That line is from the first Screen test, and it is the reason for the design.
Every Screen test builds its frame by hand, with only the keys the handler under test reads.
The timer test gets away with `%{over: false, paused: true, interval: 800}`.
If the Screen held a Board, a Piece and a Score, every one of those tests would need a running game set up in a particular position first.

It also means a frame is one moment.
The Game builds it inside one handler, and nothing else can change the Game while that handler runs, so the rows, the piece and the score in one frame always belong together.

You'll write the Game's `:frame` last, after the Screen's handlers.

## Glyphs

The board is drawn as text: twenty lines of ten coloured squares in a `code_block`.
The Screen keeps the squares in a list indexed by the numbers the Board stores:

```blimp
state glyphs: List :: ["⬛", "🟦", "🟨", "🟪", "🟩", "🟥", "🟧", "🟫", "⬜"]
```

`0` is an empty cell, `1` to `7` are the seven kinds (`elem(glyphs, 3)` is the purple T), and `8` is the white ghost.

A list, not a string of nine characters to slice, because Blimp strings are bytes.
`length("🟦")` is `4`, and `length("⬛⬛⬛")` is `9`.
Slicing a string of emoji would hand you pieces of characters; `elem` on a list picks a whole one.

## Step 1: `:paint`

```blimp
on :paint(grid: List, cells: List, v: Int) do
  reply :TODO
end
```

Write `v` into `grid` at each `{x, y}` in `cells`, skip any cell with `y < 0`, and reply the new grid.

You have written this handler before.
It is the Board's `:lock` from chapter 3, with `grid` where `:lock` has `rows` and `v` where it has `colour`: a `reduce` over the cells that starts from the grid, skips cells above the top, and writes one cell with two `set_at`s.

Why not just ask the Board to `:lock` the piece and read the rows back?
Because that would lock the piece.
Drawing a frame must not change the game, and `:paint` changes nothing: `set_at` returns a new list, so the rows in the frame, and the Board's own rows, are exactly what they were.
The Screen can paint the same frame twice, or paint it and throw it away, and the game is none the wiser.

## Step 2: `:line`

```blimp
on :line(cells: List) do
  reply :TODO
end
```

One row of the grid is ten numbers.
Reply one string of ten glyphs.

This is a `reduce` again, starting from `""`, where each step adds `elem(glyphs, v)` to the end with `concat`.
`concat` takes any number of strings, so `concat("a", "\n", "b")` is fine too; the given `:join` handler below uses exactly that to put newlines between lines.

## Step 3: `:board_lines`

```blimp
on :board_lines(frame: Map) do
  reply :TODO
end
```

Paint the ghost cells with `8`, then paint the piece cells with the piece's kind, over the frame's rows, and reply the twenty lines as strings.

The pieces:

- `lookup(frame, :rows)`, `lookup(frame, :ghost)`, `lookup(frame, :piece)` and `lookup(frame, :kind)` read the frame.
- `self <- :paint(...)` twice, the second one painting over the grid the first one replied.
- `map` over the painted grid, sending `:line` for each row.

You can rebind a name inside a handler, so `grid = ...` followed by `grid = ...` is allowed.

The order is the one thing to get right.
When the piece is resting on the stack, its ghost is in exactly the same cells.
Paint the ghost second and the piece you're steering turns white just as it lands.
The first test checks this from the other side: the piece in rows 0 and 1 is purple, the ghost's row 19 is white, and row 10 is empty.

## The handlers you're given

Read these before step 4; `:view` uses all of them.

`:join` turns the list of lines into one string with newlines, for a `code_block`.
`:preview` draws the next piece as a 4 by 2 box from the Shapes table.

`:stats` uses string interpolation, which is new: `"score #{lookup(s, :score)}"` evaluates the expression between `#{` and `}` and puts it in the string.
With `%{score: 120, lines: 3, level: 1}` it gives `"score 120   lines 3   level 1"`.

`:banner` matches on a tuple of two flags, `case {lookup(frame, :over), lookup(frame, :paused)} do`, and replies a list: two view nodes when the game is over, one when it's paused, none otherwise.
The test sends it `%{over: true, paused: false}` and counts two.

`:controls` is the touch controls: a row of five buttons and a row with pause and restart.
The pause button's label is worked out first, and the button sends `:pause` either way; the Game decides what pause means.

And `:view` puts it together:

```blimp
reply stack(
  heading("blimp tetris"),
  board,
  row(stack(text("next"), preview), self <- :stats(lookup(frame, :score))),
  self <- :banner(frame),
  self <- :controls(frame),
  self <- :effects(frame)
)
```

`:banner` and `:effects` reply lists, and `stack` splices them in.

## Step 4: `:effects`

```blimp
on :effects(frame: Map) do
  reply :TODO
end
```

Reply a flat list: eight keys, always, and one timer that sends `:tick` every `interval` milliseconds, but only while the game is neither over nor paused.

A key is `key(name, :message)`, where the name is the browser's `KeyboardEvent.key` for that key:

| Key | Name | Sends |
|-----|------|-------|
| ← | `"ArrowLeft"` | `:left` |
| → | `"ArrowRight"` | `:right` |
| ↑ | `"ArrowUp"` | `:rotate` |
| x | `"x"` | `:rotate` |
| ↓ | `"ArrowDown"` | `:down` |
| space | `" "` | `:drop` |
| p | `"p"` | `:pause` |
| r | `"r"` | `:restart` |

A timer is `timer(ms, :message)`:

```blimp
print(key("ArrowLeft", :left))
print(timer(800, :tick))
```

```
<key code="ArrowLeft" sends=:left />
<timer ms=800 sends=:tick />
```

The load-bearing fact of this chapter is what the host does with that timer.
It does not start a new interval each time it sees one.
It keys each running interval by its milliseconds and its message, `800|tick`, and after every render it compares: a timer it already has keeps running untouched, a timer that has appeared is started, and a timer that has gone from the view is cleared.

So pausing the game is not a call to stop anything.
Pausing is a frame whose view has no timer in it.
The obvious version, a `:pause` handler that tells some clock to stop and a `:resume` that tells it to start, needs the Game to hold a clock and keep it in step with `paused` by hand.
Here there is nothing to keep in step: the timer is on screen exactly when `paused` and `over` are both false, because the same frame decides both.

I checked this against `blimp-view.js` in Node with the chapter's solution mounted.
The `800|tick` interval had the same id after mount and after two `:left` presses, so moving the piece does not restart gravity; if it did, tapping left and right would hold a piece in the air forever.
After `:pause` there were no intervals and still eight keys.
After `:pause` again there was a new `800|tick`.
And after twelve cleared lines put the game on level 2, the interval was `730|tick`: the level changed the interval in the frame, the old timer vanished from the view, and the new one started.

Two pieces for the condition: `not(x)` flips a boolean, and `and` joins two.
Then a `case` on that boolean, with `true ->` giving a one-element list holding the timer and `_ ->` giving `[]`, is a list of zero or one timers.

Then you have a list of keys and a list of timers, and you need one list.
`[keys, ticker]` is a list of two lists, and `flat` removes one level of nesting:

```blimp
print(flat([[1, 2], [3]]))
print(flat([[1, [2]], [3]]))
```

```
[1, 2, 3]
[1, [2], 3]
```

Why not skip `flat` and let `stack` splice?
Because `stack` splices one level too, and a list left inside a list does not become a timer.
In the page's interpreter, `stack(text("x"), [key("p", :pause), [timer(800, :tick)]])` gives the host a key node and then this:

```
{"text":"[<timer ms=800 sends=:tick />]"}
```

A text node.
The timer is printed on the screen as literal text, and the piece never falls.
The tests catch it first: they check that `:effects` replies 9 things while running and 8 while paused or over, and a nested list has length 2.

## Step 5: the Game's `:frame`

Down in `Tetris.Game`:

```blimp
on :frame do
  reply :TODO
end
```

Reply one map with nine keys:

| Key | What it is | Where it comes from |
|-----|------------|---------------------|
| `rows` | the locked cells | `board <- :rows` |
| `piece` | the falling piece's cells | `piece <- :cells` |
| `ghost` | the same cells, dropped as far as they go | `piece <- :cells_for(0, dist, 0)` |
| `kind` | the piece's colour | `lookup(piece <- :info, :kind)` |
| `next` | the kind after this one | `next_kind` |
| `score` | the summary map | `score <- :summary` |
| `interval` | ms between ticks | `score <- :drop_interval` |
| `paused`, `over` | the flags | the Game's own state |

`dist` is the only thing to work out, and you wrote the handler for it in chapter 7: `self <- :drop_distance(0)` is how many rows the piece can fall straight down.
The ghost is where a hard drop would put the piece, and `:hard_drop` moves it by exactly that distance, so the ghost cannot disagree with the drop.

The handler below it is already written:

```blimp
on :view do reply screen <- :view(self <- :frame) end
```

That is the `:view` the host sends after every message.
The Game builds the frame, the Screen turns it into a view, and the Game hands the view back.

## The startup block

The bottom of the file has two ways of building a game.

`def new_game()` spawns every part, hands them to a `Tetris.Game` and sends `:start`.
The tests call it, so each test gets its own fresh game.

Then, after it, the real one:

```blimp
spawn Tetris
bag = spawn Tetris.Bag
board = spawn Tetris.Board
piece = spawn Tetris.Piece
score = spawn Tetris.Score
screen = spawn Tetris.Screen
game = spawn Tetris.Game, bag: bag, board: board, piece: piece, score: score, screen: screen
game <- :start
game <- :view
```

This is the block the Play tab runs.
It has to be last for two reasons you've met already: defining an actor runs its state defaults, so every actor must be defined before anything spawns it, and top-level code runs in file order.
The variable has to be `game`, and the last line has to be `game <- :view`, for the host's sake.

`spawn Tetris` spawns the actor at the very top of the file, which holds only the game's name.
Nothing sends it a message; it is there so the program's actor list has a `Tetris` in it.

Running the file does not run its `test` blocks, and running the tests does not play the game, but it does evaluate the file first.
That's why, on the stub, `blimp exercises/ch08_screen/01_screen.blimp --test` starts with `warning: first-pass eval failed` and a TypeError in `:join`: the startup block's `game <- :view` reached `:join` with `:TODO` instead of a list of lines.
The warning goes away when `:board_lines` works.

## The exercise

Open `exercises/ch08_screen/01_screen.blimp`.
Six tests, one of which (`preview shows the next piece in two rows`) passes before you start, because `:preview` is given.

- **board lines paint the piece over the ghost**: `:paint`, `:line` and `:board_lines`. Twenty lines; the T in rows 0 and 1 in purple, its ghost in row 19 in white, row 10 empty.
- **the timer is only there while the game runs**: `:effects` replies 9 things running, 8 paused, 8 over.
- **view is a view node**: the whole `:view` works on a hand-built frame, and `:banner` replies 0 or 2 lines.
- **pause freezes gravity and movement and drops the timer**: `:frame` and `:effects` together. After `:pause`, a `:tick` and a `:left` leave the piece at x 3, y 0, and the effects drop to 8; after a second `:pause`, back to 9.
- **the view paints the piece and its ghost**: a real game's frame, drawn. Row 1 has the piece's glyph in it, row 19 has a white square, and `game <- :view` is a view node. `contains(string, part)` is the substring check it uses.

Fill in, in order: `:paint`, `:line`, `:board_lines`, `:effects`, then `:frame`.

## Play my code

When all six pass, open the **Play** tab and press **Play my code**.
It runs the editor's source in a second interpreter, separate from the one the tests use, seeded with the time so each game deals a different sequence.

Some things you'll see:

- **The first key does nothing.** If the editor has the focus, keys go to the editor. The host ignores key presses whose target is a text field, and it ignores any press with Ctrl, Cmd, Alt or Shift held. Click the game, or use the buttons.
- **`Evaluation error` and nothing else.** That is all the page reports for the stub's TypeError during the mount, where the native `blimp` names the line in `:join`. Run the tests; they'll show you which handler is still `:TODO`.
- **The game stops when you switch tabs.** Leaving the Play tab unmounts it on purpose, so a timer doesn't keep ticking a game you can't see. Press Play again for a new game.

**Play the finished game** runs the reference `tetris.blimp`; yours should behave the same.

## What you learned

A view is a value, and the host draws whatever your file's last expression is.
Input comes back as bare-atom messages to `game`, each followed by `game <- :view`.
`key` and `timer` are effects the host makes the page match, so pausing gravity is leaving the timer out of the view.
The Screen draws from one frame map, so it tests with hand-written maps and every frame is one consistent moment.

Chapter 9 is not an exercise: it's a list of changes you can make to this game, each naming the actor and handler it touches, and where to look next.

# Chapter 9: Where to take it

You have a whole Tetris: seven actors in about 550 lines, and the page draws it from values your program returns.
This chapter has no exercise file. It lists changes worth making, each with the actor and handlers it touches and the thing most likely to trip you, and then where the rest of Blimp is documented.

Work in a copy of your chapter 8 file, and start each change with a test.
When a change adds keys, the chapter 8 tests that count `:effects` (9 running, 8 paused) will fail; that is them doing their job, so update the numbers.

## Hold

Press `c` to put the falling piece aside and take the held one, or the next one if nothing is held yet.
You may hold once per piece.

- `Tetris.Game` gets `state held: Int :: 0` and `state can_hold: Bool :: true`.
- A new `:hold` handler, with a guard clause in front of it like every other input.
- `:start` resets both; `:lock_piece` sets `can_hold: true` again.
- `:frame` gains `held: held`.
- `Tetris.Screen`: `:effects` gains `key("c", :hold)`, and `:view` shows the held piece with `:preview`.

A guard can call functions, so the "not now" clause fits on one line:

```blimp
on :hold when over or paused or not(can_hold) do reply :ok end
```

This is the test I wrote for it; it passes against a version with the handler written:

```blimp
test "hold swaps once per piece" do
  game = new_game()
  first = lookup((game <- :piece) <- :info, :kind)
  upcoming = game <- :next_kind
  game <- :hold
  assert_eq(lookup(game <- :frame, :held), first)
  assert_eq(lookup((game <- :piece) <- :info, :kind), upcoming)
  game <- :hold
  assert_eq(lookup((game <- :piece) <- :info, :kind), upcoming)
  game <- :drop
  game <- :hold
  assert_eq(lookup((game <- :piece) <- :info, :kind), first)
end
```

The trap is the empty hold box.
`held` is `0` until the first hold, and `screen <- :preview(0)` looks like it should fail loudly: it asks Shapes for `:offsets(0, 0)`, which does `elem(table, -1)`.
It doesn't fail.
`elem` with a negative index returns the first element (`elem([10, 20, 30], -1)` is `10`, and so is `-2`), so you get the I piece's shape drawn in glyph `0`, which is black, which looks like an empty box.
It is right by accident.
Show the box only when `held` is not `0`, and don't lean on `elem` below zero anywhere else.

## A longer next queue

Show the next three pieces instead of one.

- `Tetris.Game`: `next_kind: Int` becomes `next: List`. `:start` fills it with three `bag <- :next`; `:lock_piece` spawns `head(next)` and appends one more from the bag.
- Keep `:next_kind` replying `head(next)`, so the chapter 6 and 7 tests still pass unchanged.
- `:frame`: `next:` becomes the list.
- `Tetris.Screen` `:view`: `map` the list through `:preview` and put the results in a `stack`.

`Tetris.Bag` does not change at all: it already deals one kind per `:next` and refills itself.
That is the payoff of chapter 5 keeping the bag behind one message.

Don't spawn a `Tetris.Piece` per preview to get its cells.
Actors are never collected: in the page's interpreter, twenty `x = spawn Leak` in a row left twenty more actors in the program's actor list, although only one is reachable.
`:preview` already draws from the Shapes table without spawning anything.

## T-spins

A T-spin is a T piece that locks right after a rotation, with at least three of the four corners of its 3 by 3 box blocked.
Real games pay extra for it.

- `Tetris.Game` needs to remember whether the last thing that moved the piece was a rotation: a `state last_turn: Bool`, set in `:kick` and cleared when `:nudge` or `:gravity` actually moves the piece.
- In `:lock_piece`, before the lock, when the kind is `3` and `last_turn` is true, count the blocked corners.
- `Tetris.Score` gets a `:tspin(n)` handler next to `:cleared(n)`, with its own table of values.

The corners are cheap because of chapter 2's table.
The T's centre is offset `{1, 1}` in all four rotations; I checked by filtering each rotation of `shapes <- :offsets(3, r)` for `{1, 1}` and got `[1, 1, 1, 1]`.
So the corners are always the piece's `x`, `y` plus `{0, 0}`, `{2, 0}`, `{0, 2}` and `{2, 2}`, whatever the rotation.
Ask the Board `:blocked?` for each: its first clause already counts the walls and the floor as blocked, which is what T-spin rules want.

## Lock delay

Right now a piece locks on the first tick it cannot fall, which makes sliding along the floor impossible at speed.

- `Tetris.Game` `:gravity`: instead of `self <- :lock_piece` on the first failed fall, count grounded ticks in a new `state grounded: Int :: 0` and lock on the second.
- `:nudge` and `:kick` reset `grounded` to 0 when they succeed.

Decide how many resets a piece gets before you write the test, or a player can hold a piece on the floor forever by tapping left and right.
That is the same bug chapter 8's timer design avoids, arriving by another road.

## Two players on one keyboard

Two boards side by side, one on the arrows and one on WASD, where clearing lines sends garbage rows to the other side.

The host shapes this one.
It only ever sends to the variable `game`, and only bare atoms, so there is no `game <- :left(2)`.
The thing bound to `game` has to be a new coordinator, say `Tetris.Versus`, holding two `Tetris.Game`s and handling `:p1_left`, `:p2_left` and so on by forwarding plain `:left` to the right one.

- `Tetris.Versus` `:view`: a `row` of the two Games' `:view`s.
- `Tetris.Versus` `:tick`: tick both. Or give each its own timer. The host keys intervals by milliseconds and message, so `timer(800, :tick_one)` and `timer(730, :tick_two)` in one view are two separate intervals; I mounted exactly that and got both, plus the `a` key.
- `Tetris.Board`: a `:garbage(n)` handler that drops the top `n` rows and appends `n` rows with one gap.
- `Tetris.Game` `:lock_piece`: the number of cleared rows goes into the Score and is then lost. Keep it in state (`last_cleared`) so Versus can ask after each tick.

The two Games' own `:effects` both claim the arrow keys, and whichever one is later in the view wins.
Versus should build its effects itself instead of passing theirs through.

## Watching the actors

[The Tetris post](../blog/tetris.html) runs the finished `tetris.blimp` next to a window that draws the program's actors as hexagons and each message as a ray between them, straight from the interpreter's message log.
A ray from the blob is the page sending `:tick` or a key.
Click a hexagon to see that actor's state and recent messages; the Game is selected to start with.
It is the fastest way to see what chapter 8's loop costs.
I counted the log in the page's interpreter for one `:left` and the `:view` after it, with a new piece at the top of an empty board: the `:left` was 10 messages and the `:view` was 195.
Nearly all of those are the ghost.
`:drop_distance` sends itself once per row the piece could fall, and each step asks the Board `:fits?`, which asks the Piece `:cells_for`, which asks Shapes `:offsets`, and then sends four `:blocked?`.
If you want an optimisation exercise, that is it: the ghost only changes when the piece moves sideways, rotates or a piece locks, not on every tick.

It draws from `blimp.getState()`, which returns the program's `vars`, `actors` and `messages`, called from BlimpView's `onRender` hook after every render.
The finished game has nine actors in that list: the seven kinds, a second `Tetris.Shapes` (the Piece and the Screen each spawn one), and the `Tetris` from the top of the file.

It always loads `docs/blog/tetris.blimp`, not your code.
To watch your own version, serve the `docs/` directory over HTTP from a checkout (the page fetches the file, so opening it from disk won't work) and replace `docs/blog/tetris.blimp` with your file.
Or put the window into this tutorial's Play tab: `play()` in `docs/tutorial/index.html` creates the BlimpView, and the `onRender` in `tetris.html` is what feeds the canvas and the inspector.

## Two interpreters

The command-line `blimp` and the `blimp.wasm` in this page are not identical, and one difference bites Tetris code directly.
In the native build `or` and `and` short-circuit: `true or 1 / 0 == 1` is `true`.
In the page's build the same line is a division-by-zero error, in an expression and in a guard alike.
The Board's `:blocked?` is split into clauses, with the wall checks in a guard ahead of the clause that indexes into `rows`, for exactly this reason, and a guard that leans on short-circuiting will pass your local tests and crash in the Play tab.

Both builds' `random` is unseeded: a fresh interpreter gives the same numbers every run.
The page calls `seed(Date.now())` before each game; a local experiment that wants different games needs a seed of its own.

## Where else to look

- [The Blimp home page](../) is the state of the language and the site it runs on, with the known gaps listed by name: strings are bytes, actors are never collected, the server is one thread.
- [The playground](../blog/playground.html) is a REPL in the browser.
- [The web framework guide](../web/) is Blimp on the server: routes, request bodies, sessions and CSRF, written in Blimp. It is an open pull request, not deployed.
- [Rooms and presence](../web/rooms.html) is the server-side piece a spectator mode or a networked versus game would sit on: one hub actor, `:join`, `:broadcast` and a `:flush` per tick. Also unmerged, and it needs an interpreter with `tcp_write_some`. A frame would have to cross the wire as JSON, and not all of it survives the trip: `json_decode(json_encode(%{m: :left, t: {1, 2}}))` gives back `{:ok, %{m: "left", t: [1, 2]}}`: the atom is now a string and the tuple a list.
- The language design notes in `docs/lang_design/` are background reading on actors, views, sessions and the parser. Where they disagree with what the interpreter does, the interpreter is right.

That's the end of Tetris.
The game you play in chapter 8 is the one on [bobbby.online/tetris](https://bobbby.online/tetris), actor for actor.
[Chapter 10](#ch10) leaves the game for a page made of forms and lists, a guestbook, and the rest of what Blimp's view can do.

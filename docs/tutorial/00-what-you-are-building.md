# Chapter 0: What you are building

Tetris, written as seven actors that only ever talk by sending each other messages.
By chapter 8 it runs in this page, and every rule in it is code you wrote.

## Play it first

Open the **Play** tab on the right and press **Play the finished game**.
Arrow keys move, up or `x` rotates, down drops a row, space drops the piece all the way, `p` pauses, `r` restarts.
The buttons under the board do the same thing, for a phone.

Nothing in that game is JavaScript.
The page hands every key press and every timer tick to one actor as a message, asks that actor for the screen, and draws what comes back.
The screen is a value: a heading, a block of coloured squares, some text, a row of buttons.
Where the pieces fall, what counts as a full line, how fast level 3 is: all of it is in `docs/blog/tetris.blimp`, 801 lines of Blimp including its tests.

## The seven actors

| Actor | Owns | Chapter |
|-------|------|---------|
| `Tetris.Piece` | the falling piece: its kind, rotation, column and row | 1, 2 |
| `Tetris.Shapes` | the table of what each kind looks like in each rotation | 2 |
| `Tetris.Board` | the well, 20 rows of 10 cells, 0 for empty and 1..7 for a locked piece | 3, 4 |
| `Tetris.Score` | score, lines, level, and how fast pieces fall | 4 |
| `Tetris.Bag` | which piece comes next | 5 |
| `Tetris.Game` | the other five, plus the next kind and whether the game is paused or over | 6, 7 |
| `Tetris.Screen` | how a game looks, as a view value | 8 |

There is an eighth, `actor Tetris`, with one field and no handlers.
It sits at the top of every file and holds the name the other seven are grouped under.

Who talks to whom:

```
     key presses and timer ticks from the page
                       |
                       v
                  Tetris.Game
     /        /        |        \          \
   Bag     Board     Piece     Score     Screen
                       |                   |
                    Shapes              Shapes
```

`Tetris.Game` is the only actor the page talks to.
It never looks at a cell of the board or a coordinate of the piece itself.
It asks the piece where its cells would be if it moved, asks the board whether those cells fit, and tells the piece to move only if the answer is yes.

The Piece and the Screen each get a `Tetris.Shapes` from a state default, so a running game has two.
The shape table never changes, so nothing is lost by keeping two, and neither actor has to be told where the other one's table is.
(A state default runs once, when the actor is defined, not once per spawn; chapter 2 shows what that means.)

## The chapters

Each chapter adds one actor, or finishes one, with tests you make pass.

1. **The falling piece.** `Tetris.Piece` knows its kind, rotation and position, and can move and turn. It does not know its shape yet.
2. **Shapes are data.** Seven kinds, four rotations, four cells each, written out as a table. The piece asks `Tetris.Shapes` where its cells are.
3. **The board.** `Tetris.Board` answers the question the whole game rests on: do these cells fit? Then it locks a landed piece into the grid.
4. **Clearing lines, keeping score.** The board sweeps full rows away. `Tetris.Score` pays for them, counts levels, and says how many milliseconds a row of gravity takes.
5. **The bag.** Not a dice roll: `Tetris.Bag` deals all seven kinds in a shuffled order and then shuffles again, so you never wait more than twelve pieces for the one you need.
6. **The game takes input.** `Tetris.Game` is handed the other actors when it is spawned and turns left, right, rotate and down into messages to them, wall kicks included.
7. **Gravity, landing, game over.** A timer tick is one row of gravity. A piece that cannot fall locks, the full rows go, the score is paid, the next piece spawns, and if it spawns into something the game is over.
8. **The screen, and playing it.** `Tetris.Screen` turns one map describing the game into a view. When the tests pass, **Play my code** runs your game instead of mine.
9. **Where to take it.** Hold piece, a longer next queue, T-spins: extensions you set yourself, and where to look next.

## How this page works

The chapter text is in the middle.
The pane on the right has three tabs.

**Editor** holds the chapter's exercise file.
The actors finished in earlier chapters are at the top, already done; nothing there needs changing.
They come first for a reason you will meet in chapter 2: defining an actor runs its state defaults, and some of those defaults spawn another actor, which has to be defined already.
Below them is this chapter's work.
Every handler you need to write is marked `# Exercise:` and replies `:TODO`.
**Run Tests** (or ⌘⏎) runs the file's tests and lists which pass.
**Reset to stub** puts the file back the way it started.

**Cheat** has the finished file for the chapter.
**Copy to editor** replaces what you have with it.
Try the exercise before you open it; the chapters are written so that you can.

**Play** runs the finished game on every chapter, and your own game on chapter 8.
Leaving the tab stops the game.
The page seeds the random number generator from the clock before each game, otherwise every game would deal the same pieces in the same order.

## Running it on your machine

Everything also runs from a terminal.
Build the interpreter once:

```
$ cd chunks/lang && zig build
```

That gives you `chunks/lang/zig-out/bin/blimp`; put it on your `PATH` or call it by that path.
From the repository root, run a chapter's tests with `--test`:

```
$ blimp exercises/ch01_piece/01_piece.blimp --test
...
  FAIL Tetris.Piece > move adds to x and y
    assertion failed

  FAIL Tetris.Piece > rotate wraps both ways
    assertion failed

4 failed, 0 passed, 4 total
```

That is the untouched chapter 1 file: four tests, all red, exit status 1.
Edit the file, save, run it again.
The finished game passes all of its own tests the same way:

```
$ blimp chunks/lang/examples/tetris.blimp --test
....
34 tests passed
```

Without `--test`, `blimp FILE` runs the file's top-level code and prints only what the code prints.
For the game that is nothing at all: the file ends by asking the game for its view, and only a host like this page knows how to draw one.
One more difference from the page: the terminal `blimp` does not seed its random numbers either, so `random` gives the same sequence on every run unless the file calls `seed` itself.

Every exercise is one file.
There is no project, no package manager and no build step per exercise.

## Why actors, for a game

An actor is a small thing with private state and a mailbox.
Nothing outside it can read or change that state.
You send it a message, it handles the message, it replies.
It handles its mail one message at a time, in order, and each handler runs to the end before the next message is looked at.

Picture a dispatcher with a clipboard.
Calls come in; the dispatcher reads the clipboard, updates it, answers the caller.
Two calls at once wait in line.
There is one clipboard and one pair of eyes on it, so it never ends up half updated.

Tetris is a good fit because it has exactly the problem that rule solves.
A key press and a gravity tick can arrive at the same moment.
In a program where both could run at once, the tick could check that the row below is free, the key press could slide the piece sideways into a gap, and then the tick could move the piece down into a cell it never checked.
The usual fix is a lock around every move.
In Blimp the fix is the mailbox: `Tetris.Game` handles the tick or the key press, then the other, and the second one sees the piece where the first one left it.
You will not write a lock anywhere in this course.

The other thing actors give a game is small pieces that can each be tested alone.
The board does not know there is a piece; it answers "do these cells fit?".
The score does not know there is a board; it is told how many lines were cleared.
Until chapter 6 every test spawns one or two actors, sends them messages and checks the replies, and no test in the course needs a screen to run.

That split has a name: a functional core and an imperative shell.
Most of the game is the core, where a message and the current state go in and a reply and the next state come out, and tests are cheap and exact.
The shell is the part that touches the world: the keyboard, the clock, the pixels.
In this game the shell is small on purpose.
Even the screen is a value that chapter 8 tests before you ever look at it, and the last thing you do is play the game, because no test tells you whether it is fun.

## A note on credentials

I am a novice at programming language design and at the actor model.
I have read the Erlang docs and Hewitt's papers, and taken ideas from Elixir and Pony and wherever else they looked good.
If you come from one of those, some things here will feel familiar and some a little off.
If something looks wrong, it might be; file an issue.

Chapter 1 starts with the smallest actor in the game: the piece that is falling right now.

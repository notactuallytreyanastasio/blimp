# Build Tetris in Blimp

Ten chapters that build the Tetris running on [bobbby.online/tetris](https://bobbby.online/tetris), one actor at a time. Each chapter has an exercise: a Blimp file with some handlers left as `reply :TODO`, and the tests that say when they are right. The last one plays the game you wrote.

Read it at [blimp.bobbby.online/tutorial/](https://blimp.bobbby.online/tutorial/). The page runs the interpreter as WebAssembly, so the editor, the tests and the game all run in the browser.

## Chapters

| Ch | Title | Actor | Exercise |
|----|-------|-------|----------|
| [00](00-what-you-are-building.md) | What you are building | all seven, finished | none |
| [01](01-the-falling-piece.md) | The falling piece | `Tetris.Piece` | `exercises/ch01_piece` |
| [02](02-shapes-are-data.md) | Shapes are data | `Tetris.Shapes` | `exercises/ch02_shapes` |
| [03](03-the-board.md) | The board | `Tetris.Board` | `exercises/ch03_board` |
| [04](04-lines-and-score.md) | Clearing lines, keeping score | `Tetris.Score` | `exercises/ch04_lines_and_score` |
| [05](05-the-bag.md) | The bag | `Tetris.Bag` | `exercises/ch05_bag` |
| [06](06-the-game.md) | The game takes input | `Tetris.Game` | `exercises/ch06_game` |
| [07](07-gravity.md) | Gravity, landing, game over | `Tetris.Game` | `exercises/ch07_gravity` |
| [08](08-the-screen.md) | The screen, and playing it | `Tetris.Screen` | `exercises/ch08_screen` |
| [09](09-where-to-take-it.md) | Where to take it | | none |

## Running an exercise locally

Build the interpreter (`cd chunks/lang && zig build`), then:

```
$ chunks/lang/zig-out/bin/blimp exercises/ch01_piece/01_piece.blimp --test
```

Fill in the handlers marked `# Exercise:`, save, run again. The answers are in each chapter's `solutions/` directory.

## Where the exercises come from

The finished game is [`chunks/lang/examples/tetris.blimp`](../../chunks/lang/examples/tetris.blimp), and the exercises are cut from it: each file carries what earlier chapters built, finished, and then the chapter's own actor with its tests. Most of the tests are the game's own. A few are new, for things only one chapter can check, like the wall kick in chapter 6 and a line clear through the whole game in chapter 7.

Earlier chapters' actors come first in every file. That is not tidiness: defining an actor runs its state defaults, and `state shapes: Tetris.Shapes :: spawn Tetris.Shapes` fails if `Tetris.Shapes` is defined further down.

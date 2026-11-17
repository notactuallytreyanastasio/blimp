# Nine of 34 Examples Had Stopped Running, and make check Now Runs 32 of Them

*November 16, 2026*

If you clone Blimp and try the examples one at a time, nine of the 34 in `chunks/lang/examples/` stop with an error, and on chapter 80 `make check` passes anyway: it ran three examples, under `--test`. This branch fixes six of the nine and adds a suite that runs 32 of the 34 the way a newcomer would.

We ran every example but the Bluesky client on both, from scratch copies, with a `claude` first on our PATH that only logs its calls, stdin closed and a 20 second timeout. On chapter 80 six exit 1, and its `known.json` records the Hole demos stopping at `NOT AN ACTOR`. On this branch `bank`, `geometry`, `supervision` and `marketplace` exit 0, and `bank` and `geometry` also compile, printing `700` and `37`.

## Parameter types the checker has wanted since March

Three of the files declare handler parameters without types:

```
$ blimp examples/bank.blimp
Type error at line 4, col 3: handler parameter 'amount' is missing a type annotation
...
6 type error(s) found.
```

The checker has required those types since March 21; these files ran under `--no-type-check` until that flag went on March 27. Most of the fix is `amount: Int`. `Actor` looks like the type for `:transfer`'s two accounts, but Blimp has no actor supertype and the checker reads it as an actor named Actor. They are typed `Account`; a probe with `Actor` gets:

```
Type error at line 14, col 18: argument 1 to :peek expected Actor, got Account
```

`geometry` had a second fault behind the first. With its parameters typed, it stops on its last line:

```
-- RUNTIME ERROR
  TypeError while evaluating this.
13| p.x + p.y
```

The interpreter refuses to read an actor's state from outside it; a three-line `print(p.x)` probe gets the same TypeError. The tutorial says state is private, so the example was wrong, though the error message doesn't say why. The program now ends with `p <- :move(10, 20)`, whose reply is the 37 it wanted. The checker accepts `p.x`, and `blimp-compile` reads the field straight out of the state struct; both disagreements are reported, not changed.

## Supervision means what it says

`marketplace` stopped on day 4, sending `:deposit` to an Institution, which has never had that handler. Adding one moved the crash to an uncaught bubble at line 41, on day 5. The money had gone missing two days earlier.

On day 3 a thief tries to take 1000 from bob's account. The account refuses with `bubble :insufficient_funds`, and the thief catches it with `orelse`. By then the bubble has already restarted bob's account under its supervisor, with its template's defaults. Reduced:

```
a = spawn Bank.Account, balance: 500
print(a <- :withdraw(1000) orelse :refused)    # :refused
print(a <- :balance)                           # 0
```

The thief failed and bob lost his money anyway. `supervision.blimp` exists to show exactly this reset, so we changed the example.

The quick fix would have been an `orelse` around the withdraw in `:buy`. That stops the crash, but `:charge` above it would still book revenue whether bob paid or not. So `:buy` replies `:declined` when neither wallet nor account covers it, and `:charge` takes nothing for a declined sale. We have left one question open: should a restart go back to the values the actor was spawned with?

A plain run throws a bare send's value away, so the final report printed nothing. It uses `print` now, as do `supervision`'s state checks:

```
800
3
:caught
0
0
```

## Hole demos that a run had rewritten

A Hole is a `_ # Hole: ...` branch that the interpreter fills at run time. It shells out to `claude -p`, runs the answer and writes it into the source file in place of the Hole. The three Hole demos were written on March 27, the last day on which declaring an actor also spawned an instance named after it. They now spawn their actors and pass them in.

An inline `spawn` is greedy: in `spawn Publisher, sanitizer: spawn Sanitizer, classifier: spawn Classifier`, the inner spawn takes every `key: value` after it, and a probe of that shape stops at NOT AN ACTOR. So the spawns go on lines of their own.

The commit that removed `--no-type-check` also checked in two of `game_rules`' Holes and one of `content_pipeline`'s already filled, and it doesn't say so. A run of the interpreter had written that code, and left the directives' later lines as comments under it. The `:check_winner` fill doesn't work. We copied chapter 80's Board into a file with no Holes and gave it two boards that a player has won:

```
cells [1,1,1, 0,0,0, 2,2,0], move_count 5   ->  nil
cells [2,0,0, 0,2,0, 1,1,2], move_count 5   ->  nil
```

The Holes are back with their full directives. `content_pipeline`'s Sanitizer, meant to collapse whitespace, replied with the first word of its input; it joins the words with single spaces now. Run from copies with the logging stub, `rate_limiter` prints `:allowed` and `game_rules` prints `:illegal` and `%{}`, both exiting 0. `content_pipeline` stops at a TypeError on `lookup(classification, "label")`, because its unanswered Hole hands the Scorer a nil. Each logged one call, and no copy changed.

## Running everything, without spending money

`scripts/run_examples.sh` runs every example and requires exit 0, except for a table at its top. `bank_account`, `checkout` and `content_pipeline` are listed `fail`; the first two are sketches in syntax the parser has never accepted, now with headers saying so. A `fail` entry that starts exiting 0 is a failure, and so is a listed name with no file. We made the script go red all three ways on a copy of the examples:

```
FAIL  counter exited 1:
      15| c1 <- :incremnt
FAIL  counter exits 0 now; take it out of the exceptions in scripts/run_examples.sh
FAIL  nosuch is in the exceptions but examples/nosuch.blimp does not exist
```

The Hole demos were the hard part. A plain run inside `make check` would send prompts to a paid model and rewrite the examples, and skipping them would let them break unseen again. The first version ran only the listed demos from a copy with a `claude` that prints nothing, and everything else in place with your PATH and no time limit. That left `hole_test.blimp`, whose Hole nothing reaches yet, one edit away from calling a model. A reviewer caught that and the missing time limit, and the chapter's last three commits fix both.

Now every example runs from a copy, with the silent `claude` first on PATH, under a 20 second bound (`EXAMPLE_TIMEOUT`). We tested that against a fake `claude` that answers `reply :filled`; run bare, a scratch probe that reaches a Hole calls it and rewrites itself. Through the suite, with that probe, a `spin` loop and a ten-minute `sleep_ms` added, and `EXAMPLE_TIMEOUT=3`:

```
FAIL  bench_btree ran past 3s and was killed
FAIL  zz_loop ran past 3s and was killed
FAIL  zz_wait ran past 3s and was killed
Holes reached (answered by the stub, nothing written back): content_pipeline x1, game_rules x1, rate_limiter x1, zz_hole_probe x1
fake calls: 0
```

No file changed. `test/diff/run.py` gives every program the same silent `claude` and takes the demos back. `make check` passes, running 32 examples and skipping 2, and our logging stub saw no calls.

## What it doesn't catch

Exit 0 is a low bar: 24 of the 32 examples the suite runs print nothing, `counter` and `bank` among them, since they end on a bare send. The suite shows they run without an error. `run.py` runs programs in place (`lib/` and `test/` programs may load neighbours), so there only the empty answer keeps a reached Hole from rewriting its file. `content_pipeline` passes only as an expected failure, and the one run that would finish it, with a real `claude`, also rewrites it.

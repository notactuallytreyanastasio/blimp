# make check Said All Suites Passed While the Compiler Would Not Build

*November 16, 2026*

Chapter 75 ended with a sentence that should have bothered us more: `make check` doesn't run the compiled fixtures or the diff harness. Here is what that looked like, from a fresh checkout of chapter 75 on the machine we work on:

```
$ zig build
install
+- install blimp-compile
   +- compile exe blimp-compile ReleaseSafe native failure
error: warning: unable to open library directory '/opt/homebrew/opt/llvm@20/lib': FileNotFound

$ make check
...
-- tree-sitter test: ok

all suites passed
```

The default build fails and the health check is green. `build.zig` linked `blimp-compile` against a hard-coded llvm@20. This machine has llvm@22 and llvm@23. And `scripts/check.sh` only ever built the interpreter and the wasm target, so the compiler could be broken in any way at all and the check would not notice.

On this branch, with no flags:

```
$ make check
...
blimp-compile: LLVM at /opt/homebrew/opt/llvm@22 (first of build.zig's list that exists; -Dllvm overrides)
-- build blimp-compile (LLVM found by build.zig): ok
compiled fixtures: 23 passed, 0 failed
-- compiled fixtures: ok
146 programs (9 excluded)
...
OK: every program agrees or matches its known.json entry
-- diff harness: ok

all suites passed
```

## The obvious version passes on a broken build

The first thing you'd write is three lines at the end of `check.sh`: `zig build`, then `sh test/compiled/run.sh`, then `python3 test/diff/run.py`. That passes when the build fails, because a failed `zig build` leaves the previous binary where it was:

```
$ stat -f '%z %Sm' zig-out/bin/blimp-compile
928288 Nov 16 21:16:38 2026
$ zig build -Dllvm=/nope/llvm >/dev/null 2>&1; echo $?
1
$ stat -f '%z %Sm' zig-out/bin/blimp-compile
928288 Nov 16 21:16:38 2026
$ sh test/compiled/run.sh | tail -1
compiled fixtures: 23 passed, 0 failed
```

The fixtures were testing a compiler from an earlier build. So `check.sh` records whether `blimp-compile` built in this run, and the two test suites refuse to run if it didn't:

```
$ make check LLVM=/nope/llvm
error: blimp-compile: -Dllvm=/nope/llvm has no lib/libLLVM.dylib or lib/libLLVM.so (an absolute path is required). ...
-- build blimp-compile (LLVM /nope/llvm): FAILED
not run: blimp-compile did not build in this run
-- compiled fixtures: FAILED
not run: blimp-compile did not build in this run
-- diff harness: FAILED
FAILED: build blimp-compile (LLVM /nope/llvm) compiled fixtures diff harness
```

The interpreter suites above them still pass. A machine with no LLVM loses three named suites and keeps the rest. `zig build interp` and `zig build test` don't depend on LLVM at all and still exit 0 with a bad `-Dllvm`.

We also planted two bugs to make sure the new suites can fail. We changed one expected value from 101 to 102 and added a corpus program the compiler refuses. Both came back red: `compiled fixtures: 22 passed, 1 failed` and `NEW test/diff/corpus/zz_planted.blimp`.

## Which LLVM

`build.zig` now looks for one. `-Dllvm=PREFIX` always wins, and a prefix with no libLLVM in it is an error rather than a hint to go looking elsewhere, since whoever typed it meant that one. Without the flag it tries llvm@22, then llvm@23, each in Apple Silicon Homebrew's, Intel Homebrew's and apt.llvm.org's layout, then llvm@20. After that it asks `llvm-config --prefix` on `PATH`.

The order is oldest-known-good first, which looks backwards. Every `.expected` file and every `known.json` entry was recorded against LLVM 22. If the build preferred the newest version, a `brew upgrade` could change what the harness compares without anyone deciding to. We left the unversioned `/opt/homebrew/opt/llvm` off the list for the same reason. On this machine it is a symlink to 23.1.5 today, and after the next upgrade it will point somewhere else.

Every build of `blimp-compile` prints which LLVM it used, even when nothing was recompiled, so you can always read the version off the log. We built against 23 as well: all 23 fixtures pass and the harness is OK, so the two versions agree on everything recorded so far.

## Two ways to go red on an unchanged tree

Putting the compiler's suites into `make check` made it the gate, so anything that fails without a cause is now a problem. We found two.

The first was tree-sitter. tree-sitter-cli 0.25.10 compiles the grammar to `~/.cache/tree-sitter/lib/blimp.dylib`, one file for every checkout on the machine, and rebuilds it only when `parser.c` is newer than the file. We had several worktrees open at once, one of them with grammar changes, so a checkout with an older `parser.c` was testing the other branch's grammar. We reproduced it without touching the shared file: we copied the cached library into a private directory, made it newer than this tree's `parser.c`, and ran:

```
$ TREE_SITTER_LIBDIR=$d npx --yes -p tree-sitter-cli@0.25.10 tree-sitter test
     65. ✗ Spawn with state overrides
1 failure:
```

The same tree passes in an empty directory. The suite now gets its own temporary `TREE_SITTER_LIBDIR` and deletes it afterwards. `--rebuild` would have looked like the fix, but it still writes the shared file, and the next plain run in some other worktree would then pick up this grammar. A private directory shares nothing with the other worktrees, and the price is one grammar compile per run.

The second was the harness's only flaky program. `actor_reply_string.blimp` replies `"alice"`, and compiled code prints the String as its heap address, which ASLR moves on every run. The harness marks a program flaky when its two compiled runs differ. We ran the binary 3000 times and got 1916 distinct outputs and one pair of consecutive identical ones. So about once in 3000 runs the two runs print the same address, the program counts as an ordinary divergence instead of flaky, and the whole check fails on code nobody touched.

Now a program that `known.json` lists as flaky and that comes back as something else gets classified again, up to five more times. Nothing else is ever rerun, so a real divergence elsewhere still fails at once. Retrying every program that disagrees would have been simpler, and it would hide a new flaky program instead of reporting it. To test the change without waiting for a coincidence, we wrapped `classify` so the first result for that program was a divergence. The old `run.py` printed `CHANGED` and exited 1. The new one prints:

```
note: test/diff/corpus/actor_reply_string.blimp is listed as flaky and its first two runs agreed; run 1 more time(s) before it varied
OK: every program agrees or matches its known.json entry
```

A flaky entry also used to ignore both sides' output, so the interpreter could change what it printed for that program and the harness would say nothing. With the interpreter's recorded output edited to `"bob"`, the old `run.py` still exited 0. The new fingerprint keeps everything except the stdout that varies, and the same edit now fails with `CHANGED`.

## What is still open

We only built against Homebrew's llvm@22 and llvm@23 on macOS. The Intel Homebrew and apt.llvm.org paths, llvm@20 and a Linux `llvm-config` are on the list without having been tried. `-Dllvm` wants an absolute path and refuses a relative one with the same "has no lib/libLLVM" message. A program that is truly flaky and happens to print the same address six times in a row will still read as changed. The bug behind all of this, a compiled String reply that prints as a number, is still there.

The full check took 1m14s here, against 59s before. The harness is about ten seconds of that and the fixtures about two.

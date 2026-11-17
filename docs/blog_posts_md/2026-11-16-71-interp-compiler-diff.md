# The Compiler Says 10 / 0 Is 1

*November 16, 2026*

Blimp has two ways to run a program. `blimp` is the tree-walking interpreter behind the REPL and `zig build interp`. `blimp-compile` turns the same source into LLVM IR and links a native binary. Nothing in the repo had ever run the two on the same programs and compared what came out, so this chapter builds a harness that does. The two disagree on a lot. The worst case fits in two lines:

```
x = 0
10 / x
```

The interpreter stops with a DIVISION BY ZERO report and exits 1. The compiled binary prints `1` and exits 0.

## Getting the compiler to build

The first job was getting `blimp-compile` to exist again. The zig 0.16 Io refactor ported `main.zig` and skipped `compile_main.zig`, and `build.zig` pointed at `/opt/homebrew/opt/llvm@20`. Everything else goes through `zig build interp`, and nobody noticed either break. With the LLVM path fixed by hand, the old tree stops here:

```
src/compile_main.zig:47:36: error: member function expected 4 argument(s), found 3
    const source = std.Io.Dir.cwd().readFileAlloc(allocator, input_file, 1024 * 1024) catch |err| {
```

The port copies what `main.zig` already did: build a Threaded Io in `main` and pass it to the file calls. `codegen.zig` needed no changes and builds against LLVM 22 untouched. There is a new `-Dllvm=` option for the prefix. Its default is still llvm@20, so on a machine that only has llvm@22 you need the flag:

```
cd chunks/lang
zig build -Dllvm=/opt/homebrew/opt/llvm@22
ls zig-out/bin
# blimp  blimp-compile
```

This needs zig 0.16.0.

## Giving the two something to compare

A compiled Blimp program has one output, the value of its last top-level expression. `blimp FILE` evaluates that expression and throws the value away, so a naive comparison puts an empty string next to a `3`. The new `--print-last` flag prints that value the way the REPL would:

```
$ printf '1 + 2\n' > p.blimp
$ zig-out/bin/blimp p.blimp
$ zig-out/bin/blimp p.blimp --print-last
3
$ zig-out/bin/blimp-compile p.blimp -o p && ./p
3
```

Without the flag, a run behaves as it did before, and the corpus keeps one file marked `# diff: plain` so the harness still records that the plain run prints nothing where the binary prints `3`.

## The harness

`test/diff/run.py` takes every program in `test/diff/corpus` plus `examples/`, `examples/errors/`, `test/` and the `lib/*_test.blimp` files. It runs each one through `blimp --print-last` and through the compiler and binary. Each side runs twice, and a program whose two results differ goes in the `flaky` bucket. It compares stdout byte for byte and exit status exactly. The two error renderers share no text, so for stderr it only checks whether anything got printed.

At the tip of this chapter's branch the run prints:

```
$ python3 test/diff/run.py
144 programs (9 excluded)
  agree          55
  both-reject    8
  unsupported    14
  compile-error  39
  diverge        25
  crash          1
  flaky          2

OK: every program agrees or matches its known.json entry
```

The 55 that agree and the 8 that both sides reject need no entry. The other 81 each sit in `test/diff/known.json` with both sides' output recorded. The run exits 1 when a program diverges without an entry, and also when a listed program starts agreeing, changes its output or drops out of the corpus. An allow-list that only complains about new entries would keep a stale entry for every bug someone fixed. With this one, a fix turns the run red until whoever made it deletes the entry.

You can watch it fail by planting a bug. This wrapper hands the real compiler a copy of the program with `max(` rewritten to `min(`. Set `real` to your own checkout; the harness runs the compiler from a temp directory, so a relative path will not resolve.

```sh
#!/bin/sh
real=/path/to/blimp/chunks/lang/zig-out/bin/blimp-compile
src=$(mktemp -d)/planted.blimp
sed 's/max(/min(/g' "$1" > "$src"
shift
exec "$real" "$src" "$@"
```

```
$ python3 test/diff/run.py --compiler ./minmax.sh --only builtin_m
NEW test/diff/corpus/builtin_max.blimp
...
    "stdout": "7\n",
...
    "stdout": "3\n",
...
FAIL: 1 program(s) differ from known.json
```

`builtin_min_negative` matches the filter too and still agrees, since it has no `max(` for the wrapper to rewrite.

## What the list says

Of the 53 programs that `blimp-compile` refuses, 14 say why: `Codegen error: error.UnsupportedNode`. The other 39 die in LLVM verification, at the link, or on `error.UndefinedVariable`. Most of those trace back to one branch in `codegen.zig`. A call to any name the compiler does not know becomes a call to an extern C function of that name that takes and returns i64. The comment above that code says it calls `blimp_<name>`, but the code uses the bare name. So `rem(17, 5)` fails to link on `_rem`, and calling a closure `f` fails on `_f`. When libc happens to have the name, the program links and runs. `abs(0 - 5000000000)` gets C's 32-bit `abs` and prints `705032704`. `puts(3)` passes 3 to libc's `puts` as a pointer and segfaults.

The divergences that would hurt a user exit 0 with a believable answer:

```
x = 0; 10 / x                          interp DIVISION BY ZERO, exit 1   compiled 1, exit 0
(0 - 9223372036854775807 - 1) / (0-1)  interp -9223372036854775808      compiled 1
x = 5; case x do 1 -> 10 end           interp nil                       compiled 0
n = 3; "n is #{n}"                     interp "n is 3"                  compiled "n is #{n}"
```

An uncaught bubble from a handler and a send to a handler that does not exist do the same thing: an error and exit 1 in the interpreter, `0` and exit 0 compiled. The compiled printer also loses track of types. `true && false` prints `0`, an Atom reply prints its intern id, and a String reply prints a heap address that ASLR moves on every run. Those addresses make up both `flaky` entries. Floats print with `%g`, so `0.1 + 0.2` comes out `0.3`.

Integer overflow wraps on both sides, Int and Float mix the same way, `fib` matches, and a 100000-deep tail call runs compiled without trouble. Actors that reply with Ints agree, and so does `orelse` catching a bubble from a send. Two matching outputs can still both be wrong: `2.0` prints as `2` on both sides.

The last commit adds two programs that the float-to-int work in the next chapter reported as not compiling: `[1.5, 2.5]` and `to_int(1.5)`. The harness flagged both as NEW until they went into `known.json`. They fail verification for different reasons. `to_int` goes through the unknown-name fallback. The list literal boxes each element with `blimp_val_int`, which expects an integer, and hands it a double.

## What it does not cover

The harness ignores `test` blocks, because a plain run defines them and never runs them. It does not look at the WASM build or `--self-hosted`. Nine programs are left out by name because they need the network or a terminal, or they are benchmarks. `make check` does not run the harness yet, so for now you build both binaries with `-Dllvm` and run `python3 test/diff/run.py` yourself.

The next few chapters fix entries on this list, starting with float-to-int conversion, and the counts above move as they land.

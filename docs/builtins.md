# Builtins

A reference for the functions the interpreter provides without an `import`. The registry is `BuiltinRegistry.init` in `chunks/lang/src/builtins.zig`; this page follows its groupings.

It does not describe every builtin yet. Each section below has full entries (signature, what it returns, what it raises, an example) for the builtins listed under it, and then a line naming the others in the group that have no entry here. Where an entry's example shows output, the output was checked against a run of `chunks/lang/zig-out/bin/blimp`.

Every builtin that refuses its arguments raises a runtime error that points at the call (`TypeError while evaluating this.`, with the source line under it). Where a builtin has something more specific to say, as `sqlite_query` does with sqlite's own message, the entry says so.

Builtins marked **native only** are stubbed in the WebAssembly build. Calling one there raises `NotSupported`; the program still compiles and loads.

## Process

Native only.

### exec(argv, stdin, cwd)

```
exec(argv: List[String], stdin: String, cwd: String | nil) -> [status, stdout, stderr]
```

Runs `argv[0]` (looked up on `PATH`) with the rest of the list as its arguments, writes `stdin` to it, and answers when it has exited. There is no shell: `exec(["ls -l"], ...)` looks for a program named `ls -l`. To use a shell, say so: `exec(["sh", "-c", "ls -l | wc -l"], "", nil)`.

Returns a three-element list: the status (an Int), what the program wrote to stdout (a String) and what it wrote to stderr (a String). A list rather than a map because a Temper program receives lists without help.

The status is the exit code. Three cases are not an exit code:

| status | meaning |
|--------|---------|
| `127`  | `execvp` failed: no such program, or not executable |
| `126`  | `chdir` to `cwd` failed |
| `-N`   | a signal ended it; `-9` is `kill -9` |

126 and 127 are the shell's conventions, used because the child has no other way to report an errno to the parent. A real program that exits 127 looks the same.

`cwd` is the directory to run in, or `nil` for the interpreter's own. Descriptors 3 to 1023 are closed in the child, so it does not inherit the listening socket or a client's connection (`tcp_listen` and `tcp_accept` do not set close-on-exec). Stdout and stderr are drained together with `poll`, and stdin is written in the same loop, so a child that fills its stdout pipe before reading its input does not deadlock (a 1.3 MB payload through `cat` takes 2 ms).

Raises TypeError for an `argv` that is not a list, is empty, or holds anything but Strings; for a String with a NUL byte in it; and for a `cwd` that is neither a String nor `nil`. Raises NotSupported if `pipe` or `fork` fails.

```
exec(["echo", "hi there"], "", nil)
=> [0, "hi there\n", ""]

exec(["sh", "-c", "tr a-z A-Z; echo oops 1>&2; exit 3"], "shout", nil)
=> [3, "SHOUT", "oops\n"]

exec(["pwd"], "", "/usr")
=> [0, "/usr\n", ""]

exec(["no-such-program"], "", nil)
=> [127, "", ""]

exec(["sh", "-c", "kill -9 $$"], "", nil)
=> [-9, "", ""]
```

What it does not do:

- **No timeout.** `exec` blocks the whole interpreter until the child exits, and under `--serve` every other request waits with it. Run something that might hang through `timeout(1)`: `exec(["timeout", "5", "slow-thing"], "", nil)`.
- **No streaming.** Output is collected whole and returned at the end.
- **No environment argument.** The child gets the interpreter's environment.

The design is in [lang_design/processes.md](lang_design/processes.md).

The other builtins in this group, without an entry here: `fork`, `waitpid`, `exit`, `sleep_ms`, `getenv`, `argv`, `read_line`, `process_stats`.

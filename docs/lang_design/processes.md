# Processes

## What exists

`exec(argv, stdin, cwd)` runs another program and answers `[status, stdout, stderr]` when it has finished. It was added for a web application compiled from Temper that has to shell out (to `git`, to `convert`, to `rm`), and it sits beside the older `fork`, `waitpid` and `exit`, which are the tools for a Blimp program that wants a second copy of itself. The entry is in [../builtins.md](../builtins.md#execargv-stdin-cwd).

```blimp
exec(["sh", "-c", "tr a-z A-Z; echo oops 1>&2; exit 3"], "shout", nil)
# => [3, "SHOUT", "oops\n"]
```

Native only. The WebAssembly build stubs it and raises `NotSupported`.

## Why argv and not a command string

A command string goes through a shell, and a shell reads quotes, `$`, backticks and `;`. The first program that built a command from a user's filename would run the user's input. A list of Strings goes to `execvp` as it is: no quoting to get wrong, and a NUL byte in an argument is refused outright because C strings cannot hold one. A program that wants a shell writes `["sh", "-c", ...]`, and then it is plain in the source that a shell is in play.

## Why a list comes back

`[status, stdout, stderr]` and not a map. The caller is usually Temper code, and Temper receives lists without help; a map would need a record type declared on the Temper side and a conversion on this one. `elem(r, 0)` is the cost.

## The status

The exit code, except for three cases that the parent has to tell apart without a side channel:

- A signal ended the child: the negated signal number, so `-9` is a `kill -9`. `waitpid` encodes this as the low seven bits of the wait status, the same on macOS and Linux.
- `execvp` failed: 127. The child is already a separate process by then and can only exit.
- `chdir` to `cwd` failed: 126.

126 and 127 are what a shell reports for the same failures, which is why they were chosen. The cost is that a program that really does exit 127 is indistinguishable from one that was not found.

## Everything is built before the fork

`fork()` in a process with other threads leaves the child with one thread and whatever locks the others held. Between `fork` and `execvp` the child may therefore call only async-signal-safe functions, and `malloc` is not one. So the argv array, the `cwd` and the pipes are all made first, and the child does `dup2`, `chdir`, `close` and `execvp`, nothing else. `blimp --serve` runs an HTTP worker thread for `http_start`, so this is not hypothetical.

## Closing descriptors 3 to 1023

`tcp_listen` and `tcp_accept` do not set `FD_CLOEXEC`. Without a sweep, a program started by `exec` inherits the listening socket and every client socket that is open at that moment, and a client's connection then stays open until the program exits even after the server has closed it. The child closes everything from 3 up to 1023 before `execvp`. A blunt loop, and the limit is not `RLIMIT_NOFILE`: a descriptor above 1023 would leak. A test opens a pipe, asks the child whether `/dev/fd/N` exists, and expects "closed".

## Two pipes to drain, one to fill

The parent writes the whole of `stdin` and reads both outputs, and it does all three in one `poll` loop. Doing them one after another deadlocks: write all of stdin first and a child that echoes as it reads fills its stdout pipe (64 KiB), blocks writing, and never reads again; read stdout first and a child that wants its input before it prints waits forever.

An early version deadlocked on a payload of about 128 KiB or more. `poll` reports a pipe writable when it has room for a few bytes, and a blocking `write` of 64 KiB then waits for room for all of it, while the child is blocked on its own output, which only the parent's loop drains. The stdin end is now `O_NONBLOCK`: `write` takes what fits and the loop returns to reading. The test sends 2 MiB through `cat`; before the change it never finished.

If the child exits without reading its input, the write gets `EPIPE`. `MSG_NOSIGNAL` does not apply to a pipe, so the process would die of `SIGPIPE` unless it ignores it; `blimp --serve` does and a plain run does not. A test of that case is not written.

## What it costs

On this machine (an Apple silicon laptop), 500 calls of `exec(["true"], "", nil)` took 0.7 to 1.1 seconds, a bit over a millisecond and a half each, almost all of it `fork` and the sweep of 1021 `close` calls. 1.3 MB through `cat` took 2 ms. It is not something to call per request in a hot path.

## What it does not do

- **No timeout.** The interpreter blocks until the child exits. Under `--serve` that is every request. The workaround is to put `timeout` in front: `exec(["timeout", "5", "convert", ...], "", nil)`. A real timeout needs a deadline in the `poll` loop and a `kill`; it was left out of the first version because nothing needed it yet, and it is the next thing to add.
- **No environment argument.** The child inherits the interpreter's environment.
- **No streaming.** stdout and stderr arrive whole.
- **No process groups.** If the child starts children of its own and the child is killed, they carry on.

## A forked child owns the socket

`fork()` copies the descriptor table, so after `fork` a connection is open in two processes, as two descriptors that refer to one connection. [concurrency.md](concurrency.md) describes forking a child per connection (its option A): the child handles the connection and exits, and the parent goes back to `tcp_accept`. The parent has to close its copy, or it leaks one descriptor per connection.

The obvious call for the parent is `tcp_close`, and it is wrong. `tcp_close` was written for the other case, a process that has just written a response and is about to forget the socket. It does what nginx's lingering close does: it reads and discards what has arrived, calls `shutdown(SHUT_WR)` so the peer gets its FIN after the last queued byte, and keeps the descriptor open until the peer hangs up or 30 seconds pass. `shutdown` acts on the connection, not on one descriptor. In the parent, with a child about to write, it shuts the child's write side under it.

Measured with a parent that accepts, forks a handler that writes after 300 ms, and closes its copy:

```
CLOSE_WITH=tcp_close   "client read: "
CLOSE_WITH=fd_close    "client read: hello from the child"
```

With `tcp_close` the client reads the end of the stream and no data. With `fd_close` the connection is untouched and the child's write arrives.

`fd_close(fd)` is `close(2)` and one more thing: if the descriptor is on the lingering list it comes off, so the same number is never closed twice. A descriptor number is reused as soon as it is free, and a second `close` of a stale number would close somebody else's socket.

The rule is: the process that wrote the last byte of the response closes with `tcp_close`; a process that handed the socket to a child closes with `fd_close`. A child that is the last to use the socket closes it with `tcp_close`, which is what it was written for.

`fd_close` does not check that the descriptor is open, and it will close any descriptor, a file or a pipe, not just a socket. It is not a safer `tcp_close`, it is a different call.

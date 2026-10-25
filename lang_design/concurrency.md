# Concurrent Connections in Blimp's Web Server

> How to handle multiple connections when the evaluator is single-threaded and all actors share one process.

## The Problem

The HTTPServer actor has a synchronous accept loop:

```blimp
on :accept do
  client_fd = tcp_accept(fd)      # blocks here
  raw = tcp_read(client_fd)       # blocks here
  # ... handle ...
  tcp_write(client_fd, response)
  tcp_close(client_fd)
  HTTPServer <- :accept           # loop
end
```

While handling one request, all others wait. This is fine for a single-user dev server but breaks two things:

1. **WebSockets** -- a WS connection is long-lived. If the accept loop enters a WS read loop, no other connections can be served. Agent 6's WebSocket work is blocked by this.
2. **Multiple browser tabs** -- even for regular HTTP, opening two tabs means one waits for the other.

## Options Evaluated

### Option A: fork() per connection

```blimp
on :accept do
  client_fd = tcp_accept(fd)
  pid = fork()
  case pid do
    0 -> handle_connection(client_fd); exit(0)  # child
    _ -> tcp_close(client_fd); HTTPServer <- :accept  # parent
  end
end
```

**Pros:** Simple. Works today. True OS-level concurrency. Good for stateless handlers.

**Cons:** Each child gets a **copy** of all actor state. The Sessions actor in the child is a snapshot -- any mutations (e.g., incrementing a counter via POST) are lost when the child exits. This makes fork() useless for stateful web apps.

**Verdict:** Implemented as builtins (`fork()`, `waitpid()`, `exit()`), but not used for the main server. Useful for fire-and-forget tasks or read-only endpoints.

### Option B: Non-blocking accept + poll

```blimp
on :poll_loop do
  ready = tcp_poll([fd | ws_connections], 100)
  # handle each ready fd
  HTTPServer <- :poll_loop
end
```

**Pros:** Single process, shared Sessions, handles WS + HTTP together.

**Cons:** More complex. HTTP requests must complete quickly (can't block the poll loop). Requires restructuring WS handling from recursive `ws_loop` to event-driven `handle_ws_event`.

**Verdict:** Implemented. This is the current approach for concurrent connections. See `web/concurrent_server.blimp` for a working example.

### Option C: Actor-per-connection (requires scheduler)

```blimp
actor ConnectionHandler do
  state client_fd: Int :: -1
  on :handle do
    raw = tcp_read(client_fd)
    # ... handle ...
  end
end

on :accept do
  client_fd = tcp_accept(fd)
  handler = spawn ConnectionHandler(client_fd: client_fd)
  handler <- :handle
  HTTPServer <- :accept
end
```

**Pros:** Fits the actor model perfectly. Each connection is an actor with its own mailbox. The scheduler interleaves execution. Sessions actor is shared.

**Cons:** Requires the actor scheduler from `actor-runtime.md` Phase 4. Currently, `handler <- :handle` is synchronous -- it blocks until the handler completes. Until the scheduler makes message sends async and runs actors cooperatively, this is equivalent to the sequential loop.

**Verdict:** This is the design target. When the scheduler is built (per-actor arenas, mailboxes, FIFO run queue), this becomes the natural approach. The poll-based approach is the bridge.

### Option D: Thread-per-connection via Zig

Add a builtin that spawns an OS thread running the Zig evaluator on a connection.

**Pros:** True concurrency, relatively simple.

**Cons:** The Evaluator, Environment, Registry, and BuiltinRegistry are all not thread-safe. Making them thread-safe would require mutexes around every state access, or per-thread copies of the evaluator (which has the same shared-state problem as fork).

**Verdict:** Not feasible without significant Zig-side refactoring.

## What Was Built

### New Builtins (in `src/builtins.zig`)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `fork()` | `() -> Int` | POSIX fork. Returns 0 in child, child PID in parent, -1 on error. |
| `waitpid(pid, nohang)` | `(Int, Bool) -> Int` | Wait for child. nohang=true returns immediately. pid=-1 for any child. |
| `exit(code)` | `(Int) -> never` | Exit current process with status code. |
| `tcp_set_nonblocking(fd)` | `(Int) -> :ok` | Sets a socket to non-blocking mode. |
| `tcp_poll(fds, timeout_ms)` | `(List, Int) -> List` | Poll fds for readability. Returns list of ready fds. timeout -1=block, 0=immediate, >0=ms. |

### Updated Builtins

| Builtin | Change |
|---------|--------|
| `tcp_accept(fd)` | Returns `nil` instead of crashing when socket is non-blocking and no connection pending (WouldBlock). |
| `tcp_read(fd)` | Returns `nil` instead of crashing when socket is non-blocking and no data available (WouldBlock). |

### Example Server

`web/concurrent_server.blimp` demonstrates the poll-based approach:

- Server fd polled with 100ms timeout
- HTTP requests handled synchronously (fast: read, dispatch, write, close)
- Sessions state shared across all connections
- Extensible to include WebSocket client fds in the poll list

## Shared State Model

The critical insight is that **Sessions must be shared across connections**.

| Approach | Sessions shared? | Suitable for stateful apps? |
|----------|-----------------|---------------------------|
| fork() | No (copy-on-write) | No -- mutations lost |
| poll (single process) | Yes | Yes |
| Actor scheduler | Yes (same registry) | Yes -- the target |
| Threads | Needs mutexes | Maybe, with work |

The poll-based approach keeps everything in one process, so the Sessions actor (and all actors) are naturally shared.

## WebSocket Integration (for Agent 6)

The poll loop is designed to support WebSocket connections:

```blimp
actor HTTPServer do
  state fd: Int :: -1
  state ws_connections: List :: []  # list of WebSocket client fds

  on :poll_loop do
    # Poll server fd AND all WS client fds
    all_fds = append([fd], ws_connections)
    ready = tcp_poll(all_fds, 100)

    # Process ready fds:
    #   - If server fd: accept new connection (HTTP or WS upgrade)
    #   - If WS fd: handle one WS event (non-blocking)
    HTTPServer <- :handle_ready(ready)
  end
end
```

Key points for Agent 6:
1. After WS upgrade, add the client fd to `ws_connections`
2. `ws_read_frame` should return nil on WouldBlock (set client fd to non-blocking)
3. Handle one WS event per poll cycle -- don't enter a recursive `ws_loop`
4. When a WS connection closes, remove its fd from `ws_connections`

## Connection Lifecycle

```
New connection arrives:
  tcp_poll returns server fd as ready
  -> tcp_accept(server_fd) -> client_fd
  -> tcp_read(client_fd) -> raw HTTP
  -> Is it a WS upgrade?
     Yes: handshake, add to ws_connections, set non-blocking
     No:  dispatch HTTP, write response, close fd

WebSocket event:
  tcp_poll returns ws_fd as ready
  -> ws_read_frame(ws_fd) -> frame or nil
  -> nil means connection closed, remove from ws_connections
  -> frame: parse event, update state, send patches

HTTP request:
  Read -> dispatch -> write -> close
  Fast, does not block poll loop
```

## Path to the Actor Scheduler

The poll-based approach is a bridge. The real solution is the scheduler from `actor-runtime.md`:

1. **Phase 1** (done): Registry -- actors registered globally
2. **Phase 2** (not done): Per-actor arenas -- memory isolation
3. **Phase 3** (not done): Perceus RC -- efficient memory reuse
4. **Phase 4** (not done): Scheduler -- this is the key piece
   - FIFO run queue
   - Mailbox per actor
   - Async message sends (enqueue, don't block sender)
   - Yield when reductions exhausted
5. **Phase 5** (not done): Supervision

When Phase 4 lands:
- `handler <- :handle` becomes async (returns immediately)
- The scheduler interleaves handler execution
- Each WS connection can be its own actor
- `tcp_accept` can block in one actor without blocking others
- The poll-based approach becomes unnecessary

## Files

```
chunks/lang/src/builtins.zig              -- fork, waitpid, exit, tcp_set_nonblocking, tcp_poll
chunks/lang/web/concurrent_server.blimp   -- working example of poll-based server
chunks/lang/web/server.blimp              -- main server (kept sequential for stability)
docs/lang_design/concurrency.md           -- this document
docs/lang_design/actor-runtime.md         -- scheduler design (Phase 4)
```

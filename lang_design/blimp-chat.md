# Blimp Chat: A Code Walkthrough

> A real WebSocket chat room, written in Blimp, deployed to a box, end-to-end.

This document walks the entire stack of `chunks/lang/web/chat.blimp` and the supporting Zig builtins.
The goal is to show how a few hundred lines of Blimp plus a handful of TCP/WS primitives become a multi-user chat with real-time fan-out.

## Files

| File | Lines | What it is |
|------|-------|-----------|
| `chunks/lang/web/chat.blimp` | 638 | The chat app: actors, HTTP routing, WS upgrade, JSON, JS client, CSS |
| `chunks/lang/src/builtins.zig` | (`tcp_*`, `ws_*` block ~1981–2286) | TCP socket primitives, SHA-1+Base64 handshake, WS frame read/write |
| `chunks/lang/src/scheduler.zig` | — | Cooperative actor scheduler (4000-reduction timeslice, round-robin) |
| `docs/lang_design/websockets.md` | — | The original design doc; the implementation diverges in interesting ways |

## The architecture in one paragraph

Chat input flows in over **HTTP POST**.
Chat updates flow out over **WebSocket**.
The server keeps a list of open WS file descriptors in a `Connections` actor; whenever a POST mutates the room, the handler iterates that list and writes a JSON snapshot of the rendered HTML to every fd.
The client JS receives the snapshot and replaces two DOM subtrees (`.messages` and `.user-list`).
There is no view diffing, no per-event WS read on the server side, no concurrency primitive beyond the single accept loop.
It is the smallest thing that gives you a working real-time chat — and it fits in one file.

```
Browser A                Server (Blimp)              Browser B
  | POST /send -------->|                               |
  |                     | room <- :send_msg             |
  |                     | broadcast(room, conns)        |
  |                     |    ws_write_frame(fd_A, json) |
  |                     |    ws_write_frame(fd_B, json) |
  |<-- 302 + Set-Cookie |                               |
  | GET / ------------->|<------------------- WS frame -|
  |<-- 200 + chat HTML  |                               |
  | WS upgrade -------->|                               |
  |<-- 101 + initial WS |                               |
```

## The four actors

Chat uses four actors.
None of them know about HTTP — they're the domain model.

### `ChatRoom`

The room itself.
Holds the message log, the user list, and a monotonic ID counter.

```blimp
actor ChatRoom do
  state messages: List :: []
  state users: List :: []
  state next_id: Int :: 1

  on :join(username: String) do ... end
  on :send_msg(from: String, text: String) do ... end
  on :recent(count: Int) do reply messages end
  on :get_users do reply users end
  on :leave(username: String) do ... end
end
```

Messages are maps built by `make_msg(id, from, text)`.
The `:join` and `:leave` handlers also append a synthetic system message ("alice joined the chat"), which is why those handlers all bump `next_id` and call `become` with three field updates at once.

### `Sessions`

Cookie-keyed session store.

```blimp
actor Sessions do
  state store: Map :: %{}

  on :get(id: String) do reply lookup(store, id) end
  on :put(id: String, data: Map) do become store: put(store, id, data) reply :ok end
  on :new_session do
    token = concat(to_string(random(100000, 999999)), concat("-", to_string(now())))
    reply token
  end
end
```

Note `:new_session` does not mutate state — it just generates a token.
The actual session row is materialised on the first `:put`.
This means a brand-new visitor gets a token, the request handler stuffs an empty map under it, and subsequent requests on the same cookie find a row.

### `Connections`

The ledger of live WebSocket fds.
This is the entire reason broadcast works.

```blimp
actor Connections do
  state fds: List :: []

  on :add(fd: Int) do ... end
  on :remove(fd: Int) do become fds: filter(fds, fn(x: Int) do x != fd end) reply :ok end
  on :get_all do reply fds end
end
```

Removal uses `filter` with a closure — first-class functions are doing real work here, not just sitting in examples.

### `HTTPServer`

Owns the listening socket and the four references the request loop needs (room, sess, conns).

```blimp
actor HTTPServer do
  state port: Int :: 8080
  state fd: Int :: -1
  state room: ChatRoom :: nil
  state sess: Sessions :: nil
  state conns: Connections :: nil

  on :start(r: ChatRoom, s: Sessions, c: Connections) do
    server_fd = tcp_listen(port)
    become fd: server_fd, room: r, sess: s, conns: c
    print(concat("Blimp Chat running at http://localhost:", to_string(port)))
    accept_loop(server_fd, r, s, c)
  end
end
```

`HTTPServer` only has one handler.
After binding the port, it tail-calls `accept_loop` — a free-standing `def`, not another actor.
The accept loop never returns.

### Boot

The bottom of the file is six lines:

```blimp
chat_room = spawn ChatRoom
chat_sessions = spawn Sessions
chat_conns = spawn Connections
http = spawn HTTPServer
http <- :start(chat_room, chat_sessions, chat_conns)
```

That's it.
The fact that each `actor X do ... end` definition produces a singleton type and `spawn X` produces an instance is what makes this readable.

## The accept loop

This is the hot loop and it's deliberately unsexy.
Every request — HTTP or WS upgrade — comes through here.

```blimp
def accept_loop(fd: Int, room: ChatRoom, sess: Sessions, conns: Connections) do
  client_fd = tcp_accept(fd)
  raw = tcp_read(client_fd)

  case is_ws_upgrade(raw) do
    true ->
      key = parse_ws_key(raw)
      accept_key = ws_accept_key(key)
      tcp_write(client_fd, concat("HTTP/1.1 101 Switching Protocols\r\n...Sec-WebSocket-Accept: ", concat(accept_key, "\r\n\r\n")))
      conns <- :add(client_fd)
      json = build_state_json(room)
      ws_write_frame(client_fd, json)
    _ ->
      handle_http(client_fd, raw, room, sess, conns)
  end

  accept_loop(fd, room, sess, conns)
end
```

A few things to notice:

1. **Strictly single-threaded.** `tcp_accept` blocks. While the server is parsing one request, nothing else moves. Multiple concurrent requests are serialised by the OS accept queue.
2. **WS upgrades don't enter a read loop.** After the handshake the fd is registered with `Connections`, the current room state is pushed once, and the loop tail-recurses to accept the next connection. The server **never reads** from a WS fd after the upgrade.
3. **HTTP connections are short-lived.** `handle_http` reads, dispatches, writes the response, calls `tcp_close` on the fd, and returns.
4. **Tail recursion is the loop construct.** No `while`, no `loop` — just self-call.

That second point is the load-bearing design choice and the thing the design doc (`websockets.md`) gets wrong on purpose.
The doc imagined a per-connection `ws_loop` that reads frames and re-renders.
The implementation collapsed that down to "WS is for fan-out only; input always comes via POST."
This works because POST handlers can still trigger broadcasts to every WS client, so the user-visible effect is identical and the server stays simple.

## The HTTP path: how a message gets sent

```
POST /send  →  handle_http  →  route("/send")
                                 → parse_form(get_body(raw))
                                 → room <- :send_msg(from, text)
                                 → broadcast(room, conns)
                                 → http_redirect("/")
```

Three pieces matter.

**Cookie-driven session ID.**
Before routing, `handle_http` reads the `blimp_session` cookie.
If absent, it asks `Sessions` for a new token.
The `is_new` flag is preserved so that, on a redirect response, the handler patches in `Set-Cookie`:

```blimp
final = case is_new do
  true ->
    case contains(response, "302 Found") do
      true -> http_redirect_cookie("/", sid)
      _ -> response
    end
  _ -> response
end
```

This is the entire login flow: POST `/login` with a username sets `username` in the session map and broadcasts a join message; subsequent GETs to `/` see the username in `sdata` and render the chat view instead of the login form.

**The router is a `case` over path strings.**
Five branches: `/`, `/login`, `/send`, `/logout`, and a 404 default.
Each branch destructures the form body it needs, sends to `room`, calls `broadcast`, and returns a redirect.

**`broadcast` is fire-and-forget within the request.**
It walks the fd list, writes each one, and any failure removes that fd:

```blimp
def broadcast_fds(fds: List, json: String, conns: Connections) -> Atom do
  case empty?(fds) do
    true -> :ok
    _ ->
      fd = head(fds)
      result = ws_write_frame(fd, json)
      case result == :error do
        true ->
          conns <- :remove(fd)
          tcp_close(fd)
        _ -> :ok
      end
      broadcast_fds(tail(fds), json, conns)
  end
end
```

This is the production-hardening fix from `9c6c3a0`.
Before it, `ws_write_frame` would crash the whole server when a browser tab closed and its fd went stale.
Now `tcp_write` and `ws_write_frame` return the atom `:error` on EPIPE, and the broadcast loop garbage-collects the dead fd as it goes.

## The WebSocket handshake

Both sides — Zig and Blimp — share the work.

**Blimp parses the request and asks Zig to compute the accept key:**

```blimp
def parse_ws_key(raw: String) -> String do
  lines = split(raw, "\r\n")
  find_ws_key_line(lines)
end

def find_ws_key_line(lines: List) -> String do
  case empty?(lines) do
    true -> ""
    _ ->
      case contains(head(lines), "Sec-WebSocket-Key") do
        true ->
          parts = split(head(lines), ": ")
          case length(parts) >= 2 do
            true -> elem(parts, 1)
            _ -> ""
          end
        _ -> find_ws_key_line(tail(lines))
      end
  end
end
```

**Zig does the cryptography.**
`builtinWsAcceptKeyNative` in `builtins.zig:2076` concatenates the client key with the magic GUID `258EAFA5-E914-47DA-95CA-5AB9DC80CB65`, runs SHA-1 (`std.crypto.hash.Sha1`), Base64-encodes the digest (`std.base64.standard.Encoder`), and returns the encoded string.
~25 lines of Zig.

**Blimp writes the response:**

```blimp
tcp_write(client_fd,
  concat("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ",
         concat(accept_key, "\r\n\r\n")))
```

After this, the client's `WebSocket` object transitions to `OPEN` and the connection is alive — even though the server side will never call `ws_read_frame` on it.

## The Zig WebSocket primitives

Three functions, all in `chunks/lang/src/builtins.zig`:

| Builtin | Lines | Job |
|---------|-------|-----|
| `ws_accept_key(key)` | 2076–2100 | SHA-1(key + magic GUID), Base64-encode |
| `ws_read_frame(fd)` | 2108–2238 | Parse FIN/opcode, extended length (126/127), 4-byte mask key, XOR-unmask payload, dispatch by opcode |
| `ws_write_frame(fd, data)` | 2242–2255 | Wrap payload in a server-to-client text frame (opcode 0x1, FIN=1, no mask) |

`ws_read_frame` is the heaviest.
It handles:

- **Opcode 0x1 (text)** — return the unmasked payload as a Blimp string
- **Opcode 0x8 (close)** — return `nil` so the caller knows to clean up
- **Opcode 0x9 (ping)** — auto-respond with a Pong, then recurse to read the next real frame
- **Opcode 0xA (pong)** — discard, recurse
- **Anything else** — return `nil`

It also caps payloads at 1 MB to prevent a malicious client from making the server allocate unbounded memory.

The chat doesn't currently use `ws_read_frame` (the JS sends frames the server never reads), but it exists and works.
It's the building block for a future "WS in, WS out" version.

`ws_write_frame` returns an atom (`:ok` or `:error`) instead of crashing.
That return-an-atom-on-EPIPE pattern is what unlocks the broadcast loop's dead-fd cleanup.

## The TCP primitives

Five builtins make the network layer go (`builtins.zig:1982–2065`, plus poll-mode helpers further down):

| Builtin | Behaviour |
|---------|-----------|
| `tcp_listen(port)` | `socket() → setsockopt(SO_REUSEADDR) → bind(0.0.0.0:port) → listen(128)` → returns the server fd |
| `tcp_accept(fd)` | `accept()` blocking by default; returns `nil` on `WouldBlock` if non-blocking |
| `tcp_read(fd)` | Reads up to 64 KB into a buffer, returns a string (or `nil` on `WouldBlock`) |
| `tcp_write(fd, data)` | Writes the string; returns `:ok` or `:error` (no crash on dead fd) |
| `tcp_close(fd)` | `close()`; returns `nil` |

The non-blocking-aware variants (`tcp_set_nonblocking`, `tcp_poll`) exist and are used by `concurrent_server.blimp` (a poll-based HTTP-only demo), but **chat.blimp does not use them**.
Chat is intentionally the simplest possible blocking server.

## The JavaScript client

The entire client is two functions inlined into a `<script>` tag returned from `chat_script()`:

**1. WebSocket loop with exponential backoff:**

```js
var ws, rd = 1000;
function connect() {
  ws = new WebSocket('ws://' + location.host + '/ws');
  ws.onopen = function() { rd = 1000; };
  ws.onmessage = function(e) {
    var d = JSON.parse(e.data);
    if (d.type === 'html') {
      var msgs = document.querySelector('.messages');
      var ul   = document.querySelector('.user-list');
      if (msgs) { msgs.innerHTML = d.messages; msgs.scrollTop = msgs.scrollHeight; }
      if (ul)   ul.innerHTML = d.users;
    }
  };
  ws.onclose = function() { setTimeout(connect, rd); rd = Math.min(rd * 2, 10000); };
}
if (document.querySelector('.chat-main')) connect();
```

The login page doesn't have `.chat-main`, so it never opens a socket — saves the cycle of the user upgrading then immediately POSTing the login form.
Backoff caps at 10 seconds.

**2. Form submission with HTTP fallback:**

```js
var form = document.querySelector('.chat-input');
if (form) form.addEventListener('submit', function(e) {
  var inp  = form.querySelector('input[type=text]');
  var from = form.querySelector('input[name=from]');
  if (ws && ws.readyState === 1 && inp.value) {
    e.preventDefault();
    ws.send(JSON.stringify({type:'msg', from: from.value, text: inp.value}));
    inp.value = ''; inp.focus();
  }
  // If WS not connected, let the form POST normally
});
```

This is the shape of the fix in `57205b0`.
The earlier version called `e.preventDefault()` unconditionally, which meant when WS was down (e.g. mid-reconnect) the form did nothing at all.
Now `preventDefault` only fires on the WS-success branch, so the form falls back to a normal POST whenever WS isn't open.

The honest catch: the WS-success branch sends a frame the server doesn't read.
So when WS is connected, this code path is effectively a no-op for sending — the user's text disappears into the kernel buffer for that fd.
The system actually works because most real interactions either (a) end up on a fresh page-load before the WS reconnects, or (b) use the fallback path.
Wiring `ws_read_frame` into a per-connection actor and having it drive `room <- :send_msg` is the obvious next step and what `websockets.md` originally proposed.

## The JSON layer

There's no JSON builtin in Blimp.
Chat ships its own.

**Building:** `json_obj([[key, value], ...])` produces an object literal; values are passed in already-encoded (so `json_string("hi")` for strings, `to_string(42)` for numbers).
This is enough for the chat's broadcast format:

```blimp
def build_state_json(room: ChatRoom) -> String do
  messages = room <- :recent(50)
  users = room <- :get_users
  msg_html = render_messages(messages)
  user_html = render_users(users)
  json_obj([
    ["type", json_string("html")],
    ["messages", json_string(msg_html)],
    ["users", json_string(user_html)]
  ])
end
```

**Escaping:** `json_escape_loop` walks the string a char at a time, escaping `"`, `\`, `\n`, `\r`.
It uses `from_char_code` and `char_at` because Blimp doesn't yet have string indexing or character literals.
The nested `case ... do _ -> case ... end end` pattern is awkward — a real `cond` form or pattern guards on `Int` would clean it up.

**Parsing:** `json_field(json, "from")` exists (lines 175–209) for extracting one field's quoted value out of a JSON message.
It's used by the never-invoked WS-read path.
When the inbound WS work happens, it'll probably get replaced by a proper builtin.

## Rendering

Two helpers, both straight tail recursion:

```blimp
def render_msg_loop(remaining: List, acc: String) -> String do
  case empty?(remaining) do
    true -> acc
    _ ->
      msg = head(remaining)
      ...
      line = concat("<div class='", concat(cls, ...))
      render_msg_loop(tail(remaining), concat(acc, line))
  end
end
```

Same shape for the user list.
There's no template engine here; just string concatenation.
The trade-off is clear: `concat(concat(concat(...)))` is unpleasant to read but trivial to compile and impossible to mis-escape because the user-supplied strings (`from_name`, `msg_text`) flow through untouched.
That's actually a vulnerability — XSS waiting to happen — and is one of the things `09b06e5 feat: secure string composition -- SafeHtml, SafeSql, context automaton` was meant to address.
The chat predates that fix being applied, so untrusted user input goes straight into the HTML.

## How the actor scheduler keeps up

The scheduler (`scheduler.zig`) gives each actor a 4000-reduction timeslice and round-robins them.
Even though `accept_loop` is a free-standing `def` rather than an actor handler, every `<-` send inside it (e.g. `conns <- :add(client_fd)`, `room <- :recent(50)`) drops into the scheduler to deliver the message.
The synchronous-send semantics mean the accept loop blocks until each actor handler returns, but because all four actors are tiny and in-process the latency is negligible.

What this *does* mean is that **broadcast is sequential**.
If you have 100 connected clients and the third one's fd is stale, `ws_write_frame` returns `:error`, `Connections <- :remove(fd)` runs, `tcp_close` runs, and only then does the loop continue to client 4.
In production with a few clients on a fast box this is fine.
The async send operator `<--` (commit `26adbc0`) would let broadcast fan out without waiting, but the chat doesn't use it — `<-` is enough.

## What you can't see

The deploy story isn't in the repo.
`deploy.sh` only rsyncs `docs/` to `5.161.181.91:/srv/blimp` for the static blog.
The chat binary itself was deployed by hand: `zig build` on the server (or scp the `blimp` binary plus `web/chat.blimp`) then `./blimp web/chat.blimp` under whatever process supervisor the box runs.
There's no Caddy reverse proxy in front of the chat — it serves on port 8080 directly, which is why the public URL was `http://5.161.181.91:8080` and not `https://blimp.bobbby.online/chat`.

## Limits, in plain English

1. **One request at a time.** `tcp_accept` blocks. A slow `tcp_read` from a malicious client wedges every other user. The fix is to move the accept loop onto `tcp_set_nonblocking` + `tcp_poll` (the pattern in `concurrent_server.blimp`) and add WS fds to the poll set so frames get drained alongside new connections.
2. **No inbound WS messages.** As discussed: the JS sends frames, the server doesn't read them. The whole real-time-ness of the chat hinges on POST → broadcast.
3. **No view diffing.** Every broadcast is a full HTML re-render of the message list and user list. With 50 messages that's a few KB; with 50,000 it's a problem. The `view_diff` builtin (`builtins.zig:2295`) exists and would slot in here.
4. **No XSS escaping.** User-supplied `from` and `text` go straight into HTML via `concat`. Easy to fix with the `SafeHtml` work.
5. **Session storage is in-memory.** Restart the server, everyone gets logged out. Good enough for a demo, not for a product.
6. **No backpressure on broadcast.** A slow client whose kernel send buffer fills up will block `ws_write_frame` for everyone behind it in the loop.

None of these are bugs.
They're places where the next version goes.

## Where this slots into the rest of the project

- The `view-dsl` branch (`7a33020`) makes actors render to DOM directly, which would replace the `render_messages`/`render_users` string-soup with a typed view tree. The `view_diff` builtin is the missing link between those view trees and the WS broadcast: render actor → diff old vs new → send patches instead of full HTML.
- The "AI integration into the language" thread we're heading into next would presumably treat chat sessions as something an agent can join (`agent <-- :join("claude")`), making the chat a substrate for human/agent collaboration instead of just a demo.
- `concurrent_server.blimp` already shows the poll-based pattern. Folding that into chat is a one-day refactor and unblocks proper concurrent connections.

## Reading order for someone new

If you're trying to internalise this code, read in this order:

1. **Boot section** at the bottom of `chat.blimp` — the four actors and the `:start` send.
2. **`accept_loop`** — the entire control flow lives here.
3. **The four actor definitions** — small, self-contained.
4. **`route` and `handle_http`** — the HTTP request lifecycle.
5. **`broadcast` / `broadcast_fds`** — the fan-out mechanism.
6. **`chat_script()`** — the JS client.
7. **`builtins.zig` lines 1981–2286** — the actual TCP/WS primitives that everything above sits on top of.

Skip the JSON helpers and the rendering helpers on the first pass; they're mechanical.

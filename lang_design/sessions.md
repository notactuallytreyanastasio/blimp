# Sessions

## What exists

Cookie-based session identity for the Blimp HTTP server. Each browser gets its own session with independent state. The implementation is pure Blimp string parsing in `web/server.blimp` -- no Zig builtins were added.

## Cookie format

```
Set-Cookie: blimp_session=<token>; Path=/; HttpOnly; SameSite=Lax
```

**Token format**: `<random1>-<random2>-<timestamp>` where random values come from `random(100000, 999999)` and timestamp from `now()`. Example: `847293-159482-1711555200`.

**Security flags**:
- `HttpOnly` -- not accessible from JavaScript (XSS protection)
- `SameSite=Lax` -- sent on same-site requests and top-level navigations (CSRF mitigation)
- `Path=/` -- cookie applies to all routes
- No `Secure` flag (dev server runs HTTP, not HTTPS)
- No `Expires` / `Max-Age` -- session cookie, dies when browser closes

**Not cryptographically secure.** The token is generated from Blimp's `random()` (xorshift64 PRNG) and `now()` (Unix timestamp). This is fine for a single-user dev server. For production use, you'd want a `random_bytes(n)` builtin backed by the OS CSPRNG.

## How it works

### Flow: first visit (no cookie)

1. Browser sends GET request, no `Cookie:` header
2. `parse_cookie(raw)` returns `""`
3. `Sessions <- :new_session` generates a token via `generate_session_token()`
4. `initial_state()` creates the default app state
5. `Sessions <- :put(session_id, data)` stores it
6. Response includes `Set-Cookie: blimp_session=<token>; ...`
7. Browser stores the cookie

### Flow: return visit (has cookie)

1. Browser sends `Cookie: blimp_session=847293-159482-1711555200`
2. `parse_cookie(raw)` extracts `847293-159482-1711555200`
3. `Sessions <- :get(session_id)` retrieves stored state
4. Response has no Set-Cookie (cookie already set)
5. User sees their state where they left it

### Flow: POST (button click)

1. Browser sends POST with cookie
2. Session looked up from cookie
3. `handle_event(data, msg)` computes new state
4. `Sessions <- :put(session_id, new_data)` persists
5. Redirect back (PRG pattern) -- cookie preserved

## Cookie parsing implementation

Three-layer pure Blimp string parsing:

1. **`find_header(raw, "Cookie:")`** -- splits raw HTTP on `\r\n`, walks lines looking for one containing the header name, splits on `": "` to get the value
2. **`find_cookie_value(cookie_str, "blimp_session=")`** -- splits cookie header on `"; "` to get individual cookies, walks pairs looking for the target prefix
3. **`parse_cookie(raw)`** -- combines the above, returns session ID string or `""`

The parsing uses `contains()` for matching rather than `starts_with()` (which doesn't exist as a builtin). This means a cookie named `xblimp_session` would falsely match. Acceptable for now since we control the only cookie name.

## Sessions and the actor model

The `Sessions` actor is a centralized state store. Each session maps an ID (String) to app data (Map). This is intentional:

- **One Sessions actor, many session IDs** -- the Sessions actor is the source of truth for all session state
- **Pure functions for state transitions** -- `handle_event(data, msg)` is pure; the actor just stores/retrieves
- **Message passing for coordination** -- `Sessions <- :get(id)` and `Sessions <- :put(id, data)` are the only state access patterns

This design maps cleanly to how LiveView works: a central presence/session registry with per-connection state.

## WebSocket session affinity (future)

When WebSocket support arrives (Agent 6's work), sessions need to work across both HTTP and WS:

**The plan:**
- HTTP requests identify sessions via cookies (current implementation)
- WebSocket upgrade requests also carry cookies -- parse the same way during upgrade
- After WS upgrade, the connection is session-affine -- no need to re-check cookies per message
- The WS connection actor holds a reference to the session ID from the upgrade handshake

**Token reuse:**
- The `blimp_session` token works for both HTTP cookie and WS identification
- On WS upgrade: read cookie, validate session exists, bind WS connection to that session
- If session doesn't exist during WS upgrade: reject the upgrade (require HTTP visit first)

**State ownership question:**
- Currently: Sessions actor owns all state, HTTP handler reads/writes per request
- With WS: the WS connection actor could cache state locally and sync back to Sessions
- Or: WS actor sends messages to Sessions for every state change (simpler, no cache coherence issues)
- Recommendation: keep Sessions as the sole owner, have WS actors send `:get` / `:put` just like HTTP does

## Concurrent connections (interaction with Agent 5)

When the server handles concurrent connections (via fork/scheduler):

- **Cookie parsing is pure** -- no shared state, safe to run in parallel
- **Sessions actor serializes access** -- message passing to a single actor means no race conditions on session state
- **Token generation has a subtle issue** -- `random()` uses a global xorshift state. Two concurrent `generate_session_token()` calls could generate the same token if they execute on the same PRNG state. The timestamp component makes collision unlikely but not impossible. Fix: use process-local PRNG or add a counter.

## Session expiry (not yet implemented)

Design notes for future work:

### TTL-based expiry

Add `last_accessed` timestamp to session store entries. On `:get`, check if `now() - last_accessed > ttl`. If expired, delete and return nil (treated as new session).

```blimp
actor Sessions do
  state store: Map :: %{}
  state ttl: Int :: 3600  # 1 hour

  on :get(id: String) do
    entry = lookup(store, id)
    case nil?(entry) do
      true -> reply nil
      _ ->
        last = lookup(entry, "last_accessed")
        case now() - last > ttl do
          true ->
            become store: put(store, id, nil)
            reply nil
          _ ->
            updated = put(entry, "last_accessed", now())
            become store: put(store, id, updated)
            reply lookup(entry, "data")
        end
    end
  end
end
```

### Max sessions limit

Prevent memory exhaustion by capping total sessions. When limit reached, evict the oldest (LRU). Requires tracking access order, which is harder without a sorted data structure. Simpler alternative: periodic sweep that deletes expired sessions.

### Session data cleanup

A `:cleanup` message that the server sends to itself periodically:

```blimp
on :cleanup do
  # Walk store, delete entries older than TTL
  # Re-schedule: Sessions <- :cleanup after ttl
end
```

This requires a timer/delay mechanism (`after` keyword or scheduled messages) which doesn't exist yet.

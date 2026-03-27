# Blimp Web Framework — State of the Work

> This document is a handoff guide. It describes what has been built, how it works, what the known rough edges are, and what to work on next. Written for an AI picking this up cold.

---

## What was built

A working HTTP web server written entirely in Blimp — no Phoenix, no Elixir, no framework. The stack is:

1. **TCP socket builtins in Zig** — raw POSIX sockets exposed as Blimp builtins
2. **HTML rendering builtin** — `to_html(view_node)` turns Blimp view trees into real HTML strings
3. **`web/server.blimp`** — a complete HTTP/1.1 server + counter app written in pure Blimp
4. **The Hole operator** — `situation` blocks with `_ # directive` that call Claude to fill in missing logic, then patch the source file and re-exec
5. **Type system improvements** — typed lists `[Item]`, record types `%{key: Type}`, and several parser/checker fixes

The counter app at `chunks/lang/web/server.blimp` actually runs:

```
cd chunks/lang
make server       # or: ./blimp web/server.blimp
# then: open http://localhost:8080
```

Clicking the +/- buttons sends a POST, the server handles it, redirects back (PRG pattern), and serves the updated view.

---

## Architecture overview

### Layer 1: Socket builtins (Zig, `src/builtins.zig`)

Five POSIX socket functions registered as Blimp builtins:

```
tcp_listen(port: Int) -> Int       # bind+listen, returns server fd
tcp_accept(fd: Int) -> Int         # blocking accept, returns client fd
tcp_read(fd: Int) -> String        # read up to 64KB
tcp_write(fd: Int, data: String)   # write bytes
tcp_close(fd: Int)                 # close fd
```

These are POSIX-only (native builds). The WASM build doesn't use them.

### Layer 2: HTML rendering (`to_html`, `src/builtins.zig`)

```
to_html(view_node) -> String
```

Walks a `view_node` value tree and emits HTML. Rules:

- `stack(...)` → `<div>` (flex column)
- `row(...)` → `<div data-row>` (flex row via CSS attribute selector)
- `button("label", :msg)` → `<button data-sends="msg" onclick="blimpSend(this)">`
- All string content is HTML-escaped
- `heading`, `text`, `bold`, `italic`, `code`, `code_block`, `blockquote`, `divider`, `list`, `link`, `image`, `video`, `canvas` all map to their HTML equivalents

The `blimpSend()` JavaScript function (inlined in the page) submits buttons as form POSTs with `msg=<atom>` in the body.

### Layer 3: The server (`web/server.blimp`)

Two actors and a collection of pure functions:

**`Sessions` actor** — in-memory session store, maps session id (String) to session data (Map). Currently everyone gets session id `"1"` (single-session — see open issues).

**`HTTPServer` actor** — the accept loop:
1. `tcp_listen(8080)` on `:start`
2. Loop: `tcp_accept` → `tcp_read` → parse method → `dispatch()` → `tcp_write` → `tcp_close` → loop

**Pure functions:**
- `parse_request_line(raw)` — splits the first HTTP line, returns `%{method: ..., path: ...}`
- `dispatch(method, raw, session_id, data)` — routes POST vs GET
- `handle_event(data, msg)` → new data — pure state transition
- `render_app(data)` → view_node — pure render
- `form_value(body, key)` — parses `key=value&...` POST body
- `http_ok(body)` / `http_redirect(location)` — HTTP response builders

The design intentionally mirrors LiveView's architecture: pure `render` function, pure `handle_event` function, actors for state, messages for events. The difference is it's all Blimp.

---

## Building the binary

### macOS 26+ (current machine)

`zig build` is broken on macOS 26 because the build runner itself can't link against the beta SDK. The workaround:

```bash
cd chunks/lang
zig build-exe src/main.zig --name blimp -target aarch64-macos-none -lSystem
```

Or use the Makefile:

```bash
make          # builds blimp binary
make server   # builds + runs web/server.blimp
make test     # compile-checks the lib
make wasm     # rebuild the WASM module
```

The Makefile is at `chunks/lang/Makefile`. The `.tool-versions` in that directory pins Zig to 0.15.2.

### macOS 15 / Linux

`zig build` should work normally on macOS 15 and Linux. The `zig build` runner only fails on macOS 26 beta.

---

## The Hole operator

This is the most novel feature. The semantic distinction is critical:

- **`situation`** — used when the code is **incomplete**. One or more branches is a Hole.
- **`case`** — used for **complete** dispatch. All branches are known. `_` is just a catch-all, not a Hole.

### Syntax

```blimp
situation payment_status do
  :valid -> finalize_payment()
  :expired -> reply :card_expired
  _ # Hole: handle declined payments — log to audit trail, reply :declined
end
```

The `_ # Hole: <directive>` syntax is the trigger. The `_` is the wildcard branch. Everything after `#` on that line is the directive text passed to Claude.

### What happens at runtime

1. Evaluator hits the `_` branch in a `situation` block
2. The branch body is a hole node with a directive
3. `evalHole()` in `eval.zig` is called
4. Builds a prompt: directive + subject value + all visible bindings + first 3000 chars of source file
5. Shells out: `claude -p "<prompt>"`
6. Strips markdown fences from the response
7. Parses the response with `parseHandlerBodyPublic()` — handler body context, so `become`/`reply` are valid
8. Evaluates the parsed statements
9. Patches the source file: replaces `_ # Hole: ...` with `_ ->\n  <generated code>`
10. `execv()` — replaces the current process with a fresh run of the patched file
11. Second run: the hole is gone, the generated code runs directly

### Diff output

When a hole is filled, the runtime prints:

```
╔═══ Hole filled: web/server.blimp:42 ══════════════════
║ - _ # Hole: handle declined payments — log and reply :declined
║ + _ ->
║ +   print(concat("DECLINED: ", to_string(amount)))
║ +   reply :declined
╚══════════════════════════════════════════════════════
```

### The prompt

The prompt sent to Claude (`eval.zig: evalHole`) includes:

```
You are filling in a Hole inside a Blimp actor message handler.
Blimp is an actor-model language. You are writing the BODY of a handler branch.

Syntax:
  Atoms: :ok  :error  :valid  :invalid_code
  State update: become field: value, other_field: value
  Return value: reply :atom  or  reply some_expression
  Match: case expr do :pat -> body  _  -> body  end
  Builtins: put(map, key, val)  lookup(map, key)  concat(a, b)  to_string(v)  print(v)
  Map literal: %{key: value, key2: value2}
  Send message: ActorName <- :message(arg)

Write one or more handler-body statements (become / reply / assignments / expressions).
No explanation. No markdown. No code fences. No surrounding do/end. Just the statements.

Directive: <the # comment text>

Subject value: <the runtime value being matched>

Variables in scope:
  count = 5
  items = [...]
  ...

Source file context:
```<first 3000 chars of the .blimp file>```

Fill in the Hole. Write the handler body statements:
```

### Known prompt quality issues

Claude sometimes returns:
- Lambda syntax (`fn x -> ...`) — Blimp doesn't have lambdas yet
- `filter()` — not a builtin
- Multi-statement code that uses `situation` with wrong indentation

When Claude's response fails to parse as Blimp, the hole evaluates to `nil` and the file is NOT patched. No crash — silent fallback. The hole will trigger again on the next run.

**Improving prompt quality**: The main lever is making the syntax notes section more accurate and comprehensive. The source file context helps a lot — Claude can read the actual actor structure and state fields.

---

## Type system

### What's implemented

**Primitives**: `Int`, `Float`, `String`, `Bool`, `Atom`, `Nil`, `Any`

**Generic collections**: `List` (shorthand for `[Any]`), `Map` (shorthand for `%{Any => Any}`)

**Typed lists**: `[Item]`, `[String]`, `[Product]` — list restricted to a specific element type

**Homogeneous maps**: `%{String => Int}` — all keys of one type, all values of another

**Record types**: `%{name: String, age: Int, tags: [String]}` — named fields with per-field types. This is functionally a struct; Blimp uses map syntax because records are maps at runtime.

**Actor types**: `Counter`, `Shop.Checkout` — any uppercase identifier becomes an actor type

**Tuples**: `{Int, String}`, `{Atom, Any}`

### Record type semantics

```blimp
state profile: %{
  name: String,
  age: Int,
  active: Bool,
} :: %{}

on :greet -> String do
  name = lookup(profile, "name")  # type checker infers: String
  concat("Hello, ", name)
end
```

When `lookup` is called with a string literal key on a record-typed map, the checker returns the declared type for that field. This only works with literal string keys — `lookup(profile, some_var)` infers `Any`.

Record types and map types are mutually compatible at the type level (both are maps at runtime).

### Handler parameters require type annotations

The type checker requires type annotations on all handler parameters:

```blimp
# Good
on :process(text: String, count: Int) do
  ...
end

# Type error
on :process(text, count) do
  ...
end
```

### `case` vs `situation`

The evaluator treats them identically at runtime, but the semantic distinction matters:

- `situation` — code is incomplete; `_` branches with `# directive` are Holes
- `case` — code is complete; `_` is an ordinary wildcard catch-all

The type checker doesn't currently enforce this distinction (a `situation` with all non-hole `_` branches is valid). The distinction is semantic/communicative.

### `case` as an expression

`case` and `situation` can be used on the right-hand side of assignments:

```blimp
result = case method do
  "GET"  -> :read
  "POST" -> :write
  _      -> :unknown
end
```

---

## File evaluation mode

When `blimp <file>` is run, it now evaluates the file (not just prints the AST):

1. Parse with `parseFile()`
2. Type check with `checkFile()` — mandatory, no bypass
3. Evaluate all top-level nodes with `eval()`
4. Actor definitions auto-spawn a singleton instance and bind the `actor_ref` in the environment

The `--ast` flag (`blimp file.blimp --ast`) prints the AST without evaluating, for debugging.

### String escape sequences

String literals process `\n`, `\r`, `\t`, `\\`, `\"` at evaluation time. This was required to make HTTP response headers work (`\r\n`).

---

## View primitives

17 view primitives are implemented in `builtins.zig` and renderable to HTML via `to_html`:

| Primitive | HTML output |
|-----------|-------------|
| `stack(children...)` | `<div>` flex column |
| `row(children...)` | `<div data-row>` flex row |
| `grid(children...)` | `<div>` grid |
| `text(str)` | `<span>` |
| `heading(str)` | `<h1>` (default) |
| `heading(str, n)` | `<h1>`–`<h6>` |
| `bold(str)` | `<strong>` |
| `italic(str)` | `<em>` |
| `code(str)` | `<code>` |
| `code_block(str)` | `<pre>` |
| `code_block(str, :lang)` | `<pre data-lang>` |
| `blockquote(str)` | `<blockquote>` |
| `divider()` | `<hr>` |
| `list(items...)` | `<ul>` |
| `link(label, url)` | `<a href>` |
| `image(src)` / `image(src, alt)` | `<img>` |
| `video(src)` | `<video>` |
| `canvas(id)` | `<canvas>` |
| `button(label)` | `<button>` |
| `button(label, :msg)` | `<button data-sends onclick>` |

---

## Notable builtins added

These were added during this work and weren't in the original builtins set:

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `tcp_listen` | `(Int) -> Int` | Bind+listen on port, return server fd |
| `tcp_accept` | `(Int) -> Int` | Blocking accept, return client fd |
| `tcp_read` | `(Int) -> String` | Read up to 64KB from fd |
| `tcp_write` | `(Int, String) -> nil` | Write bytes to fd |
| `tcp_close` | `(Int) -> nil` | Close fd |
| `to_html` | `(ViewNode) -> String` | Render view tree to HTML |
| `set_at` | `(List, Int, Any) -> List` | Immutable list element replacement |

Plus these were already present but worth noting: `rem`, `abs`, `nil?`, `elem`, `floor`, `ceil`, `round`, `not`, `random`, `size`, `empty?`, `flat`, `zip`, `uniq`, `sum`.

---

## Open issues / what to work on next

### 1. WebSockets

The biggest missing piece for a true LiveView-equivalent. Currently every button click causes a full page reload (POST → redirect → GET). A WebSocket connection would allow:
- The server to push diffs to the client without a full reload
- Instant UI updates (no round-trip page load)
- The server to render only the changed view nodes (diffing)

The client-side JS (`blimp_script()`) needs to upgrade to WebSocket and send/receive JSON messages. The `HTTPServer` actor needs a WebSocket upgrade path.

The key design question: does the WebSocket upgrade happen in a separate actor, or inside `HTTPServer`? Suggested approach: `HTTPServer` handles the HTTP upgrade request and spawns a `Session` actor per connection, which owns the WebSocket fd and the session state.

### 2. Session identity (cookies)

Currently hardcoded to session `"1"` — everyone shares state. Needs:
- Parse the `Cookie:` header from the raw HTTP request
- If `blimp_session=<id>` cookie exists, use that session id
- Otherwise, create a new session and set `Set-Cookie` in the response

This is pure Blimp string parsing — no Zig changes needed.

### 3. Concurrent connections

The `HTTPServer` accept loop is synchronous — it handles one request at a time. This works for demos but not real use. The actor scheduler (designed but not implemented — see `docs/lang_design/actor-runtime.md`) would solve this. Until the scheduler is real, the options are:
- Fork a new process per connection (use a `fork()` builtin)
- Accept this limitation and note it's a single-user dev server

### 4. Input fields / forms

Only `button` sends messages right now. For real apps you need text inputs. The view primitive `input(placeholder, :msg)` needs to be added, and the form body parser needs to handle `msg=<value>&input=<text>` style POSTs.

### 5. The Hole operator prompt quality

Claude's responses sometimes use Blimp syntax that doesn't exist yet (lambdas, `filter`, `map`/`reduce` higher-order functions). The prompt in `eval.zig: evalHole()` is the main lever. Ideas:
- Add more builtin names to the "available builtins" list
- Tell Claude explicitly what NOT to do (no lambdas, no closures as values yet)
- Include the type of the subject value and the declared return type of the handler

### 6. Hole in REPL mode

The Hole operator works in file mode (source patching + re-exec). It does NOT yet work in the interactive REPL — if you define an actor with a hole and send it a message, it calls Claude and returns the value but can't patch because there's no source file. This is a UX gap. The REPL should probably ask "do you want to add this to your session?" and replay the definition with the hole filled.

### 7. Multi-actor view composition

Currently `render_app()` is a pure function returning a single view tree. There's no way for one actor's view to embed another actor's view. The design from `view-dsl.md` suggests `mount(Counter)` to embed a child actor's view — not yet implemented.

### 8. Dot-notation actor names in message sends

`HTTP.Server <- :start` fails to parse — the parser only handles single-identifier send targets. Sending to `Actor.SubActor` requires either:
- Fixing the parser to handle dotted names in message send targets
- Or using flat names (current workaround: `HTTPServer`)

---

## Key files

```
chunks/lang/
  src/
    main.zig          — entry point: parse → typecheck → eval
    eval.zig          — tree-walking evaluator; evalHole() is the Hole operator
    builtins.zig      — all builtins including TCP, to_html, view primitives
    types.zig         — type representation: Type union, parseTypeName, record types
    checker.zig       — type checker: infers types, validates handler sigs
    parser.zig        — parser: includes parseTypeName for type annotations
    lexer.zig         — lexer: last_comment field captures Hole directives
    registry.zig      — actor registry: spawn, getInstance
    env.zig           — lexical environment: allBindings for Hole context
  web/
    server.blimp      — the working HTTP server + counter app
  examples/
    rate_limiter.blimp      — Hole demo: adaptive backoff
    content_pipeline.blimp  — Hole demo: multi-stage moderation
    game_rules.blimp        — Hole demo: tic-tac-toe with incomplete rules
  Makefile            — build commands for macOS 26

docs/
  lang_design/
    view-dsl.md       — view primitive design (actors render to DOM)
    view-engine.md    — view engine semantics
    actor-runtime.md  — actor scheduler design (not yet implemented)
    INITIAL_CHARTER.md
```

---

## Branch and git state

All of this work is on `blimp-core/web-framework`. It hasn't been merged to `main` yet.

Recent commits (most recent first):
- `b4ae6b6` — more typing fixes
- `f0435a1` — typed lists `[Item]` and record types `%{key: Type}`
- `9c5c74d` — hole operator improvements
- `a496725` — fix type checker, remove `--no-type-check` escape hatch
- `683dfb7` — three Hole example files
- `a23d476` — auto re-exec after hole patch + diff output
- `8acd934` — hole source patching (living codebase)
- `33b3690` — hole operator shells out to Claude
- `f9f865f` — web server actually runs: escape sequences, auto-spawn actors, file eval
- `b0bef0e` — TCP/HTTP builtins in Zig, server.blimp written

To merge when ready: `git checkout main && git merge blimp-core/web-framework`.

---

## Quick start

```bash
cd chunks/lang

# Build the binary (macOS 26)
zig build-exe src/main.zig --name blimp -target aarch64-macos-none -lSystem

# Run the counter app
./blimp web/server.blimp
# open http://localhost:8080

# Run a Hole example (will call Claude to fill in missing logic)
./blimp examples/rate_limiter.blimp

# Run tests
zig build-lib -Mblimp=src/lib.zig -target aarch64-macos-none -lSystem
```

The first time you run a Hole example, Claude fills in the missing branches and patches the file. The second run uses the generated code directly — no Claude call.

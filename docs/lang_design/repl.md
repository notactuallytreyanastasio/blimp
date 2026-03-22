# Blimp REPL: Design Questions & Answers

> This is a living document. Every decision we make about the REPL, evaluator, and interactive experience gets recorded here.

## What did we build?

A full interactive REPL for Blimp that runs in two modes: a TUI with a split-screen state sidebar (when connected to a terminal), and a plain-text mode with parseable output (when piped). The plain mode is consumed by a Phoenix LiveView that renders an interactive REPL in the browser.

The stack:

1. **Evaluator** (`eval.zig`) -- tree-walking interpreter, walks the AST and produces runtime `Value`s
2. **Value type** (`value.zig`) -- tagged union: int, float, string, atom, bool, nil, hole, list, tuple, map, actor_instance
3. **Environment** (`env.zig`) -- lexically scoped variable bindings with `allBindings()` for state display
4. **Builtins** (`builtins.zig`) -- `length`, `max`, `min`, `append`, `reverse`, `lookup`, `put`, `keys`, `now`
5. **Errors** (`errors.zig`) -- Elm-style rich error reporting with title, source line, message, hint
6. **REPL** (`main.zig`) -- `repl()` for TUI mode, `replPlain()` for piped mode, auto-detected via `isatty()`
7. **LiveView** (`repl_live.ex`) -- Phoenix app at `/repl` that displays introspected Blimp source files

## Architecture overview

The REPL is a dual-mode system. Both modes share the same evaluator, environment, and error infrastructure. The difference is output formatting.

```
CLI (TTY detected)              CLI (piped / non-TTY)
     |                                |
     v                                v
  repl()                         replPlain()
  ANSI escape codes              Box-drawing chars
  75/25 split screen             Parseable text output
  Cursor positioning             => result lines
  History scrollback             state sidebar blocks
     |                                |
     v                                v
  [Evaluator + Environment]      [Evaluator + Environment]
  (shared core)                  (shared core)
```

The LiveView at `/repl` currently operates in introspection mode -- it shells out to `blimp <file> --introspect` to get JSON about actors, state, handlers, and holes, then renders that in a sidebar alongside syntax-highlighted source. The interactive REPL (type expressions, see results) is the CLI binary.

The detection logic in `main.zig` is dead simple:

```zig
const is_tty = std.posix.isatty(std.posix.STDOUT_FILENO);
if (is_tty) {
    repl(allocator);
} else {
    replPlain(allocator);
}
```

No flags needed. Pipe the binary into another process and it automatically switches to parseable output. Run it in a terminal and you get the full TUI.

---

## The evaluator (eval.zig)

Tree-walking interpreter. Takes an AST node, produces a `Value`. No bytecode, no compilation step -- the AST *is* the execution format.

The `Evaluator` struct holds:

- `allocator` -- arena allocator, everything allocated during a session lives here
- `env` -- the `Environment` with lexical scopes
- `builtins` -- the `BuiltinRegistry` mapping function names to implementations
- `last_error` -- optional `BlimpError` for rich error reporting
- `source` -- current source text (for error context)
- `actor_ctx` -- optional `ActorContext` when inside a message handler

### What it evaluates

**Literals:** Integer, float, string, atom, bool, nil, hole. Straightforward -- allocate a `Value`, set the payload, return a pointer.

**Binary/unary ops:** Arithmetic (`+`, `-`, `*`, `/`), comparison (`<`, `>`, `<=`, `>=`, `==`, `!=`), logical (`&&`, `||`), negation (`-x`), not (`!x`). Int-float promotion happens automatically -- `1 + 2.0` gives you `3.0`. String concatenation with `+`. Division by zero returns a rich error.

**Assignment:** `x = 42` evaluates the right side, calls `env.define(name, val)`. Returns the value (assignments are expressions).

**Function calls:** Look up the name in `BuiltinRegistry`, evaluate all arguments, call the function. Unknown function name produces a rich error listing all available builtins.

**Pipes:** `[1, 2, 3] |> length` evaluates the left side, then handles three cases on the right:
1. Bare function name (`length`) -- pass left as first arg
2. Function call with a hole (`calculate_tax(_, region)`) -- substitute left for each `_` in the args
3. Function call without hole (`append(4)`) -- prepend left as first arg

The hole-substitution in pipes is the key design. From the language spec, `_` inside a pipe is the "where does the piped value go?" marker. This lets you pipe into any argument position, not just the first:

```
items |> calculate_tax(_, region)
```

**Data structures:** Lists `[1, 2, 3]`, tuples `{:ok, 42}`, maps `%{name: "bob", age: 30}`. Each evaluates all sub-expressions and allocates the appropriate `Value` variant.

**Dot access:** `m.name` evaluates the object, expects a map, linear-scans entries for a matching key. Returns nil if not found (no exception).

**orelse:** `expr orelse fallback`. Evaluates `expr`, if it's nil or hole, evaluates and returns `fallback`. Otherwise returns `expr`. This is the nil-coalescing operator.

**situation/case:** Pattern matching. Evaluates the subject, walks branches in order, compares subject to each pattern using `Value.eql()`. First match wins. Wildcard branch (null pattern) always matches. No match returns nil.

**Actor definitions:** This is where it gets interesting. `evalActorDef` walks the body nodes, collects `state_def` nodes into state fields (evaluating default values) and `message_handler` nodes into handler definitions (storing the AST, not evaluating it). Creates an `ActorInstance` on the heap, binds it in the environment by name. The actor is now a live value you can send messages to.

**Message send:** `Counter <- :increment`. Evaluates the target (must be `actor_instance`), finds a matching handler by name, checks argument count. If the handler has a guard, pushes a scope with params and state, evaluates the guard, skips if falsy. Then pushes a new scope, binds params and state fields, sets up an `ActorContext`, evaluates the handler body. Returns the `reply` value if set, otherwise the last expression's value.

**become:** Updates the `ActorInstance`'s state fields *in place* (the `state_fields` slice is mutable). But here's the critical semantic: `become` updates state for the NEXT message, not the current scope. Within the handler body, variables bound from state still hold their old values. This follows Erlang semantics -- state transitions are atomic snapshots.

```zig
// State is updated for the NEXT message. Scope bindings within this
// handler body keep the old values (become is a snapshot transition).
```

**reply:** Sets `ctx.reply_value` on the `ActorContext`. The message send returns this value to the caller.

---

## The Value type (value.zig)

Tagged union with 11 variants:

```zig
pub const Value = union(enum) {
    integer: i64,
    float: f64,
    string: []const u8,
    atom: []const u8,
    boolean: bool,
    nil,
    hole,
    list: []const *const Value,
    tuple: []const *const Value,
    map: []const MapEntry,
    actor_instance: *ActorInstance,
};
```

Key design points:

- **ActorInstance is a pointer.** It's heap-allocated and mutable (state fields update via `become`). Everything else is immutable.
- **actor_instance carries its handlers.** The `ActorInstance` struct stores the handler AST directly -- `HandlerDef` has the name, params, optional guard, and body nodes. This means the actor's behavior is data, inspectable and (eventually) serializable.
- **Format is built in.** Every `Value` knows how to format itself to a writer. Actors display as `<actor Counter { count: 2 }>`. Maps as `%{name: "bob"}`. Lists as `[1, 2, 3]`.
- **Structural equality.** `Value.eql()` compares by structure, not identity. Two lists with the same elements are equal. Two actors are equal if they have the same name (identity semantics for actors -- they're singletons in the REPL).
- **Truthiness.** nil is falsy. false is falsy. hole is falsy. Everything else (including zero, empty string, empty list) is truthy.

---

## The Environment (env.zig)

Lexically scoped variable bindings. Stack of scopes, each scope is a list of `(name, value)` bindings.

```zig
pub const Environment = struct {
    scopes: std.ArrayList(Scope),
    allocator: std.mem.Allocator,

    const Binding = struct {
        name: []const u8,
        val: *const Value,
    };

    const Scope = struct {
        bindings: std.ArrayList(Binding),
    };
};
```

- `init()` pushes the global scope automatically
- `pushScope()` / `popScope()` for entering/leaving blocks (handler bodies, guard evaluation)
- `define(name, val)` creates or updates a binding in the current (innermost) scope
- `lookup(name)` searches from innermost to outermost, returns first match
- `allBindings(allocator)` returns ALL visible bindings, innermost shadows outer -- this is the killer function for the state sidebar

The scoping model is simple: the REPL operates in the global scope. When you send a message to an actor, the evaluator pushes a new scope, binds handler params and state fields, evaluates the body, then pops the scope. Guard evaluation gets its own temporary scope too (pushed and popped within the guard check).

`allBindings()` walks from innermost to outermost, tracking which names it's already seen. Inner bindings shadow outer ones. This gives you the complete picture of "what variables exist and what are they" at any point -- exactly what the state sidebar needs.

---

## Builtins (builtins.zig)

Nine built-in functions registered at evaluator init:

| Function | Signature | What it does |
|----------|-----------|-------------|
| `length` | `(list) -> int` | Length of a list |
| `max` | `(int, int) -> int` | Maximum of two integers |
| `min` | `(int, int) -> int` | Minimum of two integers |
| `append` | `(list, value) -> list` | Append element to list (returns new list) |
| `reverse` | `(list) -> list` | Reverse a list (returns new list) |
| `lookup` | `(map, key) -> value` | Look up key in map (returns nil if missing) |
| `put` | `(map, key, value) -> map` | Set key in map (returns new map) |
| `keys` | `(map) -> list` | Get all keys from a map as a list of strings |
| `now` | `() -> int` | Current Unix timestamp |

All builtins are pure functions (except `now`) with the same signature: `fn(allocator, args) -> EvalError!*const Value`. They allocate their results on the arena. `append`, `reverse`, and `put` return new values -- they never mutate their inputs.

The `BuiltinRegistry` is a simple array list with linear search. At 9 entries, there's no point optimizing the lookup.

---

## Elm-style errors (errors.zig)

Every error is a `BlimpError` struct:

```zig
pub const BlimpError = struct {
    title: []const u8,       // e.g. "UNDEFINED VARIABLE"
    source_line: ?[]const u8, // the code that triggered the error
    col: ?u32,               // column for the caret
    message: []const u8,     // what went wrong
    hint: ?[]const u8,       // what you probably meant
};
```

Two formatters: `format()` uses ANSI color codes (cyan title bar, red caret, yellow hint). `formatPlain()` strips colors for piped output.

The error types:

**UNDEFINED VARIABLE** -- When you reference a name that doesn't exist. The hint dumps all variables currently in scope with their values. If nothing is defined yet, it suggests `x = 42`.

```
-- UNDEFINED VARIABLE ──────────────────────────────────────

  foo

  I can't find a variable called `foo`.

  Variables in scope:
      x = 42
      items = [1, 2, 3]
```

**TYPE MISMATCH** -- Binary operation with incompatible types. Hints that both sides need to be the same type.

**DIVISION BY ZERO** -- Division by zero. Suggests checking the denominator.

**UNKNOWN FUNCTION** -- Calling a function that doesn't exist. The hint lists all available builtins.

**NOT AVAILABLE HERE** -- Using `state`, `on`, `become`, or `reply` outside an actor definition. Shows an example actor definition.

**NO MATCHING HANDLER** -- Sending a message to an actor that doesn't handle it. Names the actor and the message.

**BECOME OUTSIDE HANDLER** / **REPLY OUTSIDE HANDLER** -- Using `become` or `reply` at the top level. Explains these only work inside `on :message do ... end` blocks.

**NOT AN ACTOR** -- Using `<-` on something that isn't an actor instance.

**WRONG ARGUMENT COUNT** -- Handler expects N args, got M.

**PARSE ERROR** -- Falls through when nothing else matches. Detects common keyword-as-variable mistakes (trying to use `state`, `on`, `do`, `end`, `situation`, etc. as variable names) and redirects to NOT AVAILABLE HERE. Otherwise gives a generic "try a simpler expression" hint with examples.

The error generation is context-aware. `undefinedVariable()` takes the environment and allocator so it can build the "variables in scope" hint dynamically. `wrongArgCount()` takes the handler name and counts to produce a specific message.

---

## Multi-line input

Actor definitions span multiple lines. The REPL needs to know when you're in the middle of one.

`countDepthChange()` scans each line for `do` and `end` keywords at word boundaries. `do` increments depth by 1, `end` decrements by 1. Word boundaries are checked explicitly -- `doc` doesn't trigger a `do` match, `render` doesn't trigger an `end` match.

```zig
fn countDepthChange(line: []const u8) i32 {
    // Check for "do" at word boundary: before_ok and after_ok
    // Check for "end" at word boundary: before_ok and after_ok
    // Returns net delta
}
```

The REPL flow:

1. Print prompt (`blimp> ` at depth 0, `  ... ` at depth > 0)
2. Read a line
3. Append to multi-line buffer
4. Update depth with `countDepthChange(line)`
5. If depth > 0, go back to step 1 (keep accumulating)
6. If depth == 0, we have a complete input

Complete input is then dispatched:
- If it contains `\n` (was multi-line), parse with `parseFilePublic()` which handles actor definitions
- If single line, parse with `parseStatementPublic()` for expressions and assignments

This means you can type an actor definition line by line and the REPL waits for all the `end`s to close before evaluating:

```
blimp> actor Counter do
  ...   state count: Int :: 0
  ...   on :increment do
  ...     become count: count + 1
  ...     reply count + 1
  ...   end
  ... end
=> <actor Counter { count: 0 }>
```

---

## The state sidebar

This is the feature that makes the REPL actually useful. After every evaluation, you see all variables and their current values.

### How it works

`env.allBindings(allocator)` returns all visible bindings from the innermost scope outward, with inner bindings shadowing outer ones. The REPL calls this after every successful evaluation.

### Plain mode (piped output)

Box-drawing characters create a parseable sidebar block:

```
=> <actor Counter { count: 0 }>
  +----- state -------------------+
  | Counter = <actor Counter { count: 0 }>
  | x = 42
  | items = [1, 2, 3]
  +-------------------------------+
```

(Using Unicode box-drawing: `\u250c`, `\u2502`, `\u2514`, `\u2500`)

This format is easy to parse programmatically: look for lines starting with `  |` between the box borders, split on ` = ` to get name and value.

### TUI mode (terminal)

The terminal gets a 75/25 split screen:
- Left side (75% of terminal width): REPL history with input/output/errors
- Right side (25%): STATE header, then `name = value` for each binding

The TUI uses ANSI escape codes for cursor positioning and screen drawing:
- `\x1b[2J` clears the screen
- `\x1b[{row};{col}H` moves the cursor
- `\x1b[2K` clears the current line
- `\x1b[90m` for dim grey (border), `\x1b[34m` for blue (variable names), `\x1b[32m` for green (prompt), `\x1b[31m` for red (errors), `\x1b[37m` for white (output)

Terminal size is detected via `ioctl(STDOUT_FILENO, TIOCGWINSZ)`, falling back to 120x40 if it fails.

`drawScreen()` redraws everything on every evaluation:
1. Clear screen
2. Draw vertical border at column `left_cols + 1`
3. Draw STATE header on the right side
4. Draw variable bindings on the right side (truncated to fit)
5. Draw REPL history on the left side (scrolled to show most recent entries)

The history is a list of `HistoryEntry` structs tagged as `input`, `output`, or `err`. The draw function calculates how many entries fit and starts from the most recent that fills the screen.

### Actors in the sidebar

Actors display with their internal state:

```
Counter = <actor Counter { count: 2 }>
```

After `Counter <- :increment`:

```
Counter = <actor Counter { count: 3 }>
```

You can watch state evolve in real time as you send messages. This is what makes the REPL a teaching tool -- you define an actor, send messages, and see the state change on every interaction.

---

## Actor runtime in the REPL

### Defining actors

Multi-line input. The parser produces an `actor_def` AST node. The evaluator:

1. Walks the body, collects `state_def` fields (evaluating default values) and `message_handler` definitions (storing AST)
2. Creates a heap-allocated `ActorInstance`
3. Binds it in the environment by name

The actor is now a first-class value. You can see it in the sidebar, send it messages, reference it in expressions.

### Sending messages

`Counter <- :increment` is a `message_send` AST node. The evaluator:

1. Evaluates the target (`Counter` -- looks up in env, gets the `actor_instance`)
2. Scans handlers for a matching name
3. Checks argument count
4. If there's a guard, evaluates it in a temporary scope with params and state bound
5. Pushes a new scope for the handler body
6. Binds handler params from message args
7. Binds state fields as local variables
8. Sets up `ActorContext` (holds pointer to instance and reply slot)
9. Evaluates the handler body
10. Restores previous context, pops scope
11. Returns reply value (or last expression, or nil)

### become semantics

This is a deliberate Erlang-inspired design. `become count: count + 1` does two things:

1. Evaluates `count + 1` using the CURRENT scope (where `count` is still the old value)
2. Writes the result into `instance.state_fields` (mutating the actor's state)

But the scope bindings don't change. If the handler body continues after `become`, the local `count` variable still holds the old value. Only the NEXT message will see the updated state.

```
on :increment do
  become count: count + 1   # state updated to count+1
  reply count + 1            # count is still the OLD value here
end
```

This matches Erlang's process loop pattern where `become` is like the recursive call with new state -- the current function execution sees its original arguments.

### Guards

Handlers can have `when` guards:

```
on :withdraw(amount) when amount > 0 do
  become balance: balance - amount
  reply balance - amount
end
```

Guards are evaluated in a temporary scope with both handler params and state fields bound. If the guard evaluates to falsy, the handler is skipped and the next handler is tried. This lets you have multiple handlers for the same message name that dispatch based on conditions:

```
on :withdraw(amount) when amount > 0 do ... end
on :withdraw(amount) do reply :insufficient end
```

---

## The LiveView REPL (/repl route)

The LiveView at `/repl` in the term_diff Phoenix app provides a browser-based code viewer with introspection. It's served alongside the diff viewer at `/` and the agents view at `/agents`.

### How it works

`TermDiff.Blimp` is the Elixir-side interface to the Zig binary. It shells out to `blimp <file> --introspect` which outputs JSON describing actors, state fields, handlers, guards, and holes. The LiveView parses this and renders it.

The current ReplLive (`repl_live.ex`) is a file browser + introspection viewer:
- **File picker bar** at the top -- selects from `.blimp` example files
- **Source pane** (left) -- syntax-highlighted source with line numbers, hole lines highlighted in amber
- **Actor sidebar** (right, 320px) -- expandable panels showing each actor's state, handlers, and holes
- **Hole fill panel** (bottom) -- appears when you click "Fill" on a hole, with a text input for AI directives

The keyword highlighter recognizes: `actor`, `do`, `end`, `state`, `on`, `become`, `reply`, `when`, `bubbles`, `situation`, `case`, `orelse`.

### Source highlighting

Lines containing `_ #` (hole with directive) get an amber background. Keywords get fuchsia bold. Comments get grey. This is done with regex replacement on HTML-escaped source, not a full syntax highlighter.

### What's NOT here yet

The current LiveView is a static file viewer with introspection. The interactive REPL (type expressions, see results, state sidebar updating live) is CLI-only right now. The architecture for bridging them exists: the plain mode output format is designed to be machine-parseable, and the plan is to spawn the blimp binary as an Erlang Port, pipe input/output through stdin/stdout, and parse the result/state lines in real time.

Data flow for interactive LiveView REPL (future):

```
User types in browser
       |
       v
LiveView handle_event
       |
       v
Port.command(port, input <> "\n")
       |
       v
blimp binary (plain mode, stdin/stdout)
       |
       v
Port stdout -> handle_info
       |
       v
Parse "=> value" lines (results)
Parse box-drawing lines (state)
Parse "-- TITLE --" blocks (errors)
       |
       v
Render in LiveView
```

---

## Design decisions

### Why tree-walking interpreter (not bytecode)

Simplicity. The REPL needs to evaluate one expression at a time. There's no hot loop, no performance-critical path. A tree-walker is easy to understand, easy to debug (you can step through the AST), and easy to extend (add a new node kind, add a case to the switch).

The eventual compiler will emit LLVM IR via the Zig parser. The REPL evaluator is a separate concern -- it's for interactive exploration, not production execution. If REPL performance ever matters, we'll add bytecode compilation then.

### Why become doesn't update current scope

Erlang semantics. In Erlang, `become` (the recursive call with new state) doesn't change the current function's variables. Your handler body runs to completion with the values it started with. The new state takes effect on the next message.

This prevents a class of bugs where state mutation in the middle of a handler creates inconsistent intermediate states. It also makes reasoning about handlers easier -- each handler is a pure function of (state, message) that returns (new_state, reply).

### Why auto-detect TUI vs plain mode

The LiveView needs machine-parseable output. Humans need readable output. Rather than add a flag, `isatty()` does the right thing automatically. If stdout is a terminal, you get the TUI. If it's piped (into an Erlang Port, into a file, into another process), you get parseable text.

This also means `blimp --repl | cat` shows plain mode, which is useful for debugging the plain output format.

### Variable rebinding

Currently allowed. `x = 42` then `x = 99` updates `x` in the current scope. This is an open design question -- should Blimp variables be single-assignment (like Erlang) or rebindable (like Elixir)?

For the REPL, rebinding is convenient. For the language at large, single-assignment might be safer and more aligned with the actor model (immutable data, state changes only through `become`). The evaluator currently uses `define()` which updates existing bindings in the current scope, so rebinding is the default behavior.

### Arena allocation strategy

The evaluator uses a single arena allocator for the entire REPL session. Every `Value`, every `ActorInstance`, every string -- all allocated from the arena. Nothing is individually freed during the session.

This is fine for a REPL. Sessions are short-lived, memory pressure is low. When the process exits, the arena is freed wholesale. For long-running actors in production, the plan is arena-per-actor (free everything when the actor dies), but that's a compiler/runtime concern, not a REPL concern.

---

## What's next

### Interactive LiveView REPL

Spawn the blimp binary as an Erlang Port, pipe expressions through stdin, parse results and state from stdout. The plain mode output format was designed specifically for this.

### Actor supervision in REPL

Currently actors in the REPL are standalone. No supervision tree, no restart semantics. Adding `bubble` support and inter-actor messaging would let you define a supervision tree interactively and watch failures propagate.

### Type inference integration

The type checker (`checker.zig`) runs on files but not in the REPL. Integrating it would show type annotations alongside values in the state sidebar and catch type errors before evaluation.

### Tab completion

The `BuiltinRegistry` and `Environment` both support enumeration. Tab completion for builtin function names, variable names, and actor names is straightforward.

### History (readline-style)

The TUI currently doesn't support up-arrow to recall previous inputs. Adding readline or a minimal history buffer would make the REPL much more usable for iterative exploration.

### The canvas

The visual program representation where finished code is solid/geometric and Holes are chaotic/noisy. The REPL's `allBindings()` and actor introspection are the data source for this -- the canvas would be a graphical view of everything the state sidebar shows in text.

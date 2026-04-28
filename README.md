# Blimp

An actor-oriented programming language where code structure is runtime structure.
Actors are the only abstraction -- there are no modules, no classes, no separate concept of "pure functions."
A helper function is just an actor with one handler that replies immediately.

Blimp compiles to native code via LLVM.
On recursive benchmarks it runs within 1-2x of C, Rust, and Zig.

**[Try it in your browser](https://blimp.bobbby.online/blog/playground.html)** -- the full language runs as a 184KB WASM module, no install required.

**[Tutorial](https://blimp.bobbby.online/tutorial/)** -- build a bike-share simulation from scratch, with an embedded REPL in every chapter.

## What it looks like

```
actor Bike do
  state id: String :: "unknown"
  state status: Atom :: :available

  on :rent when status == :available do
    become status: :rented
    reply {:ok, id}
  end

  on :rent do
    reply {:error, "already rented"}
  end

  on :return do
    become status: :available
    reply :ok
  end
end

b = spawn Bike, id: "b-001"
b <- :rent      # => {:ok, "b-001"}
b <- :rent      # => {:error, "already rented"}
b <- :return    # => :ok
```

Multi-clause handlers with guards give you safe state transitions without mutexes.
The mailbox serializes messages; each handler runs to completion before the next one starts.
No locks, no races, by construction.

## Key ideas

**Actors all the way down.**
State lives inside actors. You talk to actors by sending messages with `<-`. An actor transitions state with `become` (Hewitt's original primitive, not mutation). It talks back with `reply`.

**Namespaces are supervision trees.**
`Shop.Checkout` means Checkout is supervised by Shop. When a `CascadeBubble` fires, all children of the same parent restart. The structure of your code IS the structure of your running system.

**Typed state, pattern-matched handlers.**
State fields require types and defaults (`state balance: Int :: 0`). Handlers use guards and multi-clause dispatch. First match wins.

**Holes for humans and agents.**
A Hole (`_` with a trailing comment) is a typed gap. It compiles, it runs, it just doesn't do anything yet. The comment is a directive to an agent or your future self.

```
situation validate(payment) do
  :valid -> process(payment)
  _ # Hole: handle invalid payment,
    # begin by researching documentation
    # on transaction failure
end
```

**Bubbles, not exceptions.**
Failure propagates through Bubble actors that walk the supervision tree. Different bubbles have different blast radii. Callers catch bubbles with `orelse`.

## The language

### Data types

| Type | Syntax | Examples |
|------|--------|---------|
| Integer | bare numbers | `42`, `-7` |
| Float | decimal numbers | `3.14`, `0.5` |
| String | double quotes | `"hello"`, `"#{name}"` |
| Atom | colon prefix | `:ok`, `:error` |
| Bool | keywords | `true`, `false` |
| Nil | keyword | `nil` |
| List | brackets | `[1, 2, 3]` |
| Tuple | braces | `{:ok, 42}` |
| Map | percent-braces | `%{name: "alice"}` |

### Functions and closures

```
def fib(n) do
  situation n do
    0 -> 0
    1 -> 1
    _ -> fib(n - 1) + fib(n - 2)
  end
end

double = fn(x) do x * 2 end
```

### Pipes

`_` marks where the piped value goes.

```
receipt = items
  |> calculate_tax(_, region)
  |> apply_discount(_, code)
  |> finalize(_, payment)
```

### Spread operators

```
...list, fn(x) do x * 2 end    # map
..list, fn(x) do print(x) end  # each
```

### 40 built-in functions

**Collections:** `length`, `append`, `reverse`, `head`, `tail`, `sort`, `merge`, `flat`, `zip`, `uniq`, `slice`, `elem`, `range`
**Maps:** `lookup`, `put`, `keys`, `values`
**Strings:** `concat`, `split`, `contains`, `upcase`, `downcase`, `to_string`
**Math:** `max`, `min`, `abs`, `rem`, `floor`, `ceil`, `round`, `random`, `sum`
**Utility:** `now`, `to_int`, `type_of`, `print`, `nil?`, `empty?`, `size`, `not`

### Error messages

Elm-quality diagnostics with region underlines, "Did you mean?" suggestions, and language-refugee detection that tells you the Blimp way when you write Python/JS/Rust syntax by accident.

## Compiler

`blimp-compile` takes a `.blimp` file, generates LLVM IR, links with an 846-line C runtime, and produces a native binary.

```
$ blimp-compile marketplace.blimp -o marketplace
$ ./marketplace

$ blimp-compile bench_fib.blimp --run       # compile + run + cleanup
$ blimp-compile marketplace.blimp --canvas  # compile + run + HTML visualization
```

### Canvas visualization

`--canvas` generates a self-contained HTML file that replays the program's actor events as animation.
Actors appear as hexagons with generative art fills derived from their state.
Message sends animate as rays between actors.
State changes flash borders white.
Parent-child relationships render as persistent dashed lines following the namespace hierarchy.

### Benchmarks

Recursive benchmarks compiled with `blimp-compile`, compared against C (`-O2`), Zig (`-OReleaseFast`), Rust (`-O`), Python 3, and Ruby.
Median of 3 runs on Apple Silicon.

| Benchmark | C | Zig | Rust | Blimp | Python | Ruby |
|-----------|---|-----|------|-------|--------|------|
| fib(40) | 453ms | 447ms | 451ms | 579ms (1.3x) | 13107ms | 9550ms |
| binary tree (depth 25) | 167ms | 169ms | 169ms | 338ms (2.0x) | 3390ms | 2753ms |
| KNN grid (1000x1000) | 170ms | 167ms | 169ms | 173ms (1.0x) | 469ms | 296ms |

1-2x C on pure computation.
On arithmetic-heavy code (KNN), it matches C exactly.
The overhead comes from `situation` branching (compare-and-branch chains vs. a single conditional).

## The marketplace

The flagship example: a marketplace simulation with 12 actors across 7 types (287 lines).
The supervision hierarchy reflects real ownership -- your account and wallet belong to you, not to the marketplace.

```
Marketplace
  Marketplace.AccountHolder
    Marketplace.AccountHolder.Account
    Marketplace.AccountHolder.Wallet
  Marketplace.Institution
    Marketplace.Institution.Account
  Marketplace.Thief
```

5 days of simulation: commerce, cash withdrawals, theft attempts (some blocked by insufficient funds), inter-business supplier payments.
Compiling with `--canvas` produces an animated HTML visualization showing all 12 actors, 156+ message events, and state changes over time.

## Tooling

### Terminal REPL

Split-pane TUI.
Left pane: input history with multi-line support and bracket-depth tracking.
Right pane: live state showing all variable bindings and actor instances with their current state.
Tab completion with type-aware signatures.

### Browser REPL

The same language compiled to WebAssembly (184KB).
Canvas visualization shows actors as hexagons with generative art fills.
Runs entirely client-side, zero server dependencies.

### Tutorial

A [bike-share simulation tutorial](https://blimp.bobbby.online/tutorial/) that builds up from a single Bike actor to a multi-actor system with supervision.
Each chapter has an embedded REPL with a Monaco editor, a test runner, and canvas visualization -- all in-browser via WASM.

Chapters so far:
- Ch 0: Why actors?
- Ch 1: Your first actor
- Ch 2: State, `become`, and the free lock
- Ch 3: Actors talking to actors

### Tree-sitter grammar

Published at [tree-sitter-blimp](https://github.com/notactuallytreyanastasio/tree-sitter-blimp) with a Zed extension for editor highlighting.

### Blimp Chat (experimental)

A chat server written entirely in Blimp: HTTP server, WebSocket handshake, frame parsing, poll-based accept loop, broadcast to connected clients.
23,000 lines of Blimp.
Bidirectional WebSocket messaging works end-to-end.

## Implementation

~20,000 lines of Zig plus an 846-line C runtime, across 26 source files.

| Component | Lines | What it does |
|-----------|-------|-------------|
| Evaluator | 3,043 | Tree-walking interpreter for REPL and browser. |
| Builtins | 2,739 | 40 built-in functions. |
| Parser | 2,500 | Recursive descent. Actors, handlers, guards, pipes, situations, holes. |
| Codegen | 2,010 | AST to LLVM IR. Full language support. |
| Type Checker | 1,889 | 2-pass cross-actor registry. Validates state types, handler signatures, message sends. |
| Main | 1,007 | CLI: REPL mode, file mode, introspect mode. Split-pane TUI. |
| Runtime (C) | 846 | Tagged values with ref counting, actor registry, round-robin scheduler, mailboxes, canvas event logging. |
| Introspect | 736 | AST to JSON export for IDE/external tool integration. |
| Errors | 598 | Elm-style diagnostics with region underlines and suggestions. |
| Types | 574 | Structural type system with subtyping. |
| WASM API | 568 | Browser bindings. Init, eval, test runner. 184KB module. |
| Compile Main | 559 | Compiler CLI. Parse, codegen, verify, link, canvas HTML generation. |
| Lexer | 514 | Atoms, strings with interpolation, numbers, operators, comments. |
| Value | 403 | Runtime value representation. |
| AST | 306 | 58 node kinds covering the full language. |
| Registry | 300 | Actor template storage, instance management, state mutation tracking. |
| Completion | 239 | Type-aware auto-complete for REPL. |
| Env | 174 | Variable binding store with scope chains. |
| Token | 130 | Token type definitions. |

## Project structure

```
chunks/lang/             Zig compiler, evaluator, WASM target
chunks/lang/src/         20 source files (20,000+ lines)
chunks/lang/examples/    30 example programs
chunks/lang/bench/       Benchmark suite (C, Zig, Rust, Python, Ruby)
chunks/lang/web/         Browser REPL, chat server, concurrent server
docs/tutorial/           Bike-share tutorial with embedded REPL
docs/lang_design/        Design documents
docs/blog/               Design journal
```

## Links

- [Playground](https://blimp.bobbby.online/blog/playground.html) -- run Blimp in your browser
- [Tutorial](https://blimp.bobbby.online/tutorial/) -- bike-share simulation, chapters 0-3
- [Design journal](https://blimp.bobbby.online/blog/)
- [Tree-sitter grammar](https://github.com/notactuallytreyanastasio/tree-sitter-blimp)
- [Landing page](https://blimp.bobbby.online)

## License

MIT

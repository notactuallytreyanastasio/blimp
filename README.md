# Blimp

A self-hosted, actor-oriented programming language.
Code structure is runtime structure.
Actors are the only abstraction.

Blimp compiles itself.
The lexer, parser, evaluator, and codegen are written in Blimp.
A Zig bootstrap gets the first generation off the ground, then Blimp takes over.

The native compiler targets LLVM IR and runs within 1-2x of C on recursive benchmarks.
The whole language also runs in the browser as a 184KB WASM module.

**[Try it](https://blimp.bobbby.online/blog/playground.html)** -- nothing to install.

**[Tutorial](https://blimp.bobbby.online/tutorial/)** -- build a bike-share simulation with an embedded REPL in every chapter.

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

Multi-clause handlers with guards.
The mailbox serializes messages.
Each handler runs to completion before the next starts.
No locks, no races, by construction.

## Key ideas

**Actors all the way down.**
No modules, no classes.
A helper function is just an actor with one handler that replies immediately.
State lives inside actors.
You talk to them with `<-`, transition state with `become`, and talk back with `reply`.

**Namespaces are supervision trees.**
`Shop.Checkout` means Checkout is supervised by Shop.
When a `CascadeBubble` fires, all siblings restart.
The structure of your code IS the structure of your running system.

**Self-hosted.**
The Blimp compiler is written in Blimp.
The Zig code is the bootstrap -- it evaluates the Blimp-written compiler, which then handles user code.
`blimp_compile(source, :eval)` spawns a Lexer actor, pipes tokens to a Parser actor, and walks the AST through an Evaluator actor.

**Holes.**
`_` with a trailing comment is a typed gap in your program.
It compiles, it runs, it just doesn't do anything yet.
The comment is a directive to an agent or your future self.

```
situation validate(payment) do
  :valid -> process(payment)
  _ # Hole: handle invalid payment,
    # begin by researching documentation
    # on transaction failure
end
```

**Bubbles, not exceptions.**
Bubbles are actors that walk the supervision tree deciding who restarts.
Different bubbles have different blast radii.
`on :charge bubbles(CascadeBubble)` takes out all siblings; a plain handler defaults to `SelfBubble`.
Callers catch bubbles with `orelse`.

**Typed state, pattern-matched handlers.**
State fields require types and defaults: `state balance: Int :: 0`.
Handlers use guards and multi-clause dispatch.
First match wins.

## The self-hosted compiler

In `chunks/lang/lib/`, all written in Blimp:

| Component | Lines |
|-----------|-------|
| Parser | 750 |
| Evaluator | 479 |
| Lexer | 441 |
| Safe strings | 426 |
| Codegen | 235 |
| Stdlib | 204 |
| Completion engine | 69 |
| Compiler driver | 37 |
| **Tests** | **3,466** |

The compiler actor pipeline:

```
def blimp_compile(source: String, mode: Atom) -> Any do
  case mode do
    :eval -> blimp_self_eval(source)
    :wasm -> compile_to_wasm(source)
    :tokens ->
      l = spawn Lexer
      l <- :set_source(source)
      l <- :tokenize
    :ast ->
      l = spawn Lexer
      l <- :set_source(source)
      tokens = l <- :tokenize
      p = spawn Parser
      p <- :set_tokens(tokens)
      p <- :parse
    _ -> blimp_self_eval(source)
  end
end
```

The stdlib replaces Zig builtins with Blimp implementations.
Property-based tests generate random inputs and check invariants like commutativity and associativity.
Safe string types (`SafeHtml`, `SafeSql`, `SafeUrl`) enforce context-sensitive escaping at the type level.

## Native compiler

`blimp-compile` generates LLVM IR, links with an 846-line C runtime, and produces a native binary.

```
$ blimp-compile marketplace.blimp -o marketplace
$ ./marketplace

$ blimp-compile bench_fib.blimp --run       # compile + run + cleanup
$ blimp-compile marketplace.blimp --canvas  # compile + run + HTML visualization
```

### Canvas visualization

`--canvas` generates a self-contained HTML replaying the program's actor events as animation.
Actors appear as hexagons with generative art fills derived from their state hash.
Message sends animate as rays.
State changes flash borders.
Parent-child relationships render as dashed lines following the namespace hierarchy.

### Benchmarks

Median of 3 runs on Apple Silicon.

| Benchmark | C | Zig | Rust | Blimp | Python | Ruby |
|-----------|---|-----|------|-------|--------|------|
| fib(40) | 453ms | 447ms | 451ms | 579ms (1.3x) | 13107ms | 9550ms |
| binary tree (depth 25) | 167ms | 169ms | 169ms | 338ms (2.0x) | 3390ms | 2753ms |
| KNN grid (1000x1000) | 170ms | 167ms | 169ms | 173ms (1.0x) | 469ms | 296ms |

1-2x C on pure computation.
Matches C exactly on arithmetic-heavy code (KNN).
With LTO and tail-call optimization enabled, Blimp is fastest on fib and KNN.

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

Elm-style diagnostics with region underlines, "Did you mean?" suggestions, and language-refugee detection that tells you the Blimp way when you write Python/JS/Rust syntax by accident.

## Programs written in Blimp

### Marketplace (287 lines)

12 actors across 7 types.
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

5 days of simulation: commerce, cash withdrawals, theft attempts, inter-business supplier payments.
`--canvas` produces an animated visualization with all 12 actors and 156+ message events.

### Blimp Chat (706 lines)

HTTP server, WebSocket handshake, frame parsing, poll-based accept loop, broadcast to connected clients.
Bidirectional WebSocket messaging works end-to-end.
Written entirely in Blimp, including the HTTP parsing and WebSocket frame encoding.

### Concurrent server (263 lines)

Poll-based multiplexed accept loop with shared session state.
Demonstrates non-blocking IO without threads -- `tcp_poll` over multiple file descriptors, round-robin dispatch.

## Tooling

### Terminal REPL

Split-pane TUI (889 lines of Rust + the Zig evaluator).
Left pane: input with multi-line support and bracket-depth tracking.
Right pane: live state showing all variable bindings and actor instances.
Tab toggles between state view and live LLVM IR view.
Type-aware tab completion.

### Browser REPL

The same language compiled to WebAssembly (184KB).
Canvas visualization with generative art.
Runs entirely client-side.

### Tutorial

A [bike-share simulation](https://blimp.bobbby.online/tutorial/) that builds from a single Bike actor to a multi-actor system with supervision.
Each chapter has an embedded REPL with a Monaco editor, a test runner, and canvas visualization.

- Ch 0: Why actors?
- Ch 1: Your first actor
- Ch 2: State, `become`, and the free lock
- Ch 3: Actors talking to actors

### Tree-sitter grammar

[tree-sitter-blimp](https://github.com/notactuallytreyanastasio/tree-sitter-blimp) with a Zed extension.

## Project structure

```
chunks/lang/lib/         Self-hosted compiler (Blimp)
chunks/lang/src/         Bootstrap compiler (Zig) + C runtime
chunks/lang/examples/    30 example programs
chunks/lang/bench/       Benchmarks (C, Zig, Rust, Python, Ruby)
chunks/lang/web/         Chat server, concurrent server, DOM playground
chunks/repl_tui/         Split-pane terminal REPL (Rust)
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

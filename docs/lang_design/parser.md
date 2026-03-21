# Blimp Parser: Design Questions & Answers

> This is a living document. Every decision we make about the parser gets recorded here so we can see the design evolve.

## What are we building?

A parser for Blimp -- a language with actors, pattern matching, and agent integration. We're building two things in parallel:

1. **A tree-sitter grammar** (`tree-sitter-blimp/`) -- gives us incremental parsing, syntax highlighting, structured queries for agents, and LSP foundations
2. **A Zig parser** (`src/`) -- the "real" compiler frontend that will eventually emit LLVM IR

Both define the same syntax and evolve together.

## Why Zig?

- Simple, readable systems language -- good for learning compiler internals
- Built on LLVM (Zig's own backend), so we're already in that ecosystem
- Explicit memory management -- no hidden allocations, we control everything
- Comptime metaprogramming -- useful for parser tables and token dispatch
- C interop is trivial -- important when we need LLVM C API for codegen
- No garbage collector -- the parser allocates into an arena and frees it all at once

## Why tree-sitter alongside the Zig parser?

The agents in Blimp need to *understand* code structurally, not just as text. Tree-sitter gives us:

- **Incremental parsing** -- only re-parse what changed, critical for the REPL where code is constantly in flux
- **Structured queries** -- agents can ask "find all actors", "what messages does this actor handle?", "what's in scope here?"
- **Syntax highlighting** -- works in any editor that supports tree-sitter (neovim, helix, zed, VS Code with extensions)
- **LSP foundation** -- go-to-definition, hover, completions all build on the tree-sitter AST
- **Error recovery** -- tree-sitter keeps parsing even when syntax is broken, essential for a live REPL

## Why recursive descent (for the Zig parser)?

- Easiest to understand and debug -- you can step through with a debugger
- Gives us full control over error messages ("expected 'do' after actor name, got ';'")
- Pratt parsing for expression precedence -- clean, composable
- No external dependencies (no parser generator, no grammar file to compile)
- The tree-sitter grammar handles the "incremental/error-tolerant" side, so the Zig parser can be strict

---

## Decisions Made

### D1: Syntax scope for first pass (2024-03-20)

**Scope: "Small -- actors + expressions"**

What's in:
- `actor Name do ... end`
- `state key: value, key: value`
- `on :message(args) do ... end`
- `become key: value, ...`
- `reply expression`
- Literals: integers, floats, strings, atoms, booleans, nil
- Variables / identifiers
- Binary operators: `+`, `-`, `*`, `/`, `==`, `!=`, `<`, `>`, `<=`, `>=`
- Maps: `%{key: value}`
- Lists: `[a, b, c]`
- Tuples: `{a, b}`
- Function calls: `foo(args)`

What's NOT in yet:
- Pipe operator `|>` and `_` placeholder
- Message send `<-`
- Pattern matching in `on` handlers (just simple variable binding)
- Guards (`when`)
- Supervisor syntax
- Module/import system
- Type annotations
- `def` for plain functions

### D2: Tree-sitter and Zig parser built in parallel (2024-03-20)

Both evolve together. Tree-sitter is the canonical grammar for tooling. Zig parser is the compiler frontend. They define the same syntax.

### D3: Perceus reference counting for runtime memory management (2024-03-20)

No garbage collector. Blimp will use Perceus-style reference counting (Reinking et al.). This is a compile-time insertion of reference counting operations that achieves:

- Deterministic deallocation (no GC pauses)
- Optimal reuse -- when a ref count drops to 1, the compiler can reuse the memory in-place instead of allocating new
- Works perfectly with immutable data and `become` semantics -- each `become` creates a new state snapshot, Perceus ensures the old one is freed when no longer referenced
- Aligns with the actor model -- each actor's state is isolated, so reference counting is local (no cross-actor GC coordination)

This is a RUNTIME decision, not a parser decision, but it fundamentally shapes how the compiler will eventually transform the AST. The parser itself uses Zig's arena allocator (allocate during parse, free everything at once).

---

## Open Questions

### Q1: How do atoms work syntactically?

Atoms are `:name`. But message patterns are `:name(args)`. Is `:name(args)` an atom with arguments, or is it a special "message pattern" syntax?

**Current thinking:** `:name` is an atom literal. `:name(args)` in `on` handlers is a message pattern -- syntactically different from a bare atom. The parser treats `on :name(args)` as a handler with a message name and argument list, not as an expression.

### Q2: Newlines as statement separators?

Do we require newlines between statements (like Ruby/Python), or use explicit semicolons (like C/Zig), or make them optional?

**Current thinking:** Newlines are statement separators, like Ruby. Semicolons are optional alternatives. Inside `do...end` blocks, each line is a statement. This feels natural for the "Ruby's skin" principle.

### Q3: How does `become` parse?

`become` takes keyword arguments: `become key: value, key: value`. This looks like a function call with keyword args, but it's a special form -- it replaces the actor's entire state.

**Current thinking:** `become` is a keyword, not a function. It takes a comma-separated list of `identifier: expression` pairs. The parser has a special rule for it.

### Q4: What's the precedence of operators?

For the first pass, standard math precedence:
1. `!` (unary not)
2. `*`, `/` (multiplicative)
3. `+`, `-` (additive)
4. `==`, `!=`, `<`, `>`, `<=`, `>=` (comparison)
5. `&&` (logical and)
6. `||` (logical or)
7. `=` (assignment, lowest)

### Q5: How do we handle `cons` in lists?

`[item | items]` uses `|` as a cons operator inside list literals. This is Elixir-style head|tail syntax. The parser needs to handle `|` specially inside `[...]`.

### Q6: Dot access for maps/structs?

`item.price` is dot access. Is this just syntactic sugar for `item[:price]`? Or a distinct operation?

**Current thinking:** Dot access is its own AST node. It's the primary way to access fields. Bracket access `item[:price]` is separate and works on maps. Both parse as postfix operators.

---

## Architecture Notes

### Token types

See `src/token.zig` for the full list. Highlights:
- Keywords are identified by table lookup after lexing an identifier
- Atoms start with `:` followed by an identifier
- Two-character operators (`|>`, `<-`, `<=`, `>=`, `==`, `!=`) need one character of lookahead

### AST shape

See `src/ast.zig` for the full type. The AST is a tagged union -- each node variant carries its own data. Source locations are tracked on every node for error reporting.

### Memory strategy

The parser uses an arena allocator. All AST nodes are allocated from the arena. When we're done with the AST (after codegen or analysis), we free the entire arena at once. No individual frees, no reference counting, no GC.

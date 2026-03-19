# Blimp

A radical approach to programming.

## Overview

Blimp is an actor-oriented programming language with integrated AI agents, a persistent reasoning graph, and a browser-native development environment. It compiles to LLVM IR targeting WebAssembly.

The language, the tooling, and the runtime are designed as a single unified system. Code structure is runtime structure. The REPL is a spatial navigation tool. Agents are first-class collaborators with persistent memory.

## Language Design

### Actors as the fundamental unit

Every computation in Blimp happens inside an actor. Actors communicate via message passing, transition state via `become`, and are supervised by their containing actor.

```
actor Checkout do
  state items: [], total: 0

  on :add(%{price: price} = item) when price > 0 do
    become items: [item | items],
           total: total + price
    reply :ok
  end

  on :add(%{price: price}) when price <= 0 do
    reply {:error, "price must be positive"}
  end

  on :checkout(payment) do
    receipt = items
      |> calculate_tax(_, region)
      |> apply_discount(_, payment.code)
      |> charge(payment)

    become items: [], total: 0
    reply {:ok, receipt}
  end
end
```

### Syntax

Ruby's readability with Elixir's functional core.

- `do/end` blocks, optional parentheses, expressive and readable
- Pattern matching in message handler heads with guards
- Immutable data, no mutation anywhere
- `become` for explicit state transitions (from Carl Hewitt's original actor model)
- Pipe operator `|>` with `_` placeholder for argument position
- Atoms as lightweight identifiers (`:ok`, `:error`, `:add`)
- Message send via `<-` operator

### Supervisors are namespaces

There is no separation between code organization and runtime topology. An actor that contains other actors is automatically a supervisor. The namespace hierarchy, the module structure, and the supervision tree are the same thing.

```
supervisor Shop do
  supervisor Checkout do
    actor TaxCalculator do
      state rates: %{us: 0.08, eu_west: 0.21}

      on :calculate(%{price: price}, region) do
        rate = rates[region] || rates[:default]
        reply {:ok, price * rate}
      end
    end

    actor PaymentProcessor do
      on :charge(amount, card) do
        result = gateway
          |> connect()
          |> authorize(_, card, amount)
          |> capture(_)
        reply result
      end
    end

    on :checkout(payment) do
      {:ok, tax} = TaxCalculator <- :calculate(%{price: total}, :us)
      # ...
    end
  end
end
```

Sibling actors address each other by name. No PIDs, no process registry. The supervisor itself can have state and handle messages.

### Immutability and time-travel debugging

Every `become` produces a new state snapshot. The history is the chain of snapshots. You can address past versions of an actor and send them messages:

```
blimp> Checkout @ t1 <- :summary
=> {[%{name: "shirt", price: 29.99}], 29.99}
```

This works because immutability means every past state is still valid.

## Tooling

### The REPL

Split-pane interface inspired by March. Left side is your session, right side is live program insight: variables in scope, actor state, agent commentary, autocomplete suggestions. Curated by default, full view on demand.

Navigation is spatial. `open Project`, `cd Module`, `..` to go up. The REPL is a place you navigate, not just a prompt.

### Agent system

AI agents run alongside your code with two non-overlapping interaction channels:

- `tab` accepts autocomplete suggestions, including `_` pipe placeholder positioning
- `shift+tab` expands inline annotations (Google Docs style) left by agents in the code gutter

Agents have persistent living memory via decision graphs. They remember what they noticed, what they tried, what you accepted, and what you rejected, across sessions. Decision graphs merge when agents agree and surface conflicts to the user when they disagree.

### The multiplexer

Top-level grid view of all agent workspaces. Your REPL is one cell. You can drop into any agent's REPL to see its live working state, history, decision tree, and talk to it directly.

The semantic diff viewer, the code editor, and agent workspaces are all panes in the multiplexer. Everything is a REPL inside the grid. This is the first thing being built.

### Decision trees

Every agent and the user maintains a decision tree tracking reasoning, observations, and conclusions. Trees merge when agents agree and present conflicts with full reasoning chains when they disagree. The user resolves conflicts as the final authority, and the rationale is captured.

## Compilation

Blimp compiles to LLVM IR. The primary target is `wasm32` for browser execution. The same frontend can target `x86_64`/`aarch64` for native execution later.

The actor runtime requires a green-thread scheduler (similar to Erlang's BEAM) compiled to WASM, multiplexing many actors onto few real threads.

## Status

Early design phase. The design journal, decision graph, and first blog post exist. No implementation yet.

**Build order:**
1. Multiplexer (web-based pane grid, the shell for everything else)
2. Language frontend (parser, type checker, IR generation)
3. Actor runtime (green-thread scheduler targeting WASM)
4. Agent protocol (standard interface for agent definition, memory persistence, graph merge logic)

## Open questions

- Type system design (structural? nominal? gradual?)
- Pure functions and data types outside actors
- Protocols and interfaces
- Agent definition (are agents special actors? written in Blimp?)
- Collaboration model (shared live environments vs. separate images that sync)
- Natural language boundary (where does talking to agents end and writing code begin?)

## Links

- [Design journal](https://blimp.bobbby.online/blog/)
- [Landing page](https://blimp.bobbby.online)

## License

MIT

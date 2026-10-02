# Core Language Feel: What Should Blimp Feel Like to Write?

> Blimp is a language where you are the craftsperson with a beautiful team of helpers that make you work at the speed of thought.

## Context

This is the first design session for Blimp's core syntax and runtime model. Starting from the INITIAL_CHARTER's three pillars (REPL-driven, actor model, contextual data awareness), we explored what it actually feels like to sit down and write Blimp code.

## Foundational Principle

**The programmer is the craftsperson. The agents are the team. The goal is speed of thought.**

This means:
- The programmer holds the chisel — real syntax, not conversation-as-programming
- Agents accelerate, they don't replace — they whisper suggestions, not take dictation
- When agents conflict, the user decides — with full visibility into each agent's reasoning
- The gap between intention and realization should approach zero

## Syntax Identity

**Surface like Ruby, data model like Elixir.** The syntax is expressive and readable with `do/end` blocks, optional parens, "programmer happiness" vibes. Underneath it the data model is Elixir's: immutable data, pattern matching everywhere, pipe operators, atoms.

**Pattern-matched immutability is king.** No mutation. Multi-clause message handlers with pattern matching and guards. State transitions are explicit, not side effects.

### Core Syntax Decisions

**Actors** are defined with `actor ... do ... end`:
```ruby
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

  on :summary do
    reply {items, total}
  end
end
```

**`become`** is the state transition keyword. Borrowed from Carl Hewitt's original actor model formulation. The actor *becomes* its next state. No mutation — `become` declares what the next version of the actor's state looks like. Current state fields are in scope from the handler's pattern match; `become` produces the new snapshot.

**Message send** uses `<-`:
```ruby
checkout <- :add(%{name: "shirt", price: 29.99})
```

**Message patterns** use `:name(args)` syntax:
```ruby
on :add(%{price: price} = item) do
  # ...
end
```

The message IS the pattern. `:add(item)` reads as "the add message, carrying an item."

**Pipe operator `|>`** is first-class, with `_` placeholder for argument position:
```ruby
receipt = items
  |> calculate_tax(_, region)
  |> apply_discount(_, payment.code)
  |> charge(payment)
```

The `_` placeholder solves Elixir's papercut of "which argument does this pipe into?" Agents suggest `_` placement based on function signatures.

### The Rhythm of Blimp Code

A handler has three beats: **compute, transition, communicate.**

```ruby
on :checkout(payment) do
  # compute — pipes transform data
  receipt = items
    |> calculate_tax(_, region)
    |> apply_discount(_, payment.code)
    |> charge(payment)

  # transition — become transforms the actor
  become items: [], total: 0

  # communicate — reply speaks to the caller
  reply {:ok, receipt}
end
```

Pipe, pipe, pipe — *thinking*. Become — *changing*. Reply — *speaking*.

## Architecture: Supervisors ARE Namespaces

**The structure of your code IS the structure of your running system.**

In Erlang/Elixir, code lives in modules and processes live in supervision trees — two separate hierarchies that don't align. In Blimp, they are the same thing. When you write `Shop.Checkout.TaxCalculator`, that's both where the code lives AND where the process runs AND what supervises it.

An actor that contains other actors IS a supervisor, automatically:

```ruby
supervisor Checkout do
  state items: [], total: 0

  actor TaxCalculator do
    state rates: %{us: 0.08, eu_west: 0.21, default: 0.10}

    on :calculate(%{price: price}, region) do
      rate = rates[region] || rates[:default]
      reply {:ok, price * rate}
    end
  end

  actor PaymentProcessor do
    state gateway: :stripe

    on :charge(amount, card) do
      result = gateway
        |> connect()
        |> authorize(_, card, amount)
        |> capture(_)
      reply result
    end
  end

  on :add(%{price: price} = item) when price > 0 do
    become items: [item | items],
           total: total + price
    reply :ok
  end

  on :checkout(payment) do
    {:ok, tax} = TaxCalculator <- :calculate(%{price: total}, :us)
    receipt = total + tax
      |> charge_payment(_, payment)
    become items: [], total: 0
    reply {:ok, receipt}
  end
end
```

Key implications:
- Sibling actors address each other by name — no PIDs, no process registry
- The supervisor itself can have state and handle messages
- Child crashes are restarted by the enclosing supervisor automatically
- Sane defaults (one-for-one restart) — agents tell you what the default is and offer to change it

## The REPL: A Living Workspace

### Navigation is Spatial

The REPL is a place you navigate, not just a prompt you type into:

```
blimp> open Shop

  Shop (supervisor)
  └── Checkout (supervisor)
      ├── TaxCalculator (actor) idle
      ├── PaymentProcessor (actor) idle
      └── Checkout (actor) idle, 0 msgs

blimp> cd Checkout
  [inside Shop.Checkout]
  3 actors running

blimp> TaxCalculator <- :calculate(%{price: 100}, :us)
  => {:ok, 8.0}

blimp> cd TaxCalculator
  [inside Shop.Checkout.TaxCalculator]

blimp> state
  => %{rates: %{us: 0.08, eu_west: 0.21, default: 0.10}}

blimp> ..
  [back in Shop.Checkout]
```

### Split-Pane with Agent Commentary

Inspired by the March REPL's split-pane design (variables in scope on the right), but with agent commentary and autocomplete:

```
┌─ blimp repl ─────────────────────────┬─ insight ──────────────────────────────┐
│                                      │ Variables in Scope                     │
│ blimp> actor Checkout do             │ ───────────────────────────────────────-│
│   state items: [], total: 0          │ Checkout : Actor (idle, 0 msgs)        │
│                                      │   items : List = []                    │
│   on :add(%{price: price} = item)    │   total : Int = 0                     │
│     ...                              │                                        │
│                                      │ Agents                                 │
│                                      │ ───────────────────────────────────────-│
│                                      │ scout: "item.price could be nil if     │
│                                      │  item comes from external API.         │
│                                      │  guard clause?"                        │
│                                      │                                        │
│                                      │ autocomplete:                          │
│                                      │   :checkout  (suggested — you          │
│                                      │     probably want this next)           │
└──────────────────────────────────────┴────────────────────────────────────────┘
```

**Curated by default, full view on demand.** The right pane shows what agents think is relevant right now. One keystroke expands to show everything: all variables, all actors, all agent commentary, full history, decision trees.

### Time-Travel Debugging Falls Out for Free

Every `become` is a snapshot. The history is the chain of `become` calls:

```
blimp> history Checkout

  t0  spawned           items: []           total: 0
  t1  :add("shirt")     items: ["shirt"]    total: 29.99
  t2  :add("hat")       items: ["hat",...]  total: 44.98

blimp> Checkout @ t1
  [viewing Checkout at t1]
  items: [%{name: "shirt", price: 29.99}]
  total: 29.99

blimp> Checkout @ t1 <- :summary
  => {[%{name: "shirt", price: 29.99}], 29.99}
```

`Checkout @ t1` addresses a past version of the actor. You can send it messages and see what would have happened. This works because immutability means every past state is still valid.

## The Multiplexer: Command Center

The multiplexer is the top-level view. It contains all agent REPLs, including yours. You can drop into any agent's REPL to see its live working state.

```
┌─ multiplexer ────────────────────────────────────────────────────────────┐
│  ┌─ you ──────────────┐  ┌─ scout ─────────────┐  ┌─ tracer ──────────┐│
│  │ blimp> _           │  │ scanning :checkout   │  │ graph: 4 actors  ││
│  │                    │  │ found 2 risks        │  │ 0 cycles         ││
│  └────────────────────┘  └──────────────────────┘  └──────────────────┘│
│                                                                         │
│  > drop scout                                                           │
└─────────────────────────────────────────────────────────────────────────┘
```

Dropping into an agent shows you its REPL, its scope, its decision tree, and lets you talk to it:

```
┌─ scout repl ─────────────────────────┬─ scout insight ────────────────────────┐
│ scout is working on: Checkout module │ Scout's Tree                           │
│                                      │ 1. scanned :add → nil risk (82%)      │
│ scan(1)> :add handler                │ 2. scanned :summary → stale risk (67%)│
│ => item.price accessed without guard │                                        │
│                                      │                                        │
│ you> why stale read risk?            │                                        │
│                                      │                                        │
│ scout: between :add mutating state   │                                        │
│   and :summary reading total,        │                                        │
│   another :add could arrive.         │                                        │
│                                      │                                        │
│ you> good catch. flag it.            │                                        │
│                                      │                                        │
│ > back                               │                                        │
└──────────────────────────────────────┴────────────────────────────────────────┘
```

**There is no distinction between "using the language" and "managing agents."** The REPL is an agent's workspace. Every agent has one. The multiplexer is the hallway between desks.

## Decision Trees: Reasoning as First-Class Data

Every agent (and the user) maintains a decision tree — a record of what it noticed, what it tried, what it concluded. These trees can merge when insights converge and conflict when agents disagree.

- **Auto-merge:** Scout finds nil risk, simulator confirms with failed replays. Both trees agree — merged automatically, user's tree gets a node.
- **Conflict:** Scout finds risk, simulator can't reproduce it. Presented to the user with both reasoning chains. User decides. Decision and rationale are captured in the user's tree.

Six months later, someone asks "why is there a guard clause here?" and the system can answer from the tree — because the user decided theoretical risks matter, and here's the conversation where they said so.

## Platform Target: WASM-First, Web-First

**Blimp targets WebAssembly.** This is a web-first language. The REPL, the multiplexer, the agent panes, the split-pane workspace — all of this runs in a browser.

The reasoning: the browser is the universal runtime. No install, no native dependencies, instant sharing. You open a URL and your Blimp environment is there. The REPL is a web app. The multiplexer is a web app. The agents run in the browser alongside your code.

Desktop comes later — the multiplexer/editor/semantic diff viewer will eventually offer a desktop solution. But v1 is the web.

**Blimp compiles to LLVM IR.** The compiler is an LLVM frontend — parser, type checker, and IR generation — that targets WASM via `wasm32` now and native via `x86_64`/`aarch64` later. One compiler, multiple backends. The desktop app isn't a rewrite, it's a recompile.

This has design implications:
- The Blimp compiler emits LLVM IR, which gives access to LLVM's optimization passes and multiple target architectures
- WASM target runs in the browser — the REPL, multiplexer, and agents are all web-native
- The actor runtime needs a green-thread scheduler (like Erlang's BEAM) compiled to WASM, multiplexing many actors onto few real threads
- The split-pane REPL UI is a web interface, not a terminal emulator
- Sharing a running Blimp environment could be as simple as sharing a URL
- The development experience is inherently portable — any device with a browser is a workstation
- Native target comes later for the desktop multiplexer/editor/semantic diff viewer

## Open Questions

1. **Supervisor-actor identity:** Does Option A (the supervisor IS the main actor, has state, receives messages, AND supervises children) feel right? Or too much responsibility in one construct?

2. **Restart strategies:** How are they configured? Inline in the supervisor? Separate declaration? How much should the defaults hide?

3. **Module system beyond actors:** What about pure functions, data types, protocols? Not everything is an actor. Where do plain functions live?

4. **Collaboration model:** If the REPL is a live image you navigate, how do two developers work on the same system? Shared image? Separate images that sync? Something beyond git?

5. **Agent protocol:** How are agents defined? Are they special actors? Written in Blimp? Do they have a standard interface (tree, scope, recommendations)?

6. **Natural language boundary:** `yeah` worked in early sketches for talking to agents. But code is real syntax. Where exactly is the line between "talking to an agent" and "writing code"? Is there a sigil or mode switch?

## References

- **Erlang/OTP**: Actor model, supervision trees, "let it crash"
- **Elixir**: Developer experience on actors, pipe operator, pattern matching, do/end
- **Pony**: Reference capabilities — mutation is safe inside actors because state is isolated
- **Smalltalk/Pharo**: Live image, everything is a message, IDE as part of the language
- **March REPL**: Split-pane with variables in scope — visual reference for Blimp's REPL
- **Unison**: Content-addressed code, no builds
- **Carl Hewitt**: Original actor model — `become` as the state transition primitive
- **Cognitive Dimensions of Notations** (Green & Petre): Framework for evaluating syntax decisions
- **Datomic**: Immutable database where every fact knows its history — inspiration for time-travel debugging

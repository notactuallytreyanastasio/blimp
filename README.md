# Blimp

An actor-oriented programming language with integrated AI agents, a persistent reasoning graph, and a browser-native development environment.

The language, the tooling, and the runtime are designed as a single unified system. Code structure is runtime structure. Agents are first-class collaborators with persistent memory. It compiles to LLVM IR targeting WebAssembly.

## The Language

Everything is an actor. There are no modules, no classes, no separate concept of "pure functions." A helper function is just an actor with one handler that replies immediately.

```
actor Counter do
  state count: Int :: 0

  on :increment do
    become count: count + 1
    reply count + 1
  end
end
```

### Typed State

State fields require types. The `::` separates type from default value. The compiler enforces this, not the runtime.

```
actor BankAccount do
  state balance: Int :: 0
  state owner: String :: "unknown"
  state ledger: [Transaction] :: []
  state frozen: Bool :: false

  on :deposit(amount: Int) do
    become balance: balance + amount
    reply balance + amount
  end
end
```

### Pipes

The pipe operator `|>` chains transformations. `_` marks where the piped value goes.

```
receipt = items
  |> calculate_tax(_, region)
  |> apply_discount(_, code)
  |> finalize(_, payment)
```

### Message Send

Actors talk to each other with `<-`. No PIDs, no process registry. Siblings address each other by name.

```
Shop.Checkout <- :add(%{name: "shirt", price: 29.99})

count = Shop.Inventory <- :check("shirt")

receipt = Shop.Checkout <- :charge(payment) orelse bubble
```

### Guards

Handlers can have `when` guards that filter on message parameters.

```
on :withdraw(amount: Int) when amount > 0 do
  become balance: balance - amount
  reply balance - amount
end
```

### Situations and Holes

`situation` is branching where ambiguity is explicitly allowed. A Hole (`_`) is a typed gap in your program that an agent fills. The comment after a Hole is a directive to the agent, not a note to yourself.

```
on :charge(payment: Payment) bubbles(CascadeBubble) do
  situation validate(payment) do
    :valid ->
      receipt = items
        |> calculate_tax(_, region)
        |> finalize(_, payment)
      become items: [], total: 0.0
      reply receipt
    _ # Hole: handle invalid payment,
      # begin by researching documentation
      # on transaction failure
  end
end
```

### Bubbles

Failure is handled by Bubble actors that walk the supervision tree deciding who dies. Different bubbles have different blast radii. You declare the strategy per handler with `bubbles()`. On the caller side, `orelse` catches bubbles.

```
on :charge(payment: Payment) bubbles(CascadeBubble) do
  # If this handler fails, CascadeBubble takes siblings down too
end

# Caller side: catch the bubble
receipt = checkout <- :charge(payment) orelse :fallback
```

### Namespaces are Supervision Trees

Dot-notation names define the supervision hierarchy. `Shop.Checkout` means Checkout is supervised by Shop. The namespace IS the blast radius.

```
actor Shop do
  state region: Atom :: :us
end

actor Shop.Checkout do
  state items: [Item] :: []
  state total: Float :: 0.0

  on :add(item: Item) do
    become items: [item | items],
           total: total + item.price
    reply length(items)
  end
end

actor Shop.Inventory do
  state stock: %{String => Int} :: %{}

  on :check(item_name: String) do
    reply lookup(stock, item_name)
  end
end
```

## Tooling

### Diff Follower

A Phoenix LiveView app that follows file changes in real time, stages, unstages, commits, with keyboard navigation and follow mode. This is the primary development interface right now. We use it to build itself.

### Agent Multiplexer

A 2x2 split-pane grid for running up to 4 Claude Code sessions simultaneously. Each pane streams agent output in real time, with per-pane chat for continuing conversations. The sidebar shows run history and lets you open any past run into a pane.

### Decision Graph

A persistent reasoning graph (deciduous) tracks every goal, decision, action, and outcome across sessions. The web viewer shows the full graph with git commit links.

## Implementation Status

The grammar is not hypothetical. We have:

- **Zig parser** that builds typed ASTs from Blimp source
- **Tree-sitter grammar** with corpus tests for all constructs
- **Diff follower** (Phoenix LiveView, fully functional)
- **Agent multiplexer** (Phoenix LiveView, functional, 4-pane split)
- **Decision graph** tracking all design evolution

What parses today: actors, typed state, message handlers with params, `when` guards, `bubbles()` annotations, `become`, `reply`, pipes `|>`, message send `<-`, `orelse`, `situation` with branches, Holes (`_`), dot-notation actor names, binary operators, function calls, dot access, atoms, strings, integers, floats, booleans, nil, lists, maps, tuples, comments.

**Build order (remaining):**
1. Type checker
2. Actor runtime (green-thread scheduler targeting WASM)
3. Agent protocol (Hole filling, decision graph merge)
4. The canvas (spatial visualization of running programs)

## Links

- [Design journal](https://blimp.bobbby.online/blog/)
- [Landing page](https://blimp.bobbby.online)

## License

MIT

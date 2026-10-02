# Dot Notation for Actor Names

## Syntax

Dot notation encodes the supervision hierarchy directly in actor names. A dot separates parent from child:

```blimp
actor Shop do
  state name: String :: "My Shop"
end

actor Shop.Checkout do
  state total: Int :: 0
  on :add(n: Int) do
    become total: total + n
    reply total + n
  end
end

actor Shop.Inventory do
  state stock: %{String => Int} :: %{}
  on :check(item_name: String) do
    reply lookup(stock, item_name)
  end
end
```

`Shop.Checkout` means "the Checkout actor, which is a child of Shop in the supervision tree."

### Where dots are allowed

| Context | Example | Status |
|---------|---------|--------|
| Actor definition | `actor Shop.Checkout do ... end` | Works |
| Message send target | `Shop.Checkout <- :add(10)` | Works |
| Spawn expression | `spawn Shop.Checkout` | Works |
| Assignment target | `x = Shop.Checkout <- :get` | Works |
| Mount (view composition) | `mount(Shop.Checkout)` | Planned (Agent 3) |
| WebSocket routing | Per-actor channels | Planned (Agent 6) |

Nesting is unlimited: `App.Shop.Checkout.PaymentProcessor` is valid.

## How dots map to supervision hierarchy

The dot is purely a naming convention at the language level. The runtime uses it for two things:

1. **Registry lookup**: The full dotted name is the key. `Shop.Checkout` is looked up as the literal string `"Shop.Checkout"` in both the template registry and the environment.

2. **Supervision relationships**: The registry uses string prefix matching to determine parent-child relationships. `restartChildren("Shop")` restarts all actors whose type_name starts with `"Shop."`. This means the hierarchy is flat in storage but hierarchical in semantics.

## Resolution: flat registry with dotted keys

Actor names are stored as flat strings with dots. There is no hierarchical namespace tree.

When you write `actor Shop.Checkout do ... end`:
- The parser joins the dot-separated parts into a single string: `"Shop.Checkout"`
- The template is registered under that full name
- A singleton instance is auto-spawned and bound in the environment as `"Shop.Checkout"`

When you write `Shop.Checkout <- :add(10)`:
- The parser produces a DotAccess AST node: `DotAccess(identifier("Shop"), "Checkout")`
- The evaluator flattens the DotAccess chain into `"Shop.Checkout"`
- It looks up `"Shop.Checkout"` in the environment, finds the auto-spawned actor_ref
- The message send proceeds normally against that ref

This means `Shop` and `Shop.Checkout` are independent actors. Defining `Shop.Checkout` does NOT require `Shop` to exist. The dot is a naming convention, not a namespace operation.

## Type checker integration

The type checker's `resolveActorName` flattens DotAccess chains the same way the evaluator does, then looks up the full dotted name in the actor registry. This enables:
- Argument type checking on message sends to dotted actors
- Return type inference from handler signatures
- State field type lookup via dot access on actor types

## Interaction with other features

### Agent 3: mount() for multi-actor view composition

`mount(Shop.Checkout)` will resolve the dotted name to find the actor, then render its view template. The DotAccess resolution in eval handles this since mount() receives the result of evaluating the expression.

### Agent 6: per-actor WebSocket routing

WebSocket channels can be routed by actor name. The dotted name provides a natural topic hierarchy: `ws://host/actors/Shop.Checkout` maps directly to the actor's full name in the registry.

## Implementation details

### Parser (parser.zig)

The `parsePostfix` function handles dot access. It now accepts both `identifier` and `upper_identifier` tokens after a dot, so `Shop.Checkout` parses as `DotAccess(identifier("Shop"), "Checkout")`.

Actor definitions use a separate dot-joining approach in `parseActorDef` that builds the full name string directly from contiguous source slices.

Spawn expressions handle dots in `parseSpawnExpr` by consuming `.upper_identifier` sequences and joining them with `allocPrint`.

### Evaluator (eval.zig)

`evalDotAccess` first tries to flatten the DotAccess chain into a dotted name and look it up in the environment. If found (as an actor_ref or any other value), it returns that. If not found, it falls back to map field access.

The `flattenDottedName` helper walks the DotAccess chain recursively, collecting parts, then joins them with dots. It handles up to 16 levels of nesting.

### Type checker (checker.zig)

`resolveActorName` handles `.dot_access` nodes by flattening them via `flattenDottedNameForChecker` and looking up the result in the actor registry.

`inferDotAccess` checks if the DotAccess chain resolves to a known actor name before falling back to state field lookup.

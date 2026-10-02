# View Composition: Multi-Actor Pages

> One actor, one component. mount() is the seam.

## Context

Before this, `render_app(data)` was a single pure function returning one view tree. There was no way for one actor's view to embed another actor's view. This document describes the composition model that fixes that.

Related docs: `view-dsl.md`, `view-engine.md`, `actor-runtime.md`.

## The Model

An actor becomes a UI component by defining an `on :render` handler. A parent composes child actors using `mount()`, which sends `:render` to the child and wraps the result in a mount boundary for message routing.

```blimp
actor Counter do
  state count: Int :: 0

  on :increment do
    become count: count + 1
  end

  on :render do
    reply stack(
      text(to_string(count)),
      button("+ 1", :increment)
    )
  end
end

actor Greeter do
  state name: String :: "World"

  on :render do
    reply text(concat("Hello, ", name))
  end
end

# Root composition -- mounts both actors
def render_app() do
  stack(
    heading("My App"),
    mount(Counter),
    mount(Greeter)
  )
end
```

## How mount() Works

`mount` is a Blimp-level function, not a Zig builtin:

```blimp
def mount(actor_ref) do
  name = actor_name(actor_ref)
  view = actor_ref <- :render
  mount_root(name, view)
end
```

Three things happen:

1. `actor_name(ref)` extracts the type name from the actor reference (e.g. "Counter")
2. `actor_ref <- :render` sends the `:render` message and gets back a `view_node`
3. `mount_root(name, view)` wraps the view in a mount boundary node

`mount_root` is a Zig builtin that creates a `ViewNode` with tag "mount" and a `data-actor` attribute. When rendered to HTML by `to_html()`, this becomes:

```html
<div data-actor="Counter">
  <!-- Counter's rendered view tree -->
</div>
```

## Message Routing

This is the hard part. When a button inside a mounted Counter is clicked, the message must go to Counter, not to the parent.

### The DOM Walk

The client-side JS walks up the DOM from the clicked button to find the nearest `data-actor` boundary:

```javascript
function blimpSend(btn) {
  var msg = btn.getAttribute('data-sends');
  var actor = '';
  var el = btn;
  while (el) {
    if (el.getAttribute && el.getAttribute('data-actor')) {
      actor = el.getAttribute('data-actor');
      break;
    }
    el = el.parentElement;
  }
  // POST both msg and actor to the server
}
```

The form POST includes two fields: `msg=increment&actor=Counter`.

### Server-Side Routing

The server dispatcher reads both fields and routes the message to the correct actor:

```blimp
def route_message(target_actor, msg_str) do
  case target_actor do
    "Counter"  -> route_counter(msg_str)
    "Greeter"  -> route_greeter(msg_str)
    _          -> :unknown
  end
end

def route_counter(msg_str) do
  case msg_str do
    "increment" -> Counter <- :increment
    "decrement" -> Counter <- :decrement
    "reset"     -> Counter <- :reset
    _           -> :unknown
  end
end
```

### Why Static Routing (For Now)

The routing is static because Blimp's message send syntax (`Actor <- :message`) requires a compile-time message name. You can't do `Actor <- some_variable`. This is by design -- it makes message flow visible in the source code.

The trade-off: every new message handler needs a corresponding route entry. This is the same trade-off as having an explicit reducer in Elm or Redux. It's verbose but safe.

When dynamic message sends are added to the language (passing an atom variable as a message), the routing can collapse to:

```blimp
def route_message(target_actor, msg_str) do
  actor = lookup_actor(target_actor)
  msg = to_atom(msg_str)
  actor <- msg  # hypothetical dynamic send
end
```

## The View Tree

After composition, the view tree looks like:

```
stack
  heading "My App"
  mount [data-actor="Counter"]
    stack
      text "0"
      button "+ 1" [sends=:increment]
  mount [data-actor="Greeter"]
    stack
      text "Hello, World"
      button "Toggle" [sends=:toggle_excitement]
```

The mount boundaries are invisible to the user but critical for routing. They render as plain `<div>` elements with a `data-actor` attribute. CSS can target them: `div[data-actor] { border: 1px solid #ddd; }`.

## New Builtins

| Builtin | Signature | Purpose |
|---------|-----------|---------|
| `mount_root` | `(String, ViewNode) -> ViewNode` | Creates a mount boundary node |
| `actor_name` | `(ActorRef) -> String` | Extracts type name from an actor reference |
| `to_atom` | `(String) -> Atom` | Converts a string to an atom |

## Interaction with Other Agents' Work

### Agent 4: Dot Notation (Shop.Checkout)

Dot notation in actor names works with mount directly:

```blimp
actor Shop do
  state region: Atom :: :us
end

actor Shop.Checkout do
  state items: [Item] :: []

  on :render do
    reply stack(
      heading("Checkout"),
      list(items |> map(fn(item) do text(item.name) end))
    )
  end
end

# In the root render:
mount(Shop.Checkout)
```

The `data-actor` attribute will be `"Shop.Checkout"` and the routing table matches on that string.

### Agent 6: WebSocket Diffing

When WebSockets replace the current HTTP POST/redirect cycle, mount boundaries become diff boundaries. The server can:

1. Track which actors' state changed since the last render
2. Only re-render and diff changed actors' subtrees
3. Send per-actor patches: `{actor: "Counter", patch: [{op: "replace", path: "/0/0", value: "5"}]}`

The mount boundary's `data-actor` attribute provides the DOM anchor for applying patches to the correct subtree.

### Agent 1: Input Fields

When input fields exist (text_input, select, etc.), they'll need to send their values along with the message. The `data-actor` routing works the same way -- the JS collects the input value and includes it in the POST alongside `msg` and `actor`.

### Agent 2: Sessions

Multi-session support means each session gets its own actor instances. The mount model doesn't change -- `mount(Counter)` mounts whatever Counter instance belongs to the current session. The session layer is below the view composition layer.

### Agent 5: Concurrent Connections

Multiple connections rendering simultaneously will each call `:render` on actors. Since actors process messages sequentially, renders are serialized per-actor. The mount model is safe for concurrent access because each mount call is a message send, and messages are handled one at a time.

## Design Decisions

**Why not make mount a Zig builtin?** Because builtins only get `(allocator, args)` -- they can't access the actor registry or evaluator. Making mount a Blimp function that calls `:render` keeps the Zig layer simple and the Blimp layer expressive.

**Why a separate mount_root builtin?** Because we need to create a ViewNode with a special tag ("mount") and attribute ("data-actor") that the HTML renderer understands. This is a one-line Zig function that fits the existing builtin pattern perfectly.

**Why static message routing?** Blimp's `<-` operator takes a compile-time message name. This is intentional -- it makes message flow greppable and statically analyzable. Dynamic sends may come later but static routing is the safe default.

**Why DOM walk for actor resolution?** Because it composes naturally. Nested mounts work without extra plumbing -- the nearest `data-actor` ancestor wins. This is the same principle as CSS cascade and event bubbling.

## Open Questions

1. **Parameterized mount**: `mount(Counter, %{initial: 10})` -- should mount support passing initial state overrides to the actor? Currently actors use their default state.

2. **Actor lifecycle**: What happens when a mounted actor crashes? The parent re-renders and calls `:render` on the crashed actor, which may be in a reset state. The supervision hierarchy (from actor-runtime.md) handles restart, but the view layer needs to handle the "briefly unavailable" state.

3. **Dynamic actor lists**: `for actor in actors do mount(actor) end` -- mounting a dynamic list of actors requires keyed diffing to avoid remounting everything on list changes.

4. **Nested mount routing**: If Counter mounts a sub-actor, the DOM walk finds the innermost `data-actor` boundary. This is correct behavior but means the routing table needs entries for all mountable actors, not just top-level ones.

5. **Dynamic message sends**: The `to_atom` builtin exists but `Actor <- variable_atom` doesn't work in the AST yet. Adding this would collapse the static routing table to a single generic router.

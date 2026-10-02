# View DSL: Purely Functional UI Primitives

> Views are just actors replying to `:render`. Everything else follows.

## Context

This document describes Blimp's opinionated UI layer: a purely functional view DSL built on the actor model, with server-side diffing over WebSockets. Related docs: `actor-runtime.md`, `core-language-feel.md`.

## Core Decision

`view do...end` is syntactic sugar for `on :render do reply ... end`.

This falls out of the actor model for free:

```ruby
actor App.Session do
  state page: :home, cart: []

  view do
    stack do
      heading "My App"
      text "Welcome"
    end
  end
end
```

Desugars to:

```ruby
actor App.Session do
  state page: :home, cart: []

  on :render do
    reply stack(
      heading("My App"),
      text("Welcome")
    )
  end
end
```

**Why this matters:** Time-travel debugging works on views for free. Because `:render` is a message, you can do:

```
blimp> App.Session @ t3 <- :render
=> <stack><heading level=1>"My App"</heading><text>"Welcome"</text></stack>

blimp> diff(App.Session @ t1 <- :render, App.Session @ t5 <- :render)
=> [{:update, [0, 0], "Your Cart"}, {:replace, [1], <row>...</row>}]
```

## View Tree Value Type

A new `Value` variant: `view_node`. Every view primitive returns a `view_node`. The evaluator treats these as ordinary values — they can be stored, passed as arguments, pattern matched, returned from functions.

```zig
pub const ViewNode = struct {
    tag: []const u8,
    attrs: []const ViewAttr,
    children: []const *const Value,

    pub const ViewAttr = struct {
        key: []const u8,
        val: *const Value,
    };
};
```

Format: `<tag attr=val>children</tag>` or `<tag attr=val />` for leaf nodes.

## Primitive Set

Chosen to match what markdown gives you, plus media embeds and canvas.

### Layout
| Primitive | Signature | Notes |
|-----------|-----------|-------|
| `stack` | `(child...) -> view_node` | Vertical flex container |
| `row` | `(child...) -> view_node` | Horizontal flex container |
| `grid` | `(child...) -> view_node` | Grid container |

### Typography (markdown parity)
| Primitive | Signature | Notes |
|-----------|-----------|-------|
| `text` | `(string) -> view_node` | Inline text |
| `heading` | `(string, level?) -> view_node` | h1-h6, level defaults to 1 |
| `bold` | `(string) -> view_node` | Strong/bold text |
| `italic` | `(string) -> view_node` | Em/italic text |
| `code` | `(string) -> view_node` | Inline code span |
| `code_block` | `(string, lang?) -> view_node` | Fenced code block, optional lang atom |
| `blockquote` | `(string) -> view_node` | Block quote |
| `divider` | `() -> view_node` | Horizontal rule |
| `list` | `(item...) -> view_node` | Unordered list, variadic items |

### Navigation
| Primitive | Signature | Notes |
|-----------|-----------|-------|
| `link` | `(label, url) -> view_node` | Anchor, href attr |

### Media
| Primitive | Signature | Notes |
|-----------|-----------|-------|
| `image` | `(src, alt?) -> view_node` | Img embed, alt optional |
| `video` | `(src) -> view_node` | Video embed |
| `canvas` | `(id) -> view_node` | 2D drawing canvas |

### Interactive
| Primitive | Signature | Notes |
|-----------|-----------|-------|
| `button` | `(label, sends?) -> view_node` | Clickable button; `sends:` is an atom that becomes a message to the session actor |

## The `sends:` Convention

`sends:` on a button is an atom naming the message to send to the actor when clicked:

```ruby
button("Add to cart", :add_item)
# => <button sends=:add_item>"Add to cart"</button>
```

When the browser receives this tree, it knows: when this button is clicked, send `{msg: "add_item"}` over the WebSocket. The server routes it to the session actor's mailbox as `:add_item`.

## Semantic Model

1. Browser connects over WebSocket → server spawns a session actor
2. Server calls `Session <- :render` → gets view tree
3. Server serializes tree as JSON, sends to browser
4. Browser renders it (minimal runtime, ~50 lines JS)
5. User clicks a button with `sends: :checkout`
6. Browser sends `{msg: "checkout"}` over WebSocket
7. Server routes to session actor: `Session <- :checkout`
8. Handler runs, `become` transitions state
9. Server calls `Session <- :render` with new state
10. Server diffs old tree vs new tree
11. Server sends JSON patch over WebSocket
12. Browser applies patch

## REPL Interaction

```
blimp> actor Page do
  ...   state count: 0
  ...
  ...   view do
  ...     stack(
  ...       heading("Counter"),
  ...       text(to_string(count)),
  ...       button("Increment", :inc)
  ...     )
  ...   end
  ...
  ...   on :inc do
  ...     become count: count + 1
  ...   end
  ... end
=> <actor Page { count: 0 }>

blimp> Page <- :render
=> <stack><heading level=1>"Counter"</heading><text>"0"</text><button sends=:inc>"Increment"</button></stack>

blimp> Page <- :inc
=> nil

blimp> Page <- :render
=> <stack><heading level=1>"Counter"</heading><text>"1"</text><button sends=:inc>"Increment"</button></stack>
```

Time travel:

```
blimp> history Page
  t0  spawned     count: 0
  t1  :inc        count: 1
  t2  :inc        count: 2

blimp> Page @ t0 <- :render
=> <stack>...<text>"0"</text>...</stack>

blimp> diff(Page @ t0 <- :render, Page @ t2 <- :render)
=> [{:update, [1, 0], "2"}]
```

## Open Questions

1. **Session spawning**: How are N session actors given unique identities? The registry currently holds one actor per name. Need dynamic spawning with auto-generated IDs (`Session#42`, `Session#43`).

2. **Nested `sends:`**: What if a button inside a `list` needs to send `:remove(item)` where `item` is loop data? The sends atom can't carry runtime data as written. Needs either a tuple form (`sends: {:remove, item}`) or a closure form.

3. **The diff algorithm**: Keyed vs unkeyed diffing. If the tree has no stable keys, list reorderings are misidentified as updates. Markdown content probably never reorders, but data lists do. A `key:` attr on list items would help.

4. **HTTP layer**: Not yet designed. Needs `actor HTTP.Router`, connection upgrade to WebSocket, session actor lifecycle (spawn on connect, kill on disconnect).

5. **The `view do...end` syntax**: Parser doesn't support it yet. Currently `view` would need to be a special block keyword in the parser, or implemented as a convention (function named `render`).

## References

- Phoenix LiveView: server-side diffing inspiration
- Elm Architecture: pure view functions, typed messages
- Solid.js: fine-grained reactivity, no VDOM
- Morphdom: efficient DOM patching

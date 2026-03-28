# Blimp View Engine

Actors define views. Views are first-class values. The runtime renders them to the DOM, and buttons send messages back to actors. That's the whole model.

## The Core Loop

```
spawn actor -> send :view -> get view_node tree -> render DOM
                                                      |
                                               button clicked
                                                      |
                                          send :message to actor
                                                      |
                                            actor does become
                                                      |
                                          send :view again -> re-render
```

No framework. No virtual DOM diffing library. No build step. The actor IS the component. `become` IS setState. The `:view` handler IS the render function.

## View Primitives

All view functions return `view_node` values -- a tagged tree with attributes and children. They compose by nesting.

### Layout

| Function | Renders as | Purpose |
|----------|-----------|---------|
| `stack(children...)` | Vertical flex column | Stack things top to bottom |
| `row(children...)` | Horizontal flex row | Put things side by side |
| `grid(children...)` | CSS grid, auto-fit | Responsive grid layout |

### Text

| Function | Renders as | Purpose |
|----------|-----------|---------|
| `text(value)` | `<span>` | Display any value as text |
| `heading(str)` | `<h1>` | Level 1 heading (default) |
| `heading(str, n)` | `<h1>`-`<h6>` | Heading at level n |
| `bold(str)` | `<strong>` | Bold text |
| `italic(str)` | `<em>` | Italic text |
| `code(str)` | `<code>` | Inline code |
| `code_block(str)` | `<pre>` | Code block |
| `code_block(str, :lang)` | `<pre data-lang>` | Code block with language |
| `blockquote(str)` | `<blockquote>` | Quoted text |

### Structure

| Function | Renders as | Purpose |
|----------|-----------|---------|
| `divider()` | `<hr>` | Horizontal rule |
| `list(items...)` | `<ul><li>` | Bulleted list |
| `link(label, href)` | `<a>` | Hyperlink |

### Media

| Function | Renders as | Purpose |
|----------|-----------|---------|
| `image(src, alt)` | `<img>` | Image |
| `video(src)` | `<video>` | Video with controls |
| `canvas(id)` | `<canvas>` | Raw canvas element |

### Interactive

| Function | Renders as | Purpose |
|----------|-----------|---------|
| `button(label)` | `<button>` | Static button |
| `button(label, :msg)` | `<button onclick>` | Button that sends `:msg` to the actor |

## Actors as Components

An actor becomes a UI component by defining a `:view` handler that returns a view_node tree, and message handlers that update state via `become`.

```blimp
actor Counter do
  state count: Int :: 0

  on :increment do
    become count: count + 1
  end

  on :decrement do
    become count: count - 1
  end

  on :view do
    stack(
      heading("Counter"),
      text(count),
      row(
        button("- 1", :decrement),
        button("+ 1", :increment)
      )
    )
  end
end

c = spawn Counter
send(c, :view)
```

The view handler reads from the actor's state fields directly. No props, no binding syntax, no subscriptions. The state is right there.

## The Button Protocol

`button("label", :message_name)` creates a button that, when tapped, sends `:message_name` to the actor that owns this view. The runtime then re-calls `:view` and re-renders.

This means any actor handler can be triggered from the UI. The same message that another actor would send via `send(ref, :increment)` is the same message the button sends. There's no separate "UI event" concept. Messages are messages.

## View Nodes as Values

View nodes are regular Blimp values. You can:

- Store them in variables: `v = heading("hello")`
- Pass them to functions: `def wrap(content) do stack(heading("Page"), content) end`
- Return them from handlers
- Put them in lists
- Compare them for equality

`type_of(heading("hi"))` returns `:view_node`.

A view node serializes as `<tag attr=val>children</tag>` when printed, but the runtime works with the structured tree, not strings.

## WASM Bridge

The interpreter compiles to WebAssembly. The view pipeline:

1. Zig evaluates Blimp code, produces `view_node` values
2. `wasm_api.zig` serializes view trees as JSON via `blimp_get_view_ptr/len`
3. `blimp.js` parses the JSON and exposes `result.view`
4. The page's `renderView()` walks the tree and creates DOM elements
5. Button click handlers call `blimp.eval('send(var, :msg)')` and re-render

## Canvas Visualization

Every actor also gets a generative hexagonal visualization on the canvas. The hexagons:

- Use SHA-256 hashed state for unique generative fill patterns
- Flash white when state changes
- Receive animated message rays when messages are sent
- Auto-layout in a hex-packed grid

The canvas and the rendered view are two representations of the same system. Swipe between them.

## What's Not Here Yet

- **Input fields**: No `input(placeholder)` or `text_input(binding)` yet. Buttons-only for now.
- **Multi-actor views**: Implemented via `mount()`. See `view-composition.md` for the full design.
- **Conditional rendering**: Works via `if/else` in the view handler, but no `:if` attribute on view nodes.
- **Animation**: State changes re-render immediately. No transition system between view states.
- **CSS/styling**: View nodes map to fixed CSS classes. No inline style attribute yet.
- **Forms**: No form submission, no input validation in the view layer.

## Design Decisions

**Why not HTML templates?** Because views are values. You can compute them, compose them, pass them around. A template is a string. A view_node is a tree you can inspect and transform.

**Why not React/virtual DOM diffing?** The actor's state is the single source of truth. When state changes, re-render from scratch. The view trees are small (phone-screen UIs, not huge SPAs), so full re-render is fast enough. If it becomes a bottleneck later, diffing can be added without changing the programming model.

**Why buttons send atoms?** Because atoms are how actors receive messages. `button("Go", :start)` sends `:start` -- the same thing `send(ref, :start)` does. One message protocol for everything.

**Why no JSX/DSL syntax?** The view primitives are regular function calls. `stack(heading("hi"), text("world"))` reads fine and composes naturally. A special syntax would add parser complexity for minimal readability gain. If Blimp ever gets macros, someone could build a template syntax as a library.

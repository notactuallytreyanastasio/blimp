# Forms and Input Fields

> View primitives for collecting user input and sending it as form data alongside messages.

## Design

### The Problem

Before this work, `button("label", :msg)` was the only interactive element. Clicking a button sent a POST with `msg=<atom>` in the body. There was no way to collect text input from the user.

### The Solution

Five new view primitives, a `form()` wrapper, and a form data parsing pipeline.

**Key decision:** Buttons inside a `form()` collect all sibling input values and POST them together. This is the standard HTML form model -- no custom wire protocol needed.

## New View Primitives

| Primitive | Signature | HTML Output |
|-----------|-----------|-------------|
| `input("name", "placeholder")` | 2 string args | `<input name="..." placeholder="...">` |
| `input("name", "placeholder", :type)` | 3rd arg is atom | `<input name="..." placeholder="..." type="...">` |
| `textarea("name", "placeholder")` | 2 string args | `<textarea name="..." placeholder="...">` |
| `select("name", option1, ...)` | name + option children | `<select name="..."><option>...</option></select>` |
| `option("label", "value")` | display text + form value | `<option value="...">label</option>` |
| `form(children...)` | variadic view children | `<form method="POST">children</form>` |

### Input types

The optional third argument to `input()` is an atom specifying the HTML input type:

```blimp
input("email", "you@example.com", :email)
input("pass", "Password", :password)
input("age", "25", :number)
```

Without a type, it renders as a plain text input.

## How Forms Work

### The Flow

1. User fills in inputs and clicks a button with `:msg` inside a `form()`
2. JS intercepts the click, adds `msg=<atom>` as a hidden field
3. Browser submits the form as a standard POST with all input values
4. Server extracts the body after `\r\n\r\n`
5. `parse_form_data(body)` builds a `%{key: value}` map from `key=val&key2=val2`
6. `handle_event(data, msg, form_data)` receives both the message atom and form data
7. Handler reads input values with `lookup(form_data, "input_name")`

### Example: Todo List

```blimp
def render_app(data: Map) -> ViewNode do
  stack(
    heading("Todo List"),
    form(
      row(
        input("todo_text", "What needs to be done?"),
        button("Add", :add_todo)
      )
    ),
    render_todo_list(lookup(data, "todos"))
  )
end

def handle_event(data: Map, msg: Atom, form_data: Map) -> Map do
  case msg do
    :add_todo ->
      todo_text = lookup(form_data, "todo_text")
      # ... add to list
    _ -> data
  end
end
```

### Signature Change

`handle_event` now takes three arguments instead of two:

```blimp
# Before (button-only)
def handle_event(data: Map, msg: Atom) -> Map do

# After (forms)
def handle_event(data: Map, msg: Atom, form_data: Map) -> Map do
```

The `form_data` map contains all `name=value` pairs from the POST body, including the `msg` field itself.

## List Flattening in Containers

A key implementation detail: container primitives (`stack`, `row`, `grid`, `form`) now flatten list children. This means:

```blimp
items = map(todos, fn(t: Map) do text(lookup(t, "text")) end)
stack(items)  # items is a list of view nodes -- flattened into children
```

Without flattening, `stack(items)` would create a `<div>` with a single list child. With flattening, each item becomes a direct child of the `<div>`.

## URL Decoding

Form values are URL-encoded by the browser. The server does basic decoding:
- `+` becomes space
- (Percent-encoding like `%20` is not yet handled)

## Bug Fix: String Pattern Matching

During this work, a bug was discovered and fixed in the evaluator's pattern matching. The lexer stores string literals with quotes (`"POST"`), but runtime string values are unquoted (`POST`). The pattern matcher now strips quotes before comparing, making `case` branches with string patterns work correctly.

## CSS

Input fields, textareas, and selects get baseline styling:
- Consistent padding and border radius matching buttons
- Blue focus ring (matches the button color)
- Max width of 400px for text inputs
- Responsive textarea with resize handle

## WebSocket Integration

The JS client (updated by Agent 6) handles form submission over WebSocket when available:
- Buttons inside forms collect all input values via `FormData`
- Data is sent as JSON: `{"type":"event","msg":"add_todo","form_data":{"todo_text":"hello"}}`
- Falls back to standard form POST when WebSocket is not connected

## Files Changed

- `chunks/lang/src/builtins.zig` -- new view primitives (`viewInput`, `viewTextarea`, `viewSelect`, `viewOption`, `viewForm`), to_html rendering, list flattening in `makeViewNode`
- `chunks/lang/src/eval.zig` -- fixed string pattern matching in `matchPattern`
- `chunks/lang/web/server.blimp` -- todo list demo, `parse_form_data`, `handle_event` with form data, CSS/JS updates

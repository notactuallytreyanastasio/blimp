# Chapter 10: A page of your own

Tetris drew itself with `heading`, `row` and `stack`, and listened with `key` and `timer`.
Most pages are not games. They are forms and lists: something to type into, a list of what was typed, a button that asks "are you sure?".
This chapter builds one, a guestbook, with the part of Blimp's view that pages like that need.

By the end of it people can leave a note, the newest goes on top, a note can be taken down after a confirmation, and the whole book is still there when the page is reloaded.
There is no JavaScript in it.
Every page on [bobbby.online/aim](https://bobbby.online/aim) is built from the same pieces, so when this chapter says "the obvious version is wrong", it is because the obvious version was written there first.

## `el` is a real element

`el(tag, attrs, children...)` makes an HTML element: a tag, a map of attributes, and children.
Printed with `to_html`, it is exactly the markup the page gets:

```blimp
puts(to_html(el("p", %{class: "note"}, "hello")))
```

```
<p class="note">hello</p>
```

Children can be strings, other `el`s, or lists of either.
A list is spliced in, as with `stack`.

`class:` and `style:` take data as well as strings.
A class can be a list of names, or a map of names to whether they apply.
A style can be a map.

```blimp
puts(to_html(el("li", %{class: %{note: true, fresh: true}}, "hi")))
puts(to_html(el("li", %{class: ["note", nil, "fresh"]}, "hi")))
puts(to_html(el("div", %{style: %{translate: "12px 4px", "z-index": 4, color: nil}}, "x")))
```

```
<li class="note fresh">hi</li>
<li class="note fresh">hi</li>
<div style="translate: 12px 4px; z-index: 4;">x</div>
```

A `nil` or `false` leaves a name or a property out.
That replaces the concatenating people do otherwise, `concat("note", case fresh do true -> " fresh" false -> "" end)`.
bobbby.online's pages built a class or a style by concatenating like that 83 times before `el` took lists and maps.
Numbers go in as they are, so `"z-index": 4` is right and a width wants `"12px"`.
And a name that is a Blimp keyword, like `on` or `end`, must be quoted as a map key: `%{"on": true}`.

## Attributes that are instructions

Some keys in that map are not HTML.
`click: :ask_delete` tells the page to send the actor `:ask_delete` when the element is clicked, and `with: n.id` gives the message an argument, so the actor gets `:ask_delete(3)`.
They never reach the markup:

```blimp
puts(to_html(el("form", %{submit: :post, reset_on_submit: true},
  el("textarea", %{name: "text", submit_on_enter: true, focus: true}))))
```

```
<form><textarea name="text"></textarea></form>
```

The [view reference](../view/reference.html) lists every one.
This chapter uses seven: `click:`, `with:`, `submit:`, `reset_on_submit:`, `submit_on_enter:`, `focus:` and `key:`.

## The form arrives as a map

`submit: :post` sends the form's fields when it is submitted, as a map:

```blimp
on :post(f: Map) do
  text = gb_trim(f.text)
  ...
```

`f` is `%{"name": "amy", "text": "hi there"}`, so `f.name` and `lookup(f, :text)` both read it.
A checkbox arrives as `true` or `false`, and a group of radio buttons as the value of the one that is checked.
The keys are quoted because a field can be called `size-pick`.

Three more instructions make the form behave like a chat box:

- `submit_on_enter: true` on the textarea: Enter submits the form, and Shift+Enter is a new line.
- `reset_on_submit: true` on the form: once the fields are sent, the form empties.
- `focus: true` on the textarea: it takes the focus whenever nothing else has it.

A note on `reset_on_submit`, because the obvious way to empty a field is wrong.
A program cannot reach into a field and clear it, so the trick is to change the field's `id`, which makes the page throw the old element away and draw a new, empty one.
That works, and it also throws away the focus, which is the one thing a chat box must keep.
bobbby.online's chat boxes were emptied that way until `reset_on_submit` existed.
`reset_on_submit` empties the same element.

Blimp has no `trim`, by the way.
bobbby.online's comes from its Temper library.
So the guestbook has a small `gb_trim`, written with `slice`.

## Maybe: `show`

A page is full of things that are there only sometimes: the "nobody has signed yet" line, the dialog.
`show(cond, node)` is `node` when `cond` is true, and nothing when it is false:

```blimp
show(notes == [], el("p", %{class: "empty"}, "Nobody has signed yet."))
```

`show` is lazy: `node` is only built when `cond` is true.
That matters more than it looks:

```blimp
q = nil
puts(to_html(el("div", %{}, show(q != nil, el("p", %{}, q.text)), "after")))
```

```
<div>after</div>
```

If `show` built `node` first, `q.text` would be an error with `q` nil, before `show` ever saw the condition.
The first version of `show` did exactly that, and it failed the first time it was used for real.
"Show this thing's part, if the thing is there" is most of what a maybe is for.

A `nil` or `false` child is also nothing, so a helper can return `nil` for "nothing here".

## Lists, and `key:`

The notes are a list, newest first: a new note goes at the front.

```blimp
el("ul", %{class: "notes"}, map(notes, fn(n: Map) -> Any do gb_note(n, newest) end))
```

When the list changes, the page has to decide which old element becomes which new one.
Without help it goes by position: the first `<li>` shows the first note, the second the second.
For a list that grows at the end that is right.
For one that grows at the front it is wrong. The new note is drawn into the old first element, the old first note into the second, and so on down the list, so anything that was happening in a row moves to another note.
On bobbby.online a grid of YouTube videos had its whole server shaped around that: "a video that is playing never moves".

`key: n.id` on each item tells the page which note is which.
A new note on top is then one new element, and the rest are left exactly as they were.
Every child of the list needs a key, and two with the same key are an error.

## The dialog

Taking a note down asks first.
That is a dialog, and the browser has one built in, which Blimp uses:

```blimp
show(confirming != 0, el("dialog", %{modal: true, dismiss: :cancel},
  el("p", %{}, "Take this note down?"),
  el("button", %{click: :delete}, "Take it down"),
  el("button", %{click: :cancel}, "Keep it")))
```

`modal: true` opens it the way the browser's own modal dialogs open: with a dimmed backdrop, the focus kept inside, and the page behind it unclickable.
`dismiss: :cancel` is sent when the reader presses Escape or clicks the backdrop.
Whether it is open is the program's business: it is open while it is in the view, which is while `confirming` is not 0.

Why not a full-page `div` with `click: :cancel` on it?
Only the innermost `click:` runs, so a click on the dialog's text, which has no `click:` of its own, lands on the overlay and closes the dialog.
The hand-made modals on bobbby.online each worked around it: a do-nothing `click: :stay` on the dialog, a separate backdrop element, or a script that checked where the click landed.

## Remembering between visits

A page forgets everything when it is reloaded, unless it keeps something in the browser's storage.
Two view nodes do that:

```blimp
stored("guestbook.notes", :remembered),
store("guestbook.notes", json_encode(notes))
```

`stored(key, :msg)` reads the key once and sends `:remembered(text)`, with `""` if nothing was kept.
`store(key, value)` keeps `value` under `key`, and writes it only when it has changed, so rendering it every time costs nothing.
The guestbook keeps the notes as JSON, and the name, so the form remembers who you are.

The page reads before it writes.
The guestbook's first view, drawn before anything is read, says `store("guestbook.notes", "[]")`.
If that were written first, the book would be emptied before it could be read back.

Like `key` and `timer`, these draw nothing:

```blimp
puts(to_html(el("div", %{}, stored("k", :got), store("k", "v"), timer(1000, :tick), "only this")))
```

```
<div>only this</div>
```

## The time

Each note says when it was written, in the reader's time zone:

```blimp
format_time(at + utc_offset(), "%I:%M %p")
```

`now()` is seconds since 1970, and `utc_offset()` is how many seconds the reader's zone is ahead of UTC (-14400 in New York in summer).
In the browser they come from the page's clock.
Until Blimp chapter 46 `now()` returned 0 there, because WebAssembly has no clock of its own.

## The exercise

Open `exercises/ch10_page/01_guestbook.blimp` in the editor.
`:view` is finished. Read it first, because it is everything above in one place.
Four parts are yours:

1. **`:post`**. Trim the name and the text; no text means `:ignored`; otherwise a note `%{id: next, name: ..., text: ..., at: now()}` goes at the front, "anonymous" if there is no name.
2. **`:delete`**. Take out the note whose id is `confirming`, and close the dialog.
3. **`:remembered`**. Decode what `store` kept. Only a list counts, and `next` goes on from its highest id.
4. **`gb_note`**. One `<li>`, with `key: n.id` and the class map `%{note: true, fresh: n.id == newest}`.

The tests are in the file, as before.
Run them, and when they pass, press **Play my code**.
Leave a note, take one down, reload the tutorial page and come back to this chapter: Play again, and the book is still there.

## Where to take it

- **Talk to a server.** `socket("/live/room", %{frame: :frame, open: :up, closed: :down, sent: :sent}, first, outbox)` holds a WebSocket while it is in the view. Every frame from the server is `:frame(text)`, and the program's outbox goes up one frame at a time, each exactly once. That is how [bobbby.online/aim](https://bobbby.online/aim) chats, with no script of its own.
- **Move things.** `drag: :moved` on a title bar sends `:moved(dx, dy)` while it is dragged; the program keeps the offset and draws the window there (`style: %{translate: ...}`).
- **Follow a log.** `scroll: :end` keeps a transcript at its last line, unless the reader has scrolled up to read.
- **Ask the server.** `fetch("/api/notes", :got)` GETs once and sends `:got(status, body)`.

All of them, with the rules for each, are in the [view reference](../view/reference.html).

## What you learned

- `el` makes real elements. `class:` and `style:` take lists and maps, and instructions like `click:` never reach the markup.
- A form's `submit:` arrives as a map. `reset_on_submit`, `submit_on_enter` and `focus` make it a chat box.
- `show(cond, node)` is a lazy maybe, and `nil` children are nothing.
- `key:` tells the page which item is which, so a list that grows at the top keeps its rows.
- `el("dialog", %{modal: true, dismiss: :msg})` is the browser's own dialog, and the program decides when it is open.
- `stored` and `store` remember between visits, read first.
- `now()` and `utc_offset()` are the reader's clock.

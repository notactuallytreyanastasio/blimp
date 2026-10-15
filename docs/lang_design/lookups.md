# Lookups: actors by id, builtins by name

## What changed

Two lookups the evaluator makes on nearly every step were linear scans with
string or integer compares. Both are now indexed.

- `Registry.getInstance` (`src/registry.zig`) walked `instances` comparing
  ids until it found the target of a send. It now reads `by_id[id]`, a slot
  per actor ever spawned. Ids are dense and never reused, so the index is an
  array, not a map; a slot is null once a compaction dropped its actor.
- `BuiltinRegistry.get` (`src/builtins.zig`) walked the two hundred and four
  registered builtins comparing names on every call of one. It now reads a
  `StringHashMap` filled in `register`.

## Why it mattered

A send to an actor spawned late in a run cost as much as the number of actors
spawned before it. Nothing in the language makes that visible: a program with
a dozen actors never notices. A Temper program compiled to Blimp has an actor
per object, so a Markdown renderer that makes a token actor per emphasis run
had thousands alive, and every field read was a scan of all of them.

The probe (`actor Cell` with one field; twenty thousand `c <- :get` reads of
one cell, the cell spawned either after a hundred others or after twenty
thousand and a hundred):

```
                                  before     after
  spawned after 100 others          7 ms      7 ms
  spawned after 20101 others      467 ms      7 ms
```

Before, a read of the late cell cost 23 us; after, 0.35 us, the same as the
early one. The same change in the Temper fork took a field read on a
thirteen-field object, measured after the html library's test suite had
spawned a few thousand actors, from 39 us to under 1 us, and a 2,000
character Markdown paragraph with emphasis and links from 257 ms to 55 ms.
The builtin index took that paragraph to 45 ms.

## Compaction

`gc.compact` copies the live instances into a new allocator and swaps the
list in. The index lived in the old allocator, so `compact` calls
`Registry.reindex`, which rebuilds `by_id` from the new list with the new
allocator. The dropped actors' slots come back null; a send to one of them
answers "not an actor", as it did before.

## What is still linear

`runScheduler` (`src/eval.zig`) still walks every instance looking for a
non-empty mailbox, and does so after every async send (`<--`). A program
that sends asynchronously to a few of many actors pays for all of them on
each send. The fix is a queue of actors with mail, which the `Scheduler`
already has in outline; it is not done.

`Environment.lookup` (`src/env.zig`) compares names byte by byte inside a
scope, behind a 64-bit first-last-length filter. A native profile of the
Markdown probe after these two changes puts `mem.eqlBytes` and `lookup`
first among the interpreter's own frames. Interning names at parse time, or
carrying a hash in the identifier node, is the next step and is not done.

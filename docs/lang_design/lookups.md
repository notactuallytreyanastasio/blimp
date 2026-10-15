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

## Names: a hash per binding, the top level once, and call sites that remember

After the two indexes, a native profile (`sample`) of the Markdown probe put
`mem.eqlBytes` and `Environment.lookup` first among the interpreter's own
frames. Counting inside `lookup` on that bench: 38.2 million lookups, 5.1
frames walked per lookup on average, 68 percent found in a local scope, 8
percent at the top level, 24 percent found nowhere. The last are builtin
calls: a builtin's name has no binding, so the walk went out through every
frame (about sixteen on that stack), then hashed the name for the global map
and again for the builtin registry. Those misses were three quarters of the
frame walking.

Three changes, each measured alternately against the build before it under
the same load, three rounds each (user seconds for the bench):

```
  a binding carries hashName(name), compared before the bytes.
  Compiler-made names are the same length and share a prefix
  (best__2115, from__2111, blimp_branch_764, blimp_signal_765),
  so std.mem.eql's length check never ruled one out            4.65 -> 4.41

  lookup finds the name's top-level index once, and walks the
  global_prev chain from it for each frame's mark, instead of
  hashing the name again at every frame that reads the top     4.75 -> 4.68

  a call site keeps the builtin it resolved to (ast.CallCache,
  made by the parser).  It is used only while no top-level
  definition has been added since (Environment.globals_version)
  and no frame on the stack claims the name's bit
  (Environment.bindsLocally); otherwise the slow path runs and
  refills it                                                    4.75 -> 3.55
```

The 2,000 character paragraph went from 46 ms to 33 ms; it was 257 ms
before the registry index. On this tree, a hundred thousand `slice` calls
went from 41 ms to 34 ms.

The cache is conservative in two ways that matter. The scope masks are never
cleared and several names share a bit, so a frame that once bound anything
with the same bit sends the call down the slow path; that is a false alarm,
never a wrong answer. And `globals_version` is bumped on every top-level
define, so the first call after a `def` at the top level re-resolves. A probe
that shadows `length` with a parameter, a local, a closure's capture, an
actor's state field and a later top-level `def` prints the same on the build
before and after.

## What is still linear, and what turned out not to matter

`runScheduler` no longer walks every instance: the registry keeps the ids
with mail in a bitset and a pass visits them in id order (scheduler.md). On
a probe with 20,000 actors and 100,000 async sends that was 1585 ms to
22 ms, and the Markdown bench 1.70 s to 1.53 s, most of it from the walk that
ran every 4,000 reductions.

The call-site cache was extended to top-level closures and to identifier
references to top-level bindings, soundly (a slot holding the latest binding,
its index and the globals version, used only when no frame claims the name's
bit and the innermost frame that reads the top level sees that index), and
it measured nothing: counting on the Markdown bench, of about 20 million
lookups 18.0 million resolve to a parameter or a local in the current frame,
1.6 million to a top-level call and 0.2 million to a top-level identifier.
The extension is not in the tree. What a local read costs is the hash of
its name, computed from the string on every lookup, and the scan of the
frame; that is the next thing to remove.

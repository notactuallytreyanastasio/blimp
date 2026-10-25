# Handles: buffers and hash maps outside the heap

## What exists

Twenty-six builtins in three families: `buf_*` (a list that grows in place), `sbuf_*` (a string that grows in place) and `hmap_*` (an insertion-ordered hash map). Each keeps its data in a table in `src/handles.zig` and gives the program an Int handle to it, the way `sqlite_open` gives a database. The reference entries are in [../builtins.md](../builtins.md#buffers-and-hash-maps).

This work came out of compiling Temper to Blimp. Temper's `ListBuilder`, `StringBuilder` and `Map` became actors whose state is a Value, and a Value is immutable. It was written in the Temper fork of Blimp and brought back here; the numbers below are from that fork's probes (one process each, `BLIMP_HEAP_LIMIT=0`, time and peak RSS from `/usr/bin/time -l`) and were not re-measured on this tree, except where a section says so.

## Why it exists

The evaluator frees nothing inside a run (see `gc.zig`) and a Value cannot change. So `append(items, x)` builds a new list the size of the old one plus one, and keeps the old list for the rest of the run. Building a list of n elements one `append` at a time costs n squared / 2 element copies and the same in retained memory. `concat(text, s)` is the same for strings. A Map compiled from Temper was a list of `[key, value]` entries searched with `==`, so each `set` was a scan of every key and a copy of the list.

Same Temper programs, before and after:

```
                                    before             after
  ListBuilder.add + get, 5,000      28 ms    102 MB    22 ms     7 MB
  ListBuilder.add + get, 20,000    214 ms   1543 MB    87 ms    17 MB
  StringBuilder 10 B, 5,000         47 ms    130 MB    38 ms    11 MB
  StringBuilder 10 B, 20,000       324 ms   1941 MB   153 ms    33 MB
  MapBuilder.set String, 5,000    6554 ms    239 MB    10 ms     6 MB
  MapBuilder.set String, 20,000 140134 ms   1712 MB    41 ms    13 MB
  set + getOr String, 5,000      15470 ms    635 MB    22 ms     8 MB
  set + getOr String, 20,000    270603 ms   4781 MB    93 ms    22 MB
```

Twenty thousand `ListBuilder` adds went from 214 ms and 1543 MB to 87 ms and 17 MB; twenty thousand String-keyed map sets went from 140 seconds and 1712 MB to 41 ms and 13 MB. The sums the probes return are identical before and after.

## How it works

A list buffer is a growable array of `*const Value` that doubles as it fills, owned by libc's allocator and not by the evaluator's arena, so growth frees the old array. A string buffer is a growable byte array. A hash map is an array of slots (key, value, canonical key, live flag) in insertion order, plus a hash index from a canonical byte encoding of the key to the slot.

The canonical encoding is what makes the keys exact. Every type has a tag and every encoding is self-delimiting (`s3:abc`, `i1;`, `l2[s1:as2:bc`), so Int `1` and String `"1"` differ, and the list `["a", "bc"]` cannot be confused with `["ab", "c"]`. It follows `Value.eql`: `0.0` and `-0.0` share an encoding because `eql` says they are equal. A key that has no encoding (a map, a closure, a view node) is a TypeError, because the old linear scan could never have matched one and a silent miss hides that.

Removing a key leaves a tombstone, and the slots are swept when there are more than 32 and they outnumber the live entries two to one. Setting an existing key keeps its place.

## Snapshots

The obvious version is wrong here. `buf_items(h)` has to answer a Value, and a Value is immutable, so it is a copy. If every read copied, then reading a builder inside a loop that adds to it would be O(n) per element where `ListBuilder.get` used to be O(1) after a write. So `buf_items`, `sbuf_string`, `hmap_keys`, `hmap_values` and `hmap_entries` cache the copy until the next write. A buffer that is read more than it is written costs one copy. A loop that alternates a write and a read costs O(n) per pair, which is what it cost before and no worse. `buf_len`, `buf_get`, `sbuf_len` and `hmap_get` do not copy at all.

## What it costs, and what breaks

### Handles live outside the heap

The buffers' memory comes from libc, not from the arena the evaluator allocates in. So `BLIMP_HEAP_LIMIT` does not count it. The ceiling exists so that a runaway program stops at 2 GiB (the default) instead of taking the machine; a runaway `buf_push` loop does not stop at it.

### Nothing is freed

A handle is never closed and its number is never reused. A builder, a string buffer or a map lives until the process exits, like an actor. `fork()` copies the table with the process, which is what a forking server wants. A program that makes a buffer per request leaks one per request.

### Compaction follows the buffers

The buffers hold `*const Value` pointers into the evaluator's heap, and
`gc.compactWith` copies everything reachable into a fresh arena and frees the
old one. For a while the two could not coexist: `main.zig` refused to compact
once any buffer existed (`inUse()`), which traded a use-after-free for a leak,
and a `--serve` site or a REPL that loaded one Temper library grew without
bound from then on. Measured then, a served program whose tick built and
discarded a 2,000-element list, with and without one unused `buf_new()`:

```
without a buffer   rss after 2 s  14.5 MB   after 4 s   8.7 MB   after 6 s   3.7 MB
with one buf_new() rss after 2 s 1.25 GB    after 4 s   2.9 GB   after 6 s   3.7 GB
```

Now `gc.compactWith` asks `handles.valuePointers` for every pointer a buffer
or a map holds (the items of a list buffer, the key and value of every map
slot, and the cached snapshots), copies each with the memoizing
`copier.value`, and writes the copies back through `handles.relocate` with
the rest of the swap at the end. The copies are made before the instances,
because a value in a buffer may name an actor: with `.drop_unreachable`, an
actor that only a map holds is kept. The canonical key bytes are the map's
own and are not touched. `inUse()` stays, as information; nothing refuses on
it.

A plain `blimp file` run compacts too now, between top-level statements,
once the heap has grown by as much as what survived the last compaction and
at least 16 MB, and it drops the actors nothing can reach (`main.zig`, the
same policy as `--serve`; the REPL and the browser keep every actor because
a host may hold an id). It never did before, which is why a Temper library's
test run, one statement running every test, reached the 8 GB ceiling with
three hundred tests. With those tests as one statement each: keeping every
actor, 353 s and a 1057 MB peak; dropping the unreachable ones, 119 s and
980 MB, because every dead object was an actor copied on each compaction.

The probe (`probe_compact.blimp`: a buffer of 1,000 entries and a map, each
entry naming an actor held nowhere else, then 160 MB of garbage over six
statements, then every entry read back and the actors asked):

```
                               before        after
  bad entries after compaction      0            0
  maximum resident set size   1206 MB       206 MB
```

## What else does not work

- **WebAssembly.** The builtins are stubbed there and raise `NotSupported`, so a Temper library compiled onto them does not run in the browser.
- **Reads after a write are O(n).** `buf_items` on a buffer that was just appended to copies it. Only add, extend, set, get, length, pop and clear on lists, append and length on strings, and the map operations are O(1).
- **No splice, insert-at, sort or reverse.** Those are `buf_items`, the list builtins, `buf_replace`.
- **A single thread.** Only the evaluator touches the table; it is not locked.
- **`hmap_assign` costs the size of its source**, one copy of each live entry.

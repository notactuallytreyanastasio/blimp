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

### Compaction stops once any buffer exists (a regression for `--serve` and the REPL)

This is the part to read twice.

The buffers hold `*const Value` pointers into the evaluator's heap. `gc.compactWith` copies everything the evaluator can reach into a fresh arena and frees the old one, and it does not know about the buffers, so after a compaction every pointer in every buffer would point into freed memory. The fork's author's answer, in `main.zig`, is to refuse:

```zig
fn compactWith(self: *ValueHeap, eval: *Evaluator, actors: gc.Actors) usize {
    // Buffers in handles.zig hold pointers into this heap; moving it would strand them.
    if (@import("handles.zig").inUse()) return 0;
```

`inUse()` is true once any buffer, of any kind, has been created, and it never becomes false. After that:

- **`blimp --serve` never frees its heap.** It compacts when the heap has grown by more than the larger of its live size and 16 MB since the last compaction. Now the attempt returns 0 at once, the loop records it as a compaction anyway (`:stats` reports compactions that did not happen), and the heap grows without bound until it reaches the 2 GiB ceiling and the site stops.
- **The REPL never frees its heap** between prompts.
- A plain `blimp file` run is unaffected: it never compacted.
- The first compaction after boot (which also drops actors nothing can reach) is skipped too, if a buffer exists by then.

Measured here, on this tree: a served program whose tick builds and discards a 2,000-element list, with and without one `buf_new()` at the top level that nothing ever uses:

```
without a buffer   rss after 2 s  14.5 MB   after 4 s   8.7 MB   after 6 s   3.7 MB
with one buf_new() rss after 2 s 1.25 GB    after 4 s   2.9 GB   after 6 s   3.7 GB
```

A server that stays flat today will not stay flat once any library it loads creates a builder at start-up. Nothing existing calls these builtins, so nothing changes on its own; but the first library that does turns a `--serve` site into one that leaks. Fix the following before depending on them in a long-lived server.

### The fix this needs

Make the collector aware of the buffers, so `inUse()` need not stop it:

1. `gc.compactWith` already has a memoizing `copier.value(v)` that returns the new address of an old value. Add a pass, after the evaluator's own roots are copied, that walks every buffer and replaces each `*const Value` it holds with `copier.value(item)`: the items of each list buffer, and the key and value of each live hash-map slot.
2. Build the replacement arrays first and swap them in with the rest of the swap at the end of `compactWith`, so a failed copy leaves the buffers consistent, as the file already promises for the evaluator.
3. Clear the cached snapshots (`snap`, `keys_snap`, `values_snap`, `entries_snap`); they are old-heap pointers too, and the next read will rebuild them.
4. The buffers are roots: a value reachable only through a buffer is live. For `.drop_unreachable`, actor references found in buffers must be passed to `copier.see`, or an actor that only a map holds will be dropped.

The canonical key bytes need no change: they are copies, not pointers. Then `inUse()` and the early return in `main.zig` go.

Until then the early return is the safe choice: it trades a leak for a use-after-free.

## What else does not work

- **WebAssembly.** The builtins are stubbed there and raise `NotSupported`, so a Temper library compiled onto them does not run in the browser.
- **Reads after a write are O(n).** `buf_items` on a buffer that was just appended to copies it. Only add, extend, set, get, length, pop and clear on lists, append and length on strings, and the map operations are O(1).
- **No splice, insert-at, sort or reverse.** Those are `buf_items`, the list builtins, `buf_replace`.
- **A single thread.** Only the evaluator touches the table; it is not locked.
- **`hmap_assign` costs the size of its source**, one copy of each live entry.

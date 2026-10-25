# names are interned by the parser, and a name compare is a pointer compare; Markdown 2 percent, core 4 to 5 percent

The byte compare after a hash match was pure cost. On the Markdown bench every one of the 31.7 million lookups that reached a name compare and succeeded did so on a name the parser had produced, and the pointers were equal in all but 350,000 of them; those 350,000 were the actor state fields, which come from the registry's templates. Interned, the byte compare is reached zero times on Markdown and zero on core (temporary counter, not in the patch). `mem.eqlBytes` falls from about 12 percent of the run thread to about 6, and what remains is the `globals` hash map and handler dispatch, which compare strings that are not bindings.

    bench      base6 (s)             intern (s)      (three alternating rounds, user seconds)
    markdown   1.16 1.14 1.15         1.14 1.13 1.10
    core       1.67 1.67 1.65         1.62 1.60 1.58
    webtest    1.34 1.34 1.32         1.35 1.34 1.33

Markdown is 2 percent faster, core 4 percent, webtest unchanged (actor-bound, and its lookups are the state tier). Smaller than the profile share suggested: eqlBytes at 12 percent included the call overhead of a short compare that the hash test now prunes cheaply, and the scan loops still run.

What changed

`name_key.intern` keeps one copy of each name in a process-wide table: an arena over `page_allocator`, a string hash map, a spin lock. It is process-wide because `blimp_eval` and the REPL parse with their own allocators, and several interpreter threads may parse at once; a table owned by one parser's allocator would hand out pointers that die with it. Nothing in it is freed, and gc compaction copies Values and never touches these bytes. The cost is one lock acquisition per lowercase identifier token, at parse time only.

`Parser.advance` and `Parser.init` replace an `identifier` token's lexeme with the interned copy. Every name the parser derives from a token (identifier nodes, call names, parameters, assign/given/for names, handler and def names) is therefore interned without touching the 48 sites that read lexemes. `Environment.internName` interns the state-field names in `stateLend`, once per lend, which is where the 350,000 fallbacks came from.

`name_key.sameName(a, a_hash, b, b_hash)` is the one compare: equal pointer and length is equality; otherwise the hashes, then the bytes. Used in `lookupHinted` (hint slot, own-region scan, capture tier, below-own_base scan), `defineIn` and `lendCaptured`'s shadow check. The pointer test goes first and the hash second, so the hash is still needed: a pointer mismatch is the common case in a scan (190 million mismatches on Markdown, 60 million on core) and the 32-bit compare rules those out without a load of either string. Dropping the hash would turn each into a length compare plus a byte compare.

Why `upper_identifier` is not interned: the obvious version interned both kinds, and `parse dot-notation actor name` aborted with integer overflow. The parser builds a dotted actor name and a list, tuple or map type annotation by slicing the source between two tokens' pointers, and an interned lexeme is not in the source. Upper-case names are actor and type names, not bindings, so nothing on the hot path wanted them.

Where lookups end (Markdown, 31.7 million, then core 61.1 million)

    resolved by the hint slot             18.9M    38.2M
    hint stale, then own-region scan       1.6M     1.3M
    own-region scan, no hint or a frame other than the innermost  5.0M   12.4M
    lent state (actor fields)              0.36M    0.17M
    closure captures                       ~0       ~0
    top-level, through a frame's globals_mark   3.0M   6.2M
    below own_base, left_mark              0        0
    final top-level fallback               2K       150
    missed (builtins)                      2.8M     2.9M
    scopes visited per lookup              3.0      2.0

The hint covers 60 percent of Markdown and core lookups, and the frame walk is the remaining cost: three scopes per lookup on Markdown, each checked by the 64-bit mask, with 6 name mismatches per lookup inside the scans on Markdown (1 on core). The 5.0M and 12.4M are reads with no hint slot (a null hint, or a scope that is not the innermost); the 2.8M builtin misses walk every frame and then hit the registry. Those are the next places to look, not interning.

What does not work: webtest's counters were not collected (that program leaves through a path that skips the dump), so the state-tier numbers above come from the two benches only. A runtime-built name still takes the byte compare, correctly; the new test checks it.

Gates: webtest 43/0, html 646/0, core 51/0, works 160/0, reading 190/0 (cases/failures, identical to base6); Markdown bench output identical apart from milliseconds; `zig build test` and `zig build wasm` pass. Two tests added in `name_key.zig`: interning gives one pointer per name and `sameName` falls back to bytes for a runtime-built one; two parsed occurrences of a name share a pointer. `pages_show` not run.

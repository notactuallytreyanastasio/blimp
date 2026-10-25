# The evaluator, one day of measured changes

Thirteen commits on 2026-10-15, each with its own note in this directory,
took the three benchmarks used all day from this to this (user seconds, the
same machine, alternating runs):

```
                       09:00    18:00
  markdown bench        1.97     0.77    (the html library rendering Markdown)
  core bench            2.82     1.15    (text segmenting and diffing)
  webtest suite         1.55     1.24    (43 router tests; 60% of it is pbkdf2)
  pages_show suite     119 s     22 s    (293 tests of a Temper web app)
```

Every change was measured against the tree before it with `ab2.sh`-style
alternating runs, three rounds, and had to keep `zig build test`, `zig build
wasm`, and five Temper-compiled test suites (1,090 cases) at zero failures.
The Marginalia end-to-end suite (1,806 assertions) and be-blimp's functional
tests were run after each wave.

## What paid, in order of landing

| note | change | markdown | core |
|---|---|---|---|
| literals.md | literals built once by the parser | 2% | 1% |
| scheduler.md | actors with mail kept in a bitset; reductions ticked at calls | 10% | 6% |
| sends.md | handler found by hash, state lent to the scope | 0 (micro: 34%) | 0 |
| eval-by-pointer.md | nodes and switch payloads by pointer | 16% | 19% |
| name-keys.md | names hashed once, by the parser; slot hints | 11% | 12% |
| call-sites.md | a top-level call remembers its target | 1.5% | 3% |
| interning.md | names interned; a name compare is a pointer compare | 2% | 4.5% |
| cold-arms.md | eval's cold arms out of line (frame 2000 to 400 bytes) | 1% | 1.5% |
| binary-op-frame.md | one result slot in evalBinaryOp (1248 to 176 bytes) | 1% | 2% |
| builtin-misses.md | a bloom false alarm no longer walks the stack | 6% | 5% |
| define-path.md | parameters appended without a scan; assignment hints | 4.5% | 1.5% |
| lookup-hints.md | hints cross block scopes; bindsLocally is one load | 17% | 13% |
| case-fast-path.md | `true ->` and `_ ->` arms skip matchPattern and the scope | 0 | 2.5% |

Percentages are each against the tree just before it, so they compound.

## What did not pay, and why that is worth knowing

- Operator fast paths: 99% of binary operations are int/int or atom/atom and
  were already served from the interned table (binops, not in the tree).
- Skipping the scope push for literal `case` arms measured zero on the
  morning's tree and 2.5% on the evening's; the push was never the cost.
- Atom and message-name interning: most remaining byte compares are the
  Markdown bench's own `index_of`, which is real work.
- A second bloom mask: every one of the 2.3M "maybe bound" builtin calls per
  Markdown run is unbound, and halving the compares measured 1 to 2%.
- Parameter type annotations resolved to an enum: 1% on core only.
- The stack protector off: 3 to 5% on the eval-bound benches. Not shipped;
  it gives up stack-overrun detection in a binary that runs programs from
  the web, and that is a decision for the owner, not for a benchmark.

## Where the time is now

On the Markdown bench, as shares of the run thread: `Evaluator.eval` 27%
(the dispatch switch, with the inlined local-lookup hit), `unbound` 7%,
byte compares 7% (mostly `index_of`), `evalSituationTail` 7%, the rest of
lookup 6%, defines 4%. Nothing is above 10% except the tree walk itself.
The next step change is a different execution model, a resolver that gives
lexically bound locals slots and a closure-compiled or bytecode body, and
that is a project, not a wave of patches: a Blimp closure sees its caller's
locals, so non-local names stay dynamic, and the hints and caches here are
what makes that dynamic rule cheap today.

## How the work was done

Six to three agents per wave, each in a git-free copy of `chunks/lang`,
each handed the same brief (the profile, the semantics that are not
negotiable, the gates, the alternating-run rule, "a change that passes the
gates but makes nothing faster is a finding, not a win"). Each returned a
`diff -ruN` patch and a note; the coordinator applied one patch at a time,
re-measured against the tree before it, ran the gates, and committed the
note as the message. Two patches were rebased by their authors when the
tree moved under them. The counters in the notes come from temporary
instrumentation that is not in the tree.

# The Nested Actor Bug That Was a Parse Error

*November 16, 2026*

The design sketch at the bottom of the repo's CLAUDE.md puts actors inside actors. `Shop` holds `Checkout` and `Inventory`, and Checkout's `:charge` handler passes Shop's `region` straight into `calculate_tax`. Under that sketch the same file is written a second way, flat, as `actor Shop.Checkout do ... end`, and only the flat spelling runs.

We went in to find out what the interpreter did with the nested one. The starting point was a line in `evalActorDef`, the function in `eval.zig` that turns an actor definition into a template:

```zig
else => {
    // Ignore other body nodes (e.g. nested actors, not yet supported)
},
```

Read at face value, that comment says the interpreter accepts an inner actor and drops it without a word. You would write a Checkout, see no complaint, and find out later when `spawn Shop.Checkout` reported a missing template.

The comment was wrong about what reaches it. We ran this file:

```blimp
actor Shop do
  state region: Atom :: :us

  actor Checkout do
    state total: Int :: 0

    on :add(n: Int) do
      become total: total + n
      reply total + n
    end
  end
end

c = spawn Shop.Checkout
c <- :add(3)
```

on the parent branch, before this chapter:

```
$ blimp nested.blimp
Parse error: error.UnexpectedToken at line 4, col 3
```

The parser stopped it. `parseActorBodyTopLevel` lets four things into an actor body (`state`, `on`, `test`, `property`) and returns `error.UnexpectedToken` for anything else. The evaluator never saw the inner actor. The `else` branch only ever received `test_def` and `property_def` nodes, and skipping those is correct, because `blimp test` pulls them out of the actor body itself.

The defect was the error message. Line 4, column 3 is the right place, and `UnexpectedToken` tells you nothing about what was unexpected. The compiler gave even less, because `blimp-compile` retries a file that fails to parse as a single expression, and it reported the retry's failure:

```
$ blimp-compile nested.blimp -o x
Parse error: error.UnexpectedToken at line 1, col 1
```

## What it says now

The parser carries a `diagnostic` now: a message plus a line and column, set at the point where it gives up on something it can explain. The file runner, the REPL, `blimp test` and the wasm entry point all check for one first. Same file, this branch:

```
$ blimp nested.blimp
Parse error at line 4, col 3: nested actor `Checkout` inside `Shop` at line 4 is not supported; define it at top level as `actor Shop.Checkout do ... end`
4|   actor Checkout do
```

`blimp-compile` prints the same message and exits 1 before it tries the expression retry. The plain REPL used to answer with "I couldn't understand this expression." and then paste back all twelve lines you had typed. It now shows the message and the one line, with a caret.

The suggestion builds the dotted name from both sides, so dotted names nest correctly:

```
nested actor `Checkout.Tax` inside `App.Shop` at line 2 is not supported; define it at top level as `actor App.Shop.Checkout.Tax do ... end`
```

The parser explains two neighbouring cases as well. A `def` in an actor body gets:

```
Parse error at line 3, col 3: `def` at line 3 is not allowed in the body of actor `Shop`; an actor body holds only `state`, `on`, `test` and `property`
```

An actor inside a handler gets the message below, and tests and case branches share that body parser, so they get it too:

```
Parse error at line 3, col 5: actor `Checkout` at line 3 cannot be defined inside a handler, test or case branch; define it at top level
```

## The drop was real, one layer down

The comment did describe what `evalActorDef` would do with an inner actor, if the parser ever produced one. To see it, we built the AST by hand, put an `actor_def` for Checkout inside Shop's body, and handed it to the evaluator. On the parent branch the test came back with:

```
expected error.NotSupported, found .{ .atom = { 83, 104, 111, 112 } }
```

Those bytes spell `Shop`. The evaluator registered Shop, and Checkout never existed. The type checker had it backwards: it skipped the inner actor when registering actors, then type-checked its handlers anyway as if it were a top-level actor the checker had never registered. Both now refuse the node with the same message as the parser. `blimp file.blimp` cannot reach that code today. The guard is for a later, looser parser. The tree-sitter grammar in `chunks/lang/tree-sitter-blimp` lets any statement into an actor body, though it reads `actor Checkout do` there as three bare words and builds no inner actor from it.

## Why it refuses

The tempting fix is to accept the nested form as shorthand for the flat one. Picking the name would be easy, since the flat form works:

```blimp
actor Shop do
  state region: Atom :: :us
end

actor Shop.Checkout do
  state total: Int :: 0

  on :add(n: Int) do
    become total: total + n
    reply total + n
  end
end

c = spawn Shop.Checkout
print(c <- :add(3))
print(c <- :add(4))
```

```
3
7
```

The hard part is `region`. The CLAUDE.md sketch reads Shop's state from inside Checkout. `docs/lang_design/compilation.md` says nested actors are "fully independent" and talk to their parent by message. Those two documents disagree, and the flat form today behaves the way the second one describes. Give `Shop.Checkout` a handler that says `reply region` and you get:

```
-- UNDEFINED VARIABLE ────────────────────────────

  I can't find a variable called `region`.
```

A parser that rewrote nested actors into flat ones would pick the compilation.md answer for every program, and nobody has made that choice yet. The same goes for the other open parts: whether actors in the same tree can reach each other by short name (`core-language-feel.md` has Checkout send `TaxCalculator <- :calculate(...)` to its own child, and says siblings address each other by name), and whether spawning Shop spawns and supervises its children. Until those questions have answers, the parser says "not supported" and points at the spelling that works.

## Still loose

An actor defined inside a `def`, `fn` or `for` body still parses, because those bodies use the top-level parser. It registers when the function runs:

```blimp
def make() do
  actor Checkout do
    on :ping do
      reply :pong
    end
  end
  :made
end

print(make())
c = spawn Checkout
print(c <- :ping)
```

```
:made
:pong
```

`spawn Checkout` finds the template, but `Checkout <- :ping` outside the function is `UNDEFINED VARIABLE`, because the function bound the name in its own call scope. Whether an actor may be defined there is undecided, so this chapter leaves it alone.

The checker also skips `test` and `property` bodies. At top level, `c <- :add("x")` gets `argument 1 to :add expected Int, got String`, while the same line inside a test passes under `blimp test`.

`make check` reports all suites passed on this branch.

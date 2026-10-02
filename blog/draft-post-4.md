# You Can Try It Now

_March 24, 2026_

## Since Last Time

Last post the actors were alive.
We had a tree-walking interpreter, an LLVM compiler that produced native binaries, a REPL with a state sidebar, and a diff viewer that watched the work happen.
That was two days ago.

Since then we got closures, pattern matching, loops, an async scheduler, a tagged value runtime with Perceus reference counting, compiled all of it to native code via LLVM, put the entire interpreter in a browser as a 100KB WASM module, built a canvas that paints your actors as generative art, and embedded the whole thing in this blog.

There's a REPL at the bottom of this page.
Go play with it.

## Closures

We have `fn` expressions now.
They capture the enclosing scope and they're first-class values, you can store them in variables, pass them as arguments, return them from other functions.

```
double = fn(x) do x * 2 end
double(5)    # => 10

multiplier = 3
scale = fn(x) do x * multiplier end
scale(10)    # => 30
```

This unlocked `map`, `filter`, `reduce`, and `each` as builtins that take closures:

```
nums = [1, 2, 3, 4, 5]
map(nums, fn(x) do x * 10 end)        # => [10, 20, 30, 40, 50]
filter(nums, fn(x) do x > 2 end)      # => [3, 4, 5]
reduce(nums, 0, fn(acc, x) do acc + x end)  # => 15
```

## The Dots

We added two operators that I think are going to feel really natural once you get used to them.

Three dots is map:

```
double = fn(x) do x * 2 end
...[1, 2, 3], double    # => [2, 4, 6]
```

Two dots is each (side effects, returns `:ok`):

```
..[1, 2, 3], fn(x) do x end    # => :ok
```

And `for`/`in` is there too if you want the verbose version:

```
for x in [10, 20, 30] do
  x + 1
end    # => [11, 21, 31]
```

Three ways to say the same thing.
Use whichever reads best for what you're doing.

## Pattern Matching

`situation` and `case` branches now do real structural pattern matching.
Variables bind, maps destructure, lists split head and tail.

```
situation %{name: "bob", age: 30} do
  %{name: n, age: a} -> n
end    # => "bob"

situation [1, 2, 3] do
  [h | t] -> h
end    # => 1

situation {10, 20} do
  {a, b} -> a + b
end    # => 30
```

Atoms and literals match by value, identifiers bind, and holes always match.
A Hole in a situation branch is the wildcard, the catch-all, and also the place where the agent shows up:

```
on :process(event) do
  situation event do
    :known -> handle(event)
    _ # Hole: figure out what to do with unknown events
  end
end
```

That `_` with the comment is a Hole.
The agent reads it, the program keeps running (Holes act as identity until filled), and you get suggestions without leaving your code.
Patterns compose recursively so you can nest destructuring inside situation branches.

## Self

Inside a handler, `self` resolves to the current actor's ref.
So actors can send messages to themselves:

```
actor Doubler do
  state val: Int :: 0

  on :set(n) do
    become val: n
    reply n
  end

  on :double do
    self <- :set(val * 2)
    reply val
  end
end

d = spawn Doubler
d <- :set(5)
d <- :double
d <- :get_val    # val is now 10
```

The async scheduler handles self-sends by processing them inline to avoid deadlock.

## The Async Scheduler

Speaking of which.
`blimp_send` used to process messages inline, which meant no fairness and no real concurrency.
Now it enqueues the message in the target's mailbox and pumps a round-robin scheduler until the reply comes back.

What that means: when actor A sends to actor B, and B's handler sends to actor C, all three get scheduled fairly.
The scheduler does one message per actor per pass, round-robin.
If two actors deadlock (A waits on B, B waits on A), it detects it and aborts with a clear error instead of hanging.

This is single-threaded for now.
The WASM target will always be single-threaded (that's how browsers work).
The native target will get real threads later, but the scheduler architecture is ready for it.

## Tagged Values and Perceus RC

Under the hood, every value in compiled code is now a `BlimpVal*`, a heap-allocated tagged union.
Integers, floats, strings, atoms, booleans, lists, maps, closures, actor refs, all the same pointer type.

And every `BlimpVal` has a reference count.
When you bind a value to a variable, the count goes up.
When a scope exits, the count goes down.
When it hits zero, the value and all its children get freed recursively.
Lists dec their elements, maps dec their values, closures dec their captured environment.

The Perceus insight: if the refcount is 1 (you're the only owner), you can mutate in place instead of allocating.
`become count: count + 1` doesn't need to allocate a new integer if the old one has refcount 1, it just overwrites it.
We have `blimp_rc_reuse` in the runtime for this but we're not using it aggressively in codegen yet.
That's an optimization pass for later.

## Compiled to Native, All of It

The LLVM compiler now handles lists, closures, for loops, and spread operators alongside the existing actor compilation.
A single program can spawn actors, define closures, map over lists, and loop, all compiled to a native binary.

```
actor Counter do
  state count: Int :: 0
  on :increment do
    become count: count + 1
    reply count + 1
  end
end

c = spawn Counter
c <- :increment
c <- :increment
c <- :increment

nums = [10, 20, 30]
double = fn(x) do x * 2 end
result = ...nums, double

for x in result do
  x + 1
end
```

```
$ blimp-compile program.blimp --run
[21, 41, 61]
```

## Blimp in the Browser

The interpreter compiles to a 100KB WASM module via Zig's native `wasm32-freestanding` target.
No Emscripten, no WASI, no polyfills.
Just the lexer, parser, evaluator, and actor runtime, compiled to WASM.

A tiny JS loader (`blimp.js`, 80 lines) handles loading the module, passing strings through linear memory, and wiring up print callbacks.
The API is three functions: `init`, `eval`, `getState`.

We embedded it in this blog.
There's a REPL at the bottom of every page.
The playground at `/blog/playground.html` has the full setup: REPL, state panel, canvas, and a cheat sheet with copy-paste examples of every feature.

## The Canvas

This is the part where it gets weird and I love it.

Every actor on the canvas is a hexagon.
The hexagon's fill pattern is generated from a SHA-256 hash of the actor's state.
Same type and same state produce the same visual.
When state changes via `become`, the hash changes and the pattern morphs.
You can literally see state transitions as color shifts.

Four pattern types: scattered dots, concentric rings, diagonal stripes, soft blobs.
The hash determines which type and what parameters.
Two counters both at `count: 0` look identical.
Increment one and they diverge visually.

When you send a message, a dashed ray animates from the green REPL blob to the target hexagon.
The ray has a particle head that travels the path and an impact ring that pulses on arrival.
The message name floats along the path.

Raw values (variables that aren't actors) get squares instead of hexagons.
The layout adapts to any number of shapes, scaling down and using hex-grid packing when there are many.

It's generative art that IS the program.
The program paints itself.

## What's Next

We still don't have:

- **`def` for named functions** inside actors, just anonymous `fn` for now
- **String operations** as builtins (concat, split, contains)
- **Supervision** (Phase 5) so bubbles actually propagate and restart actors
- **Send after** for timers and heartbeats
- **A UI DSL** that wraps something like Tailwind so you can build interfaces from Blimp without writing HTML

That last one is the one I keep thinking about.
If actors are the runtime and the browser is the target, then the language should be able to describe interfaces.
Not with JSX, not with templates.
With actors.
A button is an actor.
A form is an actor.
The page is a supervision tree.
Clicks are messages.

We'll see.
For now, go try the REPL.

---

_Remaining: screenshots of playground, canvas with multiple actors, cheat sheet overlay_

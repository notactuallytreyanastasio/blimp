# Chapter 7: The Clock

The bike share has a vault, an inventory, and a `Rider` who can pick up a bike and return it.
What's still missing is *time*.
A real bike share charges by the minute, fines for stale rentals, and pages a mechanic if a bike has been out for too long.
None of that exists yet, because the system has no way to know how long anything has been happening.

This chapter adds a `Clock` actor.
It's the simplest actor in the tutorial and it does the most: every other piece of state-with-duration in the rest of the system will read its value to figure out what time it is.
The `Rider` from Chapter 6 grows a `pickup_at` field that captures the clock's current value at pickup time, and an `:elapsed` handler that reports how long the rider has had the bike.

By the end you'll have seven tests passing and a working notion of "now" that the rest of the tutorial can build on.

## Why we're not using wall-clock time

Blimp has a `now()` builtin that reads the system clock, the same way most languages do.
We're not using it.
Two reasons.

The first is that the tutorial runs in your browser via WASM, and `now()` in the WASM build returns 0.
That's a known limitation, not a deep design statement, but it means anything that depends on real time isn't going to work in the editor on the right.
A clock that always reports zero is not a useful clock.

The second is that even if `now()` worked, you wouldn't want the tests to depend on real time.
A test that says "wait two seconds, then assert" takes two seconds and adds non-determinism (sometimes it's 1.99, sometimes it's 2.01, and on a slow CI box it's 2.4).
A test that says "advance the clock by two ticks, then assert" is instant and exact.

So the `Clock` in this chapter is a *logical* clock.
It doesn't move on its own; it advances when somebody sends it a `:tick` message.
In a real running system you'd have something at the top level (a poll loop, an OS timer, an external event source) sending `:tick` to the clock at whatever cadence you want, and every other actor that needs to know "what time is it" would query the clock as a normal actor.
For the tutorial, the tests are the things sending `:tick`, and that's enough.

This split (logical clock for the model, separate ticker for the wall-clock part) is also how serious actor systems usually do it.
Erlang/OTP has the same pattern (`erlang:system_time` for the wall clock, `gen_server` casts and timers for the logical part), and most distributed systems test the model with a mock clock so they can fast-forward through a day in microseconds.

## The shape of a `Clock`

```blimp
actor Clock do
  state tick: Int :: 0
end
```

One field, an `Int`, defaulting to `0`.
That's the whole state.
The handlers will be a reader (`:now`) and an advancer (`:tick`).

## What a session looks like

```blimp
c = spawn Clock
c <- :now      # => 0
c <- :tick     # => 1
c <- :tick     # => 2
c <- :now      # => 2
```

`:now` is a pure read.
`:tick` advances the counter and returns the new value, so callers can chain "advance and observe" in one message.

This is the same `Counter` shape from Chapter 3's parallel-example sidebar, with two handlers instead of one and slightly different names.

Open `exercises/ch07_clock/01_clock.blimp` in the editor on the right.
You'll see the `Bike` from earlier chapters, a `Clock` with one `:TODO` handler (`:tick`), and an updated `BikeShare.Rider` with two `:TODO` handlers (the guarded `:pickup` and the guarded `:elapsed`).
Four tests pass already; the other three fail until you fill in the handlers.

## Step 1: fill in `Clock`'s `:tick`

The simplest of the three.
The body is exactly the "increment a counter, reply the new value" pattern from earlier chapters: `become` to commit the new value, `reply` with the new value (computed as `tick + 1`, since `tick` inside the handler still holds the pre-`become` reading).

A small parallel:

```blimp
on :inc do
  become n: n + 1
  reply n + 1
end
```

`Clock`'s `:tick` is the same shape with the field name changed.

**Your task:** fill in `on :tick`.
"tick advances and returns the new value" should go green.

## Step 2: capture `pickup_at` in `:pickup`

The `:pickup` handler needs one more move on the success branch: capture the clock's current value into `pickup_at` so we can compute elapsed time later.

The signature has grown.
Where Chapter 6 had `on :pickup(b: Bike) when bike == nil`, this version threads the clock through as a second argument:

```blimp
on :pickup(b: Bike, clock: Clock) when bike == nil do
  ...
end
```

This is what passing dependencies as message arguments looks like.
The rider doesn't store a reference to the clock; the caller hands the clock in at the moment of pickup, the handler reads `clock <- :now`, the caller can pass a different clock next time.
That's a deliberate design choice: it keeps the rider testable (any clock works, including a freshly-spawned one in each test) and avoids hard-wiring a singleton.

The new piece in the body is:

```blimp
become bike: b, pickup_at: clock <- :now
```

`become` accepts multiple field updates separated by commas.
Each value on the right side is just an expression, so `clock <- :now` (which is a send that evaluates to the clock's reply) is a perfectly valid right-hand side.

The rest of the handler is unchanged from Chapter 6: send `:rent` to the bike, case on the reply, only commit on `:ok`.

**Your task:** fill in `on :pickup(b: Bike, clock: Clock) when bike == nil`.
The added test "pickup after some ticks captures the right starting time" leans on you reading the clock at the right moment (before any post-pickup ticks).

## Step 3: fill in `:elapsed`

The guarded `:elapsed` is the simplest computation in the chapter.
The rider has `pickup_at` from Step 2 and the caller hands in a clock; the answer is current time minus pickup time.

```blimp
on :elapsed(clock: Clock) when bike != nil do
  reply (clock <- :now) - pickup_at
end
```

The parens around `clock <- :now` matter to the parser since `<-` is an operator.
The expression evaluates to the clock's current tick value; subtract `pickup_at` and reply.

The fallback (already wired) returns `0` when the rider is idle, which is the natural answer for "how long have you had your bike" when you don't have a bike.

**Your task:** fill in `on :elapsed(clock: Clock) when bike != nil`.
"elapsed right after pickup is 0", "elapsed after pickup and three ticks is 3", "pickup after some ticks captures the right starting time", and "return clears pickup_at" all turn on this handler reading the clock correctly.

## Why the clock is its own actor

The `Clock`'s state could have lived inside `BikeShare`, or inside the rider, or as a top-level integer that the tests read directly.
None of those would have worked the same way once the system grows.

State inside `BikeShare` would mean every actor that needs the time has to know about the bike share to ask for it.
A standalone `Bike` instance with no parent couldn't tell what time it is.
Pulling the clock out makes time a *service* that any actor can ask, regardless of where it sits in the supervision tree.

State inside the rider would mean each rider has its own personal time, which makes elapsed-time comparisons across riders meaningless.
Two riders renting at "tick 5" should mean the same thing for both of them.
A shared clock is the only way to get that.

A top-level integer would lose the mailbox guarantee.
If two pieces of code both want to advance the clock at the same time, they'd race; if one wants to read the time while another writes it, the read is non-deterministic.
Wrapping the integer in an actor gets you ordering for free, the same way every other piece of state in the tutorial gets it.

So the clock is an actor, even though it has only one integer field, because it gets the same isolation benefits everything else does.

## What you built

A `Clock` actor with two handlers and one field.
A `BikeShare.Rider` extended to capture pickup time and report elapsed ticks.
Seven tests passing.

What's worth holding onto:

1. **Logical clocks beat wall clocks for testing.** Make time something callers advance, not something that ticks on its own, and your tests get to skip days in microseconds without flake.
2. **Pass dependencies as message arguments.** The rider doesn't hoard a reference to the clock; the caller hands it in. Different callers can hand in different clocks, including test-only ones.
3. **Multi-field `become`.** `become bike: b, pickup_at: clock <- :now` updates two fields atomically. The right side of each `field: value` pair is an arbitrary expression, including a send.

## What's next

The clock makes "elapsed time" a thing the system can compute, but nothing yet *acts* on it.
Chapter 8 introduces stale rentals: a sweep that looks at every rider, checks how long they've had their bike, and fines the ones who've gone over.
You'll write a fan-out across riders (the same shape as Chapter 4's `:total_bikes`), gated by a per-rider elapsed-time check, with the clock from this chapter as the time source.

# Chapter 5: The supervision tree

Four chapters in, you have a `BikeShare` that holds a list of `Station`s and asks them all the same question at once.
The system has actors, the actors have state, and the state survives a session worth of messages.
What none of it has yet is a story for what happens when something inside it goes wrong.

This chapter is about that.
The `bubble` keyword for raising a failure from inside a handler.
The `orelse` operator for catching a bubble at the call site.
The dotted-name convention from chapter 4 turns out to be load-bearing here, because it's the thing the runtime uses to decide which actors should restart together when one of them goes down.

By the end you'll have five tests passing, an actor that bubbles a failure, a parent actor that catches it and translates it to a tagged tuple, and a "panic" handler that takes a whole subsystem of sibling actors down with it.

## What's wrong is wrong: bubble vs. tagged tuples

Chapter 2 already gave you one way to report failure: a tagged tuple.

```blimp
on :rent do
  reply {:error, :unavailable}
end
```

That's the right shape for *expected* failure.
A user tried to rent a bike that's already out, which is a perfectly normal thing to happen, and the caller wants to branch on the result and tell the user the bike is unavailable.
The actor's state is fine, the actor itself is fine, the request just doesn't apply.

Some failures aren't like that.

If a `Vault` actor finds itself asked to withdraw more cents than it has, the answer isn't "user error, please retry."
The vault was supposed to never let that question arrive in the first place.
Some upstream component already failed.
The vault's state is suspect because the assumption it operates under (every withdraw is sized so it succeeds) just got proven wrong.

For that, Blimp has `bubble`.

```blimp
bubble :overdraw
```

Read it as "raise this atom up the call chain."
A bubble propagates back through every send that's currently waiting for a reply, the same way an exception propagates through a stack of function calls in any other language.
The thing that makes it different from a tagged tuple is what happens to the actor afterward.
We'll get to that in a moment.

## Catching a bubble: `orelse`

Most of the time you want a bubble to propagate.
That's the whole point of bubbling: the failure didn't happen at the top of the call chain, but the top of the call chain is where it should be reported.

Sometimes you want to *catch* a bubble at a specific call site, the way you'd catch an exception at one specific `try` in a Java method.
Blimp's `orelse` does that.

```blimp
result = vault <- :withdraw(50) orelse :rejected
```

If the send returns normally, `result` is whatever the vault replied.
If the send bubbles, `orelse` catches the bubble, evaluates the right side, and `result` is `:rejected`.

The right side of `orelse` is just an expression.
It can be a literal, a function call, another send, anything that returns a value.
The convention is to use it for graceful degradation: if the call fails, fall back to a default that lets the rest of the handler keep going.

`try / catch` also exists for catching bubbles around bigger blocks of code.
We won't use it in this chapter, since `orelse` is enough for the patterns here, but you'll see it in later chapters when a handler needs to catch bubbles from several different sends.

## Dotted names form a supervision tree

Chapter 4 named one of its actors `BikeShare` and another `Station` and didn't make a fuss about the difference.
This chapter starts using a naming convention from chapter 0's roadmap that does make a difference.

```blimp
actor BikeShare.Vault do
  state cents: Int :: 0
  ...
end

actor BikeShare.Inventory do
  state count: Int :: 0
  ...
end
```

`BikeShare.Vault` and `BikeShare.Inventory` are two distinct actor types, with a shared *supervisor prefix* of `BikeShare`.
The dot is part of the name and Blimp parses it as one identifier.
You spawn them and message them the same way as any other actor.

What's different is what happens when one of them bubbles.
The runtime sees the dot, splits the name on the last one, and treats the result (`BikeShare`) as a supervision boundary.
"Sibling" means another actor whose name starts with that same prefix.
The supervision behavior we'll see in a minute uses this prefix to decide what to restart.

A non-dotted actor like `Plain` has no supervisor, no siblings, and no automatic restart behavior at all.
Bubbles from a non-dotted actor propagate, but its state stays put.
The dot is the opt-in.

This is a much lighter version of supervision than Erlang's, where you write supervisor processes by hand and link children to them explicitly.
In Blimp, naming is the whole API.
That's a small surface area, and it's deliberate; the cost is that you can't (yet) say "this child should restart, but with a different policy from its siblings."

## What "restart" means

When an actor restarts, its state fields are reset to the defaults you wrote in the `actor X do` declaration.
Anything you'd updated through `become` is gone.
Any messages still in flight to that actor are lost.

The actor is not destroyed and the variable holding the reference is still valid.
The next message that arrives at that variable will land in a fresh actor with the original defaults.

```blimp
v = spawn BikeShare.Vault
v <- :deposit(50)             # cents: 50
v <- :balance                  # => 50
v <- :withdraw(200) orelse :ok # bubbles :overdraw
v <- :balance                  # => 0  (the vault was reset)
```

This is what makes bubble different from a tagged tuple.
A `{:error, :unavailable}` reply preserves the actor.
A bubble erases the actor's working state and gives you a clean slate.
That's the right thing to do *if* the failure means the working state was unreliable.
It's the wrong thing if the failure was just a user error and you'd like to keep the data.
Use the right one for the situation.

## Two restart strategies

Every handler has a supervision strategy, defaulting to `SelfBubble`.

```blimp
on :crash do
  bubble :died
end
```

The default behavior is "if I bubble, restart only me."
That's what the example above with the `BikeShare.Vault` showed.

The other strategy is `CascadeBubble`, declared with the `bubbles(...)` annotation after the message pattern:

```blimp
on :corruption bubbles(CascadeBubble) do
  bubble :corrupted
end
```

When a `CascadeBubble` handler bubbles, the runtime restarts not just this actor, but every actor whose type name shares the same supervisor prefix.
A `:corruption` from a `BikeShare.Vault` doesn't just reset the vault, it also resets the `BikeShare.Inventory` next to it.
Anything not under the `BikeShare.` prefix is untouched.
A `Bank.Ledger` running in the same program goes about its day.

The annotation goes on the *handler*, not the actor.
The same actor can have one handler that restarts only itself when it bubbles and another that takes the whole subsystem down.

## What a session looks like

Before you fill anything in, here's what the finished `BikeShare` does.

```blimp
share = spawn BikeShare
v = spawn BikeShare.Vault
i = spawn BikeShare.Inventory
share <- :install(v, i)

v <- :deposit(100)
share <- :charge(40)        # => {:ok, 60}
v <- :balance                # => 60

share <- :charge(500)        # => {:error, :declined}
v <- :balance                # => 0   (the vault bubbled and reset)
i <- :count                  # => 0   (was always 0; inventory wasn't touched)

i <- :add(20)
share <- :emergency          # => :recovered
i <- :count                  # => 0   (cascade reset everything)
```

Three behaviors visible there.

`charge(40)` is the happy path; the vault returns the new balance and the parent wraps it in `{:ok, ...}`.

`charge(500)` overdraws.
The vault bubbles `:overdraw`, the parent's `orelse` catches the bubble, the parent returns `{:error, :declined}`.
After this call the *vault* is back to defaults (cents = 0), but the *inventory* is untouched, because the vault's handler used the default `SelfBubble` strategy.

`emergency` triggers the vault's `:corruption` handler, which is annotated `bubbles(CascadeBubble)`.
That cascade reaches every `BikeShare.*` actor, so when we ask the inventory for its count after the emergency, it's been reset to 0 along with the vault.

Open `exercises/ch05_supervision/01_supervision.blimp` in the editor on the right.
You'll see the three actors with three `:TODO` handlers and a test actor at the bottom with five tests.
Two pass already; the other three are red until you fill in the handlers.

## Step 1: fill in `:withdraw`

The vault's `:withdraw` is the bubble source.
The shape is a `case` (which you've used since Chapter 2) with one branch that bubbles instead of replying.

A small parallel for the bubble move:

```blimp
on :divide(by: Int) do
  case by == 0 do
    true -> bubble :divide_by_zero
    _    -> reply 100 / by
  end
end
```

`bubble :reason` raises the failure with an atom payload.
The handler stops at that point; nothing downstream of the `bubble` runs.
A caller can let it propagate or catch it (Step 2).

For `:withdraw`, the failure case is "amount is bigger than cents" with payload `:overdraw`.
The success case is the rhythm you already know: `become` with the new field value, then `reply` with the post-`become` balance.
Note that `cents` inside the handler still refers to the *pre*-`become` value, so the reply has to compute the new value explicitly (`cents - amount`), the same way Chapter 1's `:rent` reply was the new status.

**Your task:** fill in `on :withdraw(amount: Int)`.
Two more tests turn green: "vault resets after a bubble (state lost)" and "inventory survives a vault overdraw" both lean on the bubble actually firing here.

## Step 2: fill in `:charge`

The parent's `:charge` translates a bubble from the vault into a tagged tuple at its boundary.
Two moves: the `orelse` to catch, then a `case` on the result to wrap.

The `orelse` shape, on its own:

```blimp
n = counter <- :get orelse 0   # if :get bubbles, n becomes 0
```

If the send returns normally, `n` is the reply.
If the send bubbles, `orelse` catches the bubble and `n` is whatever the right side evaluates to.
The right side is just an expression, so it can be a literal, an atom, or a more complex fallback.

The `case` shape on the result, also familiar from Chapter 2:

```blimp
case result do
  :missing -> reply {:error, :missing}
  _        -> reply {:ok, result}
end
```

A success replies with `{:ok, value}`; the sentinel atom from the `orelse` fallback gets translated to `{:error, reason}`.

For `:charge`, the call is `vault <- :withdraw(amount)`, the orelse fallback is `:declined`, and the case wraps either `{:error, :declined}` or `{:ok, balance}`.

This is the standard "bubble to tuple" translation.
The downstream handler bubbles when an invariant is broken; the parent decides whether to keep bubbling, recover silently with a default, or repackage the bubble as a tuple for callers that prefer that convention.

**Your task:** fill in `on :charge(amount: Int)`.
"charge returns declined on overdraw" should go green.

## Step 3: fill in `:corruption`

The corruption handler in the stub already has the `bubbles(CascadeBubble)` annotation in place.
The only thing left is the bubble payload, which the stub has as `bubble :TODO`.

The annotation doesn't change the value of the bubble, just the strategy.
A caller catching the bubble with `orelse` will see whatever atom you bubble; the difference from a default-strategy bubble is that *also*, before the bubble propagates back, every `BikeShare.*` actor has been restarted to defaults.

The chapter has been calling this case `:corrupted`.

**Your task:** replace `:TODO` with `:corrupted`.
"emergency cascades: both vault and inventory reset" should go green and that's all five.

## Designing failures: when to bubble, when to tuple

You now have two ways to report that something went wrong, and the choice between them is a real design decision.
Both convey "this didn't work."
The trade is in what they preserve and what they signal.

A tagged tuple keeps the actor alive.
The state you'd carefully built up is still there, and the caller is expected to handle the failure as one of the normal outcomes of the call.
That fits anywhere a "no" is a routine answer, like the bike-isn't-available case from chapter 2.

A bubble erases the actor's working state.
The caller is expected to either let it propagate or translate it into something callers downstream understand.
That fits when a failure means the actor was operating on bad assumptions, the kind of failure where you wouldn't trust the actor's state field values anymore even if you could read them.

If you're not sure which one to use, default to a tagged tuple.
You can always add a bubble later when you discover an invariant the actor depends on.
Going the other way (changing a bubble to a tuple) is harder, because callers may have written `orelse` clauses that suddenly stop firing.

## What you built

A small subsystem.
A `BikeShare` parent that holds a `BikeShare.Vault` and a `BikeShare.Inventory`, and translates an internal bubble into a clean tagged tuple at its boundary.
A vault that refuses an over-withdraw with a bubble and gets restarted for its trouble.
An `:emergency` handler that takes the whole subsystem of `BikeShare.*` actors down at once.

Three new pieces of language ground:

1. `bubble :reason` for raising a failure that propagates as a value.
2. `orelse fallback` on a send for catching the bubble at the call site.
3. `bubbles(CascadeBubble)` on a handler for restarting every dotted-name sibling under the same supervisor prefix.

Plus the dotted-name convention itself, which turns out to be the language's mechanism for "which actors belong together."
A bare name like `Plain` opts out of supervision entirely; bubbles from it propagate, but no restarts happen.
A dotted name like `BikeShare.Vault` opts in: the vault restarts when it bubbles, and (with `CascadeBubble`) it can take its siblings with it.

## What's next

The bike share has cash and inventory now, but no riders.
Chapter 6 introduces a `Rider` actor that holds a single user's session: who they are, which bike they currently have out, how long they've had it.
You'll see how the supervision boundaries we drew in this chapter give riders the right kind of isolation, and you'll start to see why one rider's misadventures shouldn't be able to take the rest of the system down.

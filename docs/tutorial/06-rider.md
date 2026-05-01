# Chapter 6: The Rider

Five chapters in, the bike share has bikes, stations, a fleet, a vault, and an inventory.
What it doesn't have is a person.

Every interaction so far has been a top-level script line acting as the user: `b <- :rent` from the REPL, `share <- :charge(40)` from a test.
That's fine for testing the system from the outside, but it isn't a model of the system.
The actual users of a bike share aren't lines in a script; they're sessions with state of their own.

This chapter introduces a `BikeShare.Rider` actor that holds one user's session: their name and the bike they currently have out (or `nil` when they're idle).
The rider is the first actor in the tutorial whose entire job is to model an entity from the outside world rather than a piece of the bike share's plumbing.

By the end you'll have seven tests passing, a rider that picks up a bike and returns it, and one new piece of language ground: `nil` as a sentinel state value, and the multi-clause guards that go with it.

## Why riders are actors

You could imagine modeling a rider as a struct: name, bike id, started-at timestamp.
Stash a bunch of those in a list somewhere, look them up by name when a request comes in.

For a small number of users at small load that works.
It also gives up on every property that made the actor model worth the trouble.

A rider has *state*: the bike they're currently on.
That state is updated by *requests* that need to be ordered: pickup, then return, then maybe pickup again.
If two requests arrive at the same time (rider tries to pick up bike A, and a stale "pickup B" request from a phone with bad signal arrives a moment later), one of them must be processed completely before the other.
That's the mailbox guarantee from Chapter 2, and you get it for free by making the rider an actor.

A rider can *fail* in a way that shouldn't take other riders down.
A buggy `:pickup` handler that bubbles for one user shouldn't reset another user's session, and Chapter 5's supervision boundaries give you that isolation for free as long as each rider gets its own actor instance.

So riders are actors, and the chapter is about what their handlers look like.

## The shape of a `BikeShare.Rider`

```blimp
actor BikeShare.Rider do
  state name: String :: "anon"
  state bike: Bike :: nil
end
```

A `String` for the rider's name and a `Bike` slot for the bike they're holding.
The default for `bike` is `nil`, which is new.

`nil` is Blimp's "no value" value.
You've seen it pop up in earlier chapters as the state default for actor references that haven't been wired up yet (`state vault: BikeShare.Vault :: nil` in Chapter 5).
Here it carries semantic weight: a rider whose `bike` field is `nil` is *idle*, not riding.

The `Bike` type annotation is honest about what the field will hold once it's set.
The default is `nil`, which is a valid value of every actor-typed field.
You can read this as "this slot will eventually hold a `Bike` reference; for now it's empty."

## What a session looks like

```blimp
alice = spawn BikeShare.Rider, name: "alice"
b = spawn Bike, id: "b-01"

alice <- :status                # => :idle
alice <- :pickup(b)             # => :ok
alice <- :status                # => :riding
b <- :status                    # => :rented   (the bike's own state changed)

alice <- :return                # => :ok
b <- :status                    # => :available

alice <- :return                # => {:error, :no_bike}
```

Three new behaviors visible there.

`:status` is a derived field; the rider doesn't store `:idle` or `:riding` directly, it computes the answer from whether `bike` is `nil`.

`:pickup(b)` does *two* things: it tells the bike to flip its own status to `:rented`, and it stashes a reference to that bike in the rider's own state.
Both have to happen, and they have to happen in that order: ask the bike first, only commit on the rider side if the bike said yes.

`:return` does the mirror: tell the bike to flip back to `:available`, then clear the rider's slot.

Open `exercises/ch06_rider/01_rider.blimp` in the editor on the right.
You'll see the `Bike` from earlier chapters, a `BikeShare.Rider` skeleton with three `:TODO` handlers, and a test actor at the bottom with seven tests.
The fallback clauses for `:pickup` and `:return` are pre-wired; you'll fill in the guarded ones.

## Step 1: fill in `:status`

The rider's `:status` is the simplest of the three handlers and a chance to introduce `nil` comparison without anything else going on.

`nil` is a value, and `==` works on it the way it works on anything else.
You can compare any field against `nil` to test whether it's been set:

```blimp
case payment == nil do
  true -> reply "no payment yet"
  _    -> reply "received"
end
```

The same shape applies to the rider's `bike` field.
Two atoms to reply with: `:idle` and `:riding`, depending on which side of the `nil` test you're on.

**Your task:** fill in `on :status`.
"fresh rider is idle" should go green.

## Step 2: fill in the guarded `:pickup`

The chapter's main move is here.
Two things have to happen and the order matters: ask the bike to be `:rented`, and only if the bike says yes, commit the bike reference to the rider's state.

Three new pieces show up.

### Guards on state field equality

The handler signature is:

```blimp
on :pickup(b: Bike) when bike == nil do
  ...
end
```

`when bike == nil` is a guard, the same family of guards as Chapter 2's `when status == :available`.
The guard reads from the actor's state (`bike`) and the message argument is also in scope (`b`), so guards can mix the two: `when bike == nil and b != self_bike` would be valid.

The fallback clause (already wired in the stub) handles the other case:

```blimp
on :pickup(b: Bike) do
  reply {:error, :already_riding}
end
```

Together they cover both possibilities.
The first clause runs when the rider is idle; the second runs when they aren't.

### Send-and-check before you commit

Inside the guarded clause, the move is to capture the bike's reply in a local, then dispatch on it:

```blimp
result = b <- :rent
case result do
  :ok -> ...    # bike accepted, safe to commit
  _   -> ...    # bike refused, do nothing on this side
end
```

The reply is `:ok` if the bike was available, or `{:error, :unavailable}` if it wasn't (Chapter 2 wrote that handler).
Pattern matching on the atom `:ok` keeps the success branch tight; `_` catches everything else, including the error tuple, and lets the rider stay idle.

This is the standard pre-flight pattern: ask the downstream actor first, only commit your own state change after the downstream confirms.
A rider that committed `bike: b` *before* asking would end up holding a reference to a rented bike that another rider is riding, which is the bug the bike's two-clause `:rent` was specifically designed to prevent.

### `become` only on the success branch

The success branch needs both a `become bike: b` (to commit the reference) and a `reply :ok` (to tell whoever sent `:pickup` it worked).
The failure branch only replies `{:error, :unavailable}`; no `become`, since nothing about the rider should change when the pickup fails.

**Your task:** fill in `on :pickup(b: Bike) when bike == nil`.
"pickup an available bike returns :ok", "after pickup, rider is :riding", and "pickup of an already-rented bike returns :unavailable" should all go green.

(The "pickup while already riding refuses" test passes already; the fallback clause that handles it was pre-wired.)

## Step 3: fill in the guarded `:return`

The mirror of `:pickup`, slightly simpler.

The guard:

```blimp
on :return when bike != nil do
  ...
end
```

`!= nil` is the inverse of the `:status` test you wrote in Step 1.
This clause runs when the rider is holding a bike; the fallback (pre-wired) handles the idle case.

The body has three moves:

1. Send `:return` to the bike, which flips the bike's status back to `:available`.
2. `become bike: nil` to clear the rider's slot.
3. `reply :ok` to whoever sent `:return`.

The bike's `:return` handler (Chapter 1) always succeeds; there's nothing to refuse, you're just telling the bike it's free again, so unlike `:pickup` there's no need to check the reply.
Each line happens unconditionally.

A small note on the order: send first, then `become`, then `reply`.
We're updating the bike's state and the rider's state and they have to stay consistent.
If we cleared `bike: nil` and *then* tried to send `:return` to it, we'd have already lost the reference.
Send while the reference is still in scope.

**Your task:** fill in `on :return when bike != nil`.
"return frees the bike" should go green and that's all seven.

## Why each rider is `BikeShare.Rider`

The actor name in this chapter is dotted: `BikeShare.Rider`, sitting under the same `BikeShare.` supervisor prefix as the `Vault` and the `Inventory` from Chapter 5.
Two reasons.

The first is that riders belong to the bike share.
A standalone `Rider` actor would have no relationship to the rest of the system.
Putting it under `BikeShare.` says "this is part of this bike share; it's gone if the bike share is gone."

The second is what Chapter 5 unlocked.
Each `BikeShare.Rider` instance is its own dotted-name actor, which means each rider is its own supervision boundary.
A rider whose `:pickup` handler bubbles a failure resets *that one rider*; the other riders, the vault, and the inventory are all untouched, because the default `SelfBubble` strategy from Chapter 5 only restarts the bubbling actor.

In a system with thousands of riders this property matters.
A bug in one user's session can't take down the rest of the active sessions or the bike share's books.
You didn't write any code to get that isolation; it came from the dot in the name and the supervision rules from Chapter 5.

## What you built

A `BikeShare.Rider` actor that models one user's session: a name, a bike slot that's `nil` when idle, and a status derived from which.
Seven tests passing, including the one where the rider's own state stays clean when the bike refuses a pickup.

What showed up that's worth holding onto:

1. `nil` as a meaningful state value, with the `== nil` / `!= nil` guards that go with it.
2. The pre-flight check pattern: ask the downstream actor first, only commit your own state change after it confirms.
3. State-derived replies: a `:status` handler that computes its answer from `bike == nil` instead of storing the answer directly.

## What's next

The rider can pick up and return a bike, but no time passes between the two.
Real bike share sessions have *duration*: rentals start at one moment and end at another, and overage fees, GPS phone-homes, and stale-rental cleanups all need to know about elapsed time.

Chapter 7 introduces the `Clock`, the first actor in the tutorial that runs a live loop instead of waiting for a message.
You'll see how Blimp handles "do this on a tick" without giving up the message-passing model, and the rider you wrote in this chapter will get a `started_at` field that depends on the clock's ticks.

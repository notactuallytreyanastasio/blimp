# Chapter 2: State, become, and the free lock

The `Bike` from Chapter 1 has a bug.
If you send it `:rent` twice in a row, both times succeed.
The `status` stays `:rented`, and the handler happily replies `:ok` each time.
In a real bike share that would mean two people think they rented the same bike.

The usual fix for "make sure only one rental succeeds" is a mutex.
You wrap the read-and-write block in a lock, and now concurrent calls can't both see `:available` at the same time.
If you forget the lock, the bug ships and shows up three weeks later in prod.

Blimp doesn't have mutexes.
By the end of this chapter you'll see why it doesn't need them.

What we're adding to the `Bike`:

- a guard on `:rent` so it only succeeds when the bike is actually available
- a fallback `:rent` clause that refuses, replying with an error tuple
- a `:return` that flips the bike back to available
- a `:report_broken` that marks a bike for the mechanic

Open `exercises/ch02_state/01_rental.blimp` in the editor on the right.
Four handler bodies are stubbed with `:TODO`.
You'll fill them in one at a time.

## Two clauses for one message

You can define `on :rent` more than once.
Same message atom, different clauses:

```blimp
on :rent when status == :available do
  # only runs when the bike is available
end

on :rent do
  # runs if no earlier clause matched
end
```

When a `:rent` message arrives, Blimp tries clauses top to bottom.
The first one whose guard matches is the one that runs.
A clause with no `when` always matches, so it works as the catch-all.

If you've written Erlang or Elixir function heads, this is the same thing.
If you haven't, read it as "try the clauses in order, first match wins."

Multi-clause handlers with pattern matching were one of Blimp's earliest design decisions.
The thinking at the time was that pattern matching and immutability were going to be core to the language, and that meant borrowing the Erlang-style function-head shape for defining behavior instead of having one monolithic handler body with branching inside.
Letting you write two `on :rent` clauses puts the branching in the dispatch itself, where the runtime can see it.

### Guards

The `when <expression>` bit after the message pattern is a guard.
It's a boolean expression that has access to the actor's state fields and any parameters the message carries.
If it evaluates truthy, the clause matches.

Guards are intentionally kept simple: comparisons, arithmetic, and boolean operators, but no arbitrary function calls.
That restriction keeps them predictable and lets the runtime fast-path the check without worrying about side effects leaking through.

## Step 1: fill in the guarded `:rent`

The happy-path handler, when it's done, looks like this:

```blimp
on :rent when status == :available do
  become status: :rented
  reply :ok
end
```

The guard filters for "only when `status` is `:available`", the `become` commits the new state, and the `reply :ok` answers the sender.

**Your task:** replace the `:TODO` in the guarded `on :rent` with `become status: :rented` followed by `reply :ok`.
Run tests.
"first rent returns :ok" and "first rent flips status to :rented" should go green.
Two down.

## Tagged tuples

Blimp (like Elixir) wraps success and failure values in tagged tuples:

```blimp
:ok                       # simple success
{:ok, some_payload}       # success with data
:error                    # simple error
{:error, :unavailable}    # error with a reason atom
{:error, "message"}       # error with a reason string
```

The atom at the front of the tuple is the tag.
Callers typically pattern-match on the tag to branch success versus failure:

```blimp
case account <- :withdraw(50) do
  :ok         -> # proceed
  {:error, _} -> # handle failure
end
```

You'll see `:ok`, `{:ok, something}`, `:error`, and `{:error, reason}` all over Blimp code.
It's a convention, not a type, so you can use any shape you want, but the payoff of following the convention is that every caller already knows how to branch on your reply.

Blimp doesn't have try/catch inside handlers.
For unrecoverable failures there's a mechanism called `bubble` (Chapter 5), but for expected failures like "the bike isn't available right now" the answer is to return a tagged tuple.
Errors in Blimp are values that flow back through `reply`, not exceptions you have to catch.

## Step 2: fill in the fallback `:rent`

The fallback runs whenever the guarded first clause doesn't match.
For the `Bike` that means the `status` is something other than `:available`, which we'll report as `:unavailable` so the caller can tell what went wrong:

```blimp
on :rent do
  reply {:error, :unavailable}
end
```

No `become` in this one.
A rejected rental doesn't change the bike's state, it just says no.

**Your task:** replace the `:TODO` in the fallback `on :rent` with `reply {:error, :unavailable}`.
"second rent returns error tuple" and "refused rent does not change status" should go green.

## Step 3: fill in `:return`

Nothing new this step, just a mirror of the `:rent` handler from Chapter 1.

```blimp
on :return do
  become status: :available
  reply :ok
end
```

**Your task:** fill it in.
"after return, can rent again" should go green.

## A third state: `:broken`

So far the bike has been either `:available` or `:rented`.
Real bike shares also have bikes with flat tires and bikes in the mechanic's queue, so the model needs another state.

In a language with enums, adding a state would mean editing a type somewhere and remembering to handle the new variant everywhere it's matched.
In Blimp, `status` is typed as `Atom`, and any atom you haven't used yet is already a valid status.
No declaration needed:

```blimp
become status: :broken
```

The runtime accepts it because `:broken` is an atom.
The already-written fallback `:rent` clause will now see `status != :available` when the bike is broken and reply `{:error, :unavailable}` automatically, without you adding a new handler for the broken case.
The dispatch already knows what to do.

## Step 4: fill in `:report_broken`

Last handler.

```blimp
on :report_broken do
  become status: :broken
  reply :ok
end
```

**Your task:** fill it in.
"broken bike refuses rent" should go green, which is all seven.

## Why the lock is free

Back to the bug the chapter opened with.
In a language with ordinary shared-memory threading, the rent logic would look something like this:

```python
def rent(bike):
    if bike.status == "available":    # read
        bike.status = "rented"         # write
        return "ok"
    return "unavailable"
```

If two threads call `rent(b)` at the same moment, both can run the `if` before either one runs the assignment.
Both see `"available"`, both enter the block, both write `"rented"`, and you've rented the same bike twice.
The fix is to wrap the read-and-write in a mutex so only one thread executes the body at a time.

Here's the Blimp version again:

```blimp
on :rent when status == :available do
  become status: :rented
  reply :ok
end

on :rent do
  reply {:error, :unavailable}
end
```

No mutex, no `synchronized`, no locks anywhere, and also no race.

The reason has two parts.

The first part is the mailbox.
Every actor has one, and the actor pulls messages off it and handles them one at a time, in arrival order.
While the first `:rent` handler is running, the second `:rent` is sitting in the mailbox waiting its turn.
It can't race the first one because it isn't running yet.

The second part is that a handler runs to completion before the next one starts.
Blimp's scheduler is modeled on Erlang's BEAM: actors get preempted between messages, not mid-handler.
By the time the second `:rent` is pulled off the mailbox, the first one has already committed its `become` and the actor's status is `:rented`.
The guard on the first clause reads that fresh `status`, evaluates to false, and the fallback clause runs.

There's no inconsistent "both see available" window at any point.
The actor has no window of inconsistency at all, because no other code can observe or modify the actor's state while a handler is running.
The previous state and the next state are both valid, fully-formed versions of the actor, and the transition from one to the other is atomic.

A phrase actor-model people love is "safe concurrency by construction."
Read that as: you didn't do anything to earn the safety.
The mailbox is the lock and the handler is the critical section, and both came with the actor the moment you defined it.

## What you built

A `Bike` that refuses double rentals, refuses to be rented when broken, and lets you take it out of service and put it back in.
Seven green tests, zero mutexes, zero shared-memory hazards.

The whole thing comes from two language rules working together: each actor has a private mailbox, and handlers run to completion.
You didn't add either rule, they come from defining an actor in the first place.

## What's next

Chapter 3 adds a second actor.
A `DockingStation` that holds a pile of bikes and hands them out on request, while each individual `Bike` still owns its own state.
Once there's more than one actor in the system, the only way they can interact is by sending each other messages, and you'll start to feel why that constraint actually buys you something instead of just feeling like a limitation.

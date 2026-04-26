# Chapter 3: Actors talking to actors

Chapter 1 gave you a Bike.
Chapter 2 made the Bike careful about double-rentals.
The whole system has been one actor and a test harness, which is the smallest interesting thing you can build but not yet a system.

This chapter adds a second actor.
A `DockingStation` that holds a list of bikes that are physically parked at it, hands them out when somebody wants to rent, and takes them back when somebody returns.
By the end you'll have eight tests passing, an actor that owns a list of references to other actors, and the first real taste of what it's like when the only way two pieces of state can interact is by sending each other mail.

## Why a second actor at all?

A reasonable first instinct is to put the list of bikes inside the Bike actor itself, or maybe to make a single actor that holds everything: bikes, riders, stations, the works.
That works for about ten lines of code and then it stops working, and the reason is the same reason classes in object-oriented languages get split: one piece of state shouldn't be responsible for knowing about every other piece of state.

In bike share terms, a single Bike already has its own job.
It tracks its operational status, refuses double rentals, and later in the tutorial it'll flag itself broken and phone home with GPS.
That's plenty of clipboard for one dispatcher.

A DockingStation has a different job.
It tracks which bikes are physically parked at it right now, hands one out on request, accepts returns.
The bikes themselves don't know which station they're at, and they don't need to.
That's the station's clipboard.

So we get two actors.
The Bike still owns its own status.
The DockingStation owns the inventory list.
Renting a bike at a station is going to be the station pulling a bike off its inventory and telling that bike to flip its own status to `:rented`.
The work gets done in two places, the way it would in any system that's actually shaped like the world.

There's a deeper reason this matters that won't pay off until Chapter 5.
When two pieces of state live in two actors, a crash in one doesn't take the other down.
A buggy Bike can fall over and the station still knows where its other bikes are.
One actor holding everything doesn't give you that, and there's no clean way to add it later.

## The shape of a DockingStation

Here's the actor definition with no handlers, just state:

```blimp
actor DockingStation do
  state name: String :: "unnamed"
  state bikes: [Bike] :: []
end
```

The `name` field is the same shape you saw in Chapter 1.
String type, default value, nothing new.
What's new is the second field.

### `state bikes: [Bike] :: []`

`[Bike]` is a list of `Bike`.
The square brackets in a type position mean "a list of these."
A `[Int]` is a list of integers, a `[String]` is a list of strings, and `[Bike]` is a list of references to Bike actors.

`[]` on the right of the `::` is the empty list.
A fresh DockingStation starts with no bikes parked at it, which is the right default for "you just spawned a new station and haven't told it about any bikes yet."

When you wrote `spawn Bike, id: "b-01"` in Chapter 1, the value you got back wasn't a copy of the Bike actor, it was a _reference_ to the Bike actor that now lives in the runtime.
Two variables can hold the same reference and they both point at the same actor.
You can stuff a reference in a list, pass it as a message argument, store it in another actor's state, and the actor on the other end of the reference is still just one actor with one mailbox.

This is the same thing as a file handle in any other language.
You don't carry the file's bytes around in your variable, you carry a small token that the operating system uses to find the file when you ask.
Actor references are file handles for actors.

## What a station session looks like

Before you fill in any handlers, look at how a fully-built DockingStation is used:

```blimp
fulton = spawn DockingStation, name: "fulton"
b1 = spawn Bike, id: "b-01"
b2 = spawn Bike, id: "b-02"

fulton <- :dock(b1)        # => :ok
fulton <- :dock(b2)        # => :ok
fulton <- :count           # => 2

fulton <- :rent            # => {:ok, "b-02"}
fulton <- :count           # => 1
b2 <- :status              # => :rented
```

The bikes and the station are separate spawns.
Each `spawn` call creates one live actor and the variable on the left holds a reference to it, so `b1`, `b2`, and `fulton` are three independent actors with three independent mailboxes.

`fulton <- :dock(b1)` carries `b1`, the reference, as a message argument.
The station's `:dock` handler will receive that reference and stash it inside its own `bikes` list.
After that line runs, the station's state holds a reference to a Bike that no top-level variable points to anymore.

The pair of lines at the end is where the chapter pays off.
`fulton <- :rent` returns `{:ok, "b-02"}`, and immediately after, `b2 <- :status` reports `:rented`.
The station handed out a bike _and_ the bike's own status changed.
Two actors saw their state change as a result of one external message, which is what the station's `:rent` handler is going to make happen by sending `:rent` to the bike inside its own body.

Open `exercises/ch03_actors/01_station.blimp` in the editor on the right.
You'll see the Bike from Chapter 2, the DockingStation skeleton with three `:TODO` handlers, and a test actor at the bottom with eight tests.
Three of them already pass, since `:name` and `:count` are wired up and one test exercises both.
The other five are red until you fill in the handlers.

## Step 1: fill in `:dock`

The first handler to write is the simplest of the three.

```blimp
on :dock(b: Bike) do
  become bikes: [b | bikes]
  reply :ok
end
```

Two pieces here that haven't shown up before in this tutorial.

### `(b: Bike)`: a typed message argument

In Chapter 1 your messages were bare atoms like `:rent` and `:status`.
Some messages need to carry data, and that's what the parens after the atom are for.

`(b: Bike)` says "this message takes one argument named `b`, of type Bike."
Inside the handler body, `b` is in scope as an ordinary variable holding a reference to whichever Bike was passed.

The type annotation isn't optional decoration.
It's how Blimp checks at the call site that you're not passing a String when the handler expected a Bike.
You can pass any number of arguments and you can mix types: `on :install(name: String, b: Bike)` and so on.
For now we just need one.

The shape is the same as a state field: name first, then type.
You don't get to write `(b)` with no type and let the runtime guess.
Being explicit at the boundary keeps the actor honest.

### `[b | bikes]`: cons

The expression `[b | bikes]` builds a new list whose first element is `b` and whose tail is the existing `bikes` list.
The pipe is the cons operator, lifted from Erlang and Elixir.
Read it as "b in front of bikes."

If `bikes` was `[]` (empty), then `[b | bikes]` evaluates to `[b]`.
If `bikes` was `[x, y]`, then `[b | bikes]` evaluates to `[b, x, y]`.
The original `bikes` list is untouched.
Lists in Blimp are immutable, just like state, so cons doesn't modify the old list, it constructs a new one that shares the tail with the old one.

This is fast.
Cons is constant time because all you're doing is allocating a small "head plus pointer-to-tail" pair.
A list isn't a contiguous array, it's a chain of these pairs, so prepending is cheap and appending to the end is expensive.
We'll never need to append in this chapter.

### Putting it together

```blimp
on :dock(b: Bike) do
  become bikes: [b | bikes]
  reply :ok
end
```

`become bikes: [b | bikes]` says the next version of this DockingStation has the new list as its `bikes` field.
Everything else (the `name`) is left alone, exactly the same way it was in Chapter 1's `become status: :rented`.
`reply :ok` answers the sender so the caller knows the dock succeeded.

**Your task:** in the editor, find `on :dock(b: Bike)`, replace the two `:TODO` lines with the `become` and the `reply`, click Run Tests.
"dock replies :ok" and "dock increments count" should both go green, and that's two more tests in the bag.

## Sending messages from inside a handler

The next handler does the actual work.
Before you write it, look at what's new about it.

So far, every `<-` you've seen has been at the top level of a script.
You spawned an actor, then you wrote `b <- :rent` to send it a message.
The send sat in the script's flow, the same place an ordinary expression would sit.

A handler body is also a place where ordinary expressions can sit.
Inside an `on` block, you can write any expression you'd write at the top level, including a `<-` send to another actor.
Nothing about the actor model says handlers are sealed.
An actor can send messages while it's processing one.

So when the DockingStation receives `:rent`, the handler will:

1. Pick the bike at the front of its list
2. Set the new list to everything except that bike
3. Send the bike a `:rent` message
4. Reply to whoever asked

Step 3 is a send from inside a handler.
The bike is a separate actor, so this is two actors talking.
The DockingStation pauses its own work for the duration of that send (every send blocks until the reply, remember from Chapter 1) and resumes when the bike replies.

That blocking matters.
While the DockingStation is waiting for the bike, the DockingStation's own mailbox is _not_ being processed.
Other clients trying to dock, rent, or count from this station will wait their turn.
This is fine for now because everything happens in microseconds and the bike replies fast, but in a deeper chapter you'll see how a chain of slow synchronous sends can starve a system, and you'll see what to do about it.

For now: in a handler, `b <- :rent` works exactly the way it does at the top level.
The handler pauses, the bike runs its `:rent` handler, the reply comes back, the handler continues.

## Step 2: fill in the empty `:rent` clause

Two clauses for `:rent`, same as Chapter 2.
The fallback is easier so we'll do it first.

```blimp
on :rent do
  reply {:error, :empty}
end
```

This runs when the guarded clause didn't match, which on the DockingStation means the bikes list is empty.
There's no state to change (an empty station stays empty when somebody tries to rent from it), so no `become`.
Just a reply with the standard tagged error tuple from Chapter 2.

`{:error, :empty}` follows the `{:error, reason}` convention.
Callers can pattern-match on the `:empty` atom to give the user a useful message ("this station has no bikes right now").

**Your task:** replace the `:TODO` in the unguarded `on :rent` with `reply {:error, :empty}`.
"rent on empty station returns {:error, :empty}" should go green.

## Step 3: fill in the guarded `:rent` clause

The guarded clause is where the chapter's whole point lives.
Here's what it looks like done:

```blimp
on :rent when length(bikes) > 0 do
  b = head(bikes)
  become bikes: tail(bikes)
  b <- :rent
  reply {:ok, b <- :id}
end
```

Walk through it line by line.

### The guard: `when length(bikes) > 0`

`length` is a builtin that returns the number of elements in a list.
`length([])` is `0`, `length([b])` is `1`, and so on.
The guard says this clause only runs when there's at least one bike to hand out.

If the list is empty, the guard fails, Blimp moves on to the next `:rent` clause (the fallback), and that one replies `{:error, :empty}`.
The two clauses together cover both possibilities, with no `if` needed.

### `b = head(bikes)`

`head` is a builtin that returns the first element of a list.
`head([x, y, z])` is `x`.
On an empty list it would crash, which is why we guarded for `length(bikes) > 0` first.

`b = ...` binds the result to a local variable named `b`, in scope for the rest of this handler body.
Local variables don't survive past the end of the handler and aren't visible to other actors.
It's the same variable binding you'd get in Ruby or Elixir or any expression-oriented language.

After this line, `b` holds a reference to the bike at the front of the list.

### `become bikes: tail(bikes)`

`tail` returns everything except the first element.
`tail([x, y, z])` is `[y, z]`, and `tail([x])` is `[]`.

`become bikes: tail(bikes)` declares that the next version of the DockingStation has a bikes list with the front bike removed.
This is the dock-side bookkeeping: the bike we're about to rent is no longer parked at this station.

Notice that the order is `head` first, then `become tail`.
We bind `b` to the front of the list _before_ we change the list.
Since `bikes` is immutable and `tail(bikes)` is a fresh list, the order doesn't actually matter for correctness here.
But "look first, then write" is a habit worth keeping in any language.

### `b <- :rent`

`b` is a reference to a Bike.
Sending it `:rent` runs the Bike's own `:rent` handler from Chapter 2, which checks the bike's status, flips it to `:rented` if it was available, and replies `:ok` (or `{:error, :unavailable}` if it wasn't).

Three consequences of this single line, in increasing order of how much they bend your model.

The DockingStation pauses while the send is in flight. The send is synchronous,
the handler is blocked until the bike replies, and any messages arriving at the
DockingStation in the meantime queue up in its mailbox.

A different actor's state changes.
After this line returns, the Bike actor on the other end of `b` has a `status` field of `:rented` instead of `:available`.
The DockingStation didn't reach into the bike and set the field, it asked the bike to do it.
The bike is the only thing that can change the bike's status, by design.

The reply gets thrown away.
`b <- :rent` evaluates to whatever the bike replies, but we don't bind it to anything on this line.
That's fine for the tutorial because we know the bike will say `:ok` (it just came off the dock, so it was available).
A more paranoid handler would catch the reply and act on it, and you'll write one of those later in the tutorial.

### `reply {:ok, b <- :id}`

The last line is the reply, and it does one more send inside the same handler.

`b <- :id` sends `:id` to the bike and evaluates to the bike's reply.
Wrap that in a `{:ok, ...}` tuple and you get the success-with-data shape from Chapter 2.

The caller of `:rent` gets back something like `{:ok, "b-77"}`, where `"b-77"` is the id the bike reported.
That's enough information to tell the user "you rented bike b-77, off you go."

This handler does _three_ sends total: it sends `:rent` to the bike, it sends `:id` to the bike, and it `:reply`s to the original caller.
Three message exchanges to handle one external `:rent` request, which is normal in actor systems and not something you should worry about until benchmarks tell you to.

### Putting it together

```blimp
on :rent when length(bikes) > 0 do
  b = head(bikes)
  become bikes: tail(bikes)
  b <- :rent
  reply {:ok, b <- :id}
end
```

**Your task:** fill in the body of the guarded `on :rent`.
The remaining tests should all go green: rent returns the right tuple, rent removes the bike from the station's count, and rent flips the bike's own status to `:rented`.
That last one is the one that proves something interesting happened: the test asserts state on a different actor than the one it sent the message to, and the assertion succeeds because the DockingStation reached out and told the bike to change.

## Who owns what?

The Bike actor owns one piece of state: its status.
Nothing outside the Bike can read or write that field directly.
The only way to make a bike `:rented` is to send the bike a `:rent` message and let the bike's own handler do the work.
That's true even when the sender is another actor, like our DockingStation.

The DockingStation actor owns one piece of state: its inventory list.
Nothing outside the station can read or write that list.
The only way to add a bike to the inventory is to send the station a `:dock` message.
The only way to remove one is to send `:rent`.

There is no part of the program where both pieces of state are visible.
The station can read the bike's status by asking, and the bike can be told to flip its status by being asked, but neither one is ever holding both clipboards at once.

This is what people mean by "isolation by construction."
The language handed you this isolation the moment you defined two actors instead of one, not because you wrote careful code or remembered a convention.
A bug in the Bike's status logic cannot corrupt the station's list because it can't reach the list.
A bug in the station's `:rent` handler cannot accidentally read the bike's private state because it has no direct access.
The mailbox is the only door.

The flip side of isolation is that _every_ interaction has to go through a message.
You can't reach in, you can't shortcut, you can't optimize a hot path by sharing a pointer.
Some things that would be one line of code in a shared-memory language become a small protocol of messages in an actor language.
That's the trade.

For most software it's worth it.
Bugs where two threads tangle the same field are nasty to find and worse to fix, and a system that makes them impossible by construction is one less category to worry about.
The whole tutorial keeps taking that deal.

## What you built

A DockingStation actor that keeps a list of references to Bike actors.
Eight tests passing, and one of them asserts that an action sent to the station produces an observable effect on a different actor.

Three new things showed up:

1. List-typed state and the cons / `head` / `tail` / `length` builtins for working with it.
2. Typed message arguments with `(name: Type)` after the message atom.
3. Sending messages to other actors from inside a handler, with all the consequences (blocking, ordering, isolation) that come with that.

You also met the idea that an actor reference is a value.
You can store it in a list, pass it as an argument, hold onto it across many message exchanges.
The actor on the other end is one thing with one mailbox no matter how many references point at it.

## What's next

Two loose ends from this chapter.

The DockingStation has no `:return` handler.
A rented bike never comes back, which is a bug a real bike share would notice on day one.
You can write it yourself right now if you want the practice; it's the mirror of `:dock`.

The bigger thing: this chapter has one DockingStation and a couple of bikes.
A real bike share has dozens of stations across a city, and somebody has to manage them all.
That's Chapter 4, where you'll meet supervision trees and Blimp's dotted naming convention.
You'll see how the runtime groups actors under shared parents, and you'll use that grouping to decide what should crash together and what shouldn't.

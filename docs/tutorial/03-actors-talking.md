# Chapter 3: Actors talking to actors

Chapter 1 gave you a `Bike`.
Chapter 2 made the `Bike` careful about double-rentals.
The whole system has been one actor and a test harness, which is the smallest interesting thing you can build but not yet a system.

This chapter adds a second actor.
A `DockingStation` that holds a list of bikes that are physically parked at it, hands them out when somebody wants to rent, and takes them back when somebody returns.
By the end you'll have eight tests passing, an actor that owns a list of references to other actors, and the first real taste of what it's like when the only way two pieces of state can interact is by sending each other mail.

## Why a second actor at all?

A reasonable first instinct is to put the list of bikes inside the `Bike` actor itself, or maybe to make a single actor that holds everything: bikes, riders, stations, the works.
That works for about ten lines of code and then it stops working, and the reason is the same reason classes in object-oriented languages get split: one piece of state shouldn't be responsible for knowing about every other piece of state.

In bike share terms, a single `Bike` already has its own job.
It tracks its operational status, refuses double rentals, and later in the tutorial it'll flag itself broken and phone home with GPS.
That's plenty of clipboard for one dispatcher.

A `DockingStation` has a different job.
It tracks which bikes are physically parked at it right now, hands one out on request, accepts returns.
The bikes themselves don't know which station they're at, and they don't need to.
That's the station's clipboard.

So we get two actors.
The `Bike` still owns its own status.
The `DockingStation` owns the inventory list.
Renting a bike at a station is going to be the station pulling a bike off its inventory and telling that bike to flip its own status to `:rented`.
The work gets done in two places, the way it would in any system that's actually shaped like the world.

There's a deeper reason this matters that won't pay off until Chapter 5.
When two pieces of state live in two actors, a crash in one doesn't take the other down.
A buggy `Bike` can fall over and the station still knows where its other bikes are.
One actor holding everything doesn't give you that, and there's no clean way to add it later.

## The shape of a `DockingStation`

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
A `[Int]` is a list of integers, a `[String]` is a list of strings, and `[Bike]` is a list of references to `Bike` actors.

`[]` on the right of the `::` is the empty list.
A fresh `DockingStation` starts with no bikes parked at it, which is the right default for "you just spawned a new station and haven't told it about any bikes yet."

When you wrote `spawn Bike, id: "b-01"` in Chapter 1, the value you got back wasn't a copy of the `Bike` actor, it was a _reference_ to the `Bike` actor that now lives in the runtime.
Two variables can hold the same reference and they both point at the same actor.
You can stuff a reference in a list, pass it as a message argument, store it in another actor's state, and the actor on the other end of the reference is still just one actor with one mailbox.

This is the same thing as a file handle in any other language.
You don't carry the file's bytes around in your variable, you carry a small token that the operating system uses to find the file when you ask.
Actor references are file handles for actors.

## What a station session looks like

Before you fill in any handlers, look at how a fully-built `DockingStation` is used:

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
After that line runs, the station's state holds a reference to a `Bike` that no top-level variable points to anymore.

The pair of lines at the end is where the chapter pays off.
`fulton <- :rent` returns `{:ok, "b-02"}`, and immediately after, `b2 <- :status` reports `:rented`.
The station handed out a bike _and_ the bike's own status changed.
Two actors saw their state change as a result of one external message, which is what the station's `:rent` handler is going to make happen by sending `:rent` to the bike inside its own body.

Open `exercises/ch03_actors/01_station.blimp` in the editor on the right.
You'll see the `Bike` from Chapter 2, the `DockingStation` skeleton with three `:TODO` handlers, and a test actor at the bottom with eight tests.
Three of them already pass, since `:name` and `:count` are wired up and one test exercises both.
The other five are red until you fill in the handlers.

## Step 1: fill in `:dock`

`:dock` has three moves: pull the bike out of the message, prepend it onto the `bikes` list, reply.
Two of those moves use language pieces you haven't seen yet.

### Typed message arguments: `(name: Type)`

In Chapter 1 your messages were bare atoms like `:rent` and `:status`.
Messages can also carry data; that's what the parens after the atom are for.
Here's a small actor whose `:put` message accepts an integer and returns the new size:

```blimp
actor Counter do
  state n: Int :: 0
  on :put(x: Int) do
    become n: n + x
    reply n + x
  end
end
```

`(x: Int)` says "this message takes one argument named `x`, of type `Int`."
Inside the body, `x` is an ordinary variable holding whatever the sender passed.

The shape is the same as a state field: `name: Type`.
You can have multiple parameters: `on :install(name: String, count: Int) do ...`.
The type isn't optional decoration; it's how Blimp checks at the call site that you didn't pass a `String` where an `Int` was expected.

`:dock`'s argument is `(b: Bike)`.
The type is `Bike` instead of `Int`, but the shape is the same.

### Cons: `[head | tail]`

The expression `[h | rest]` builds a new list whose first element is `h` and whose tail is the existing list `rest`.
The pipe is the cons operator, lifted from Erlang and Elixir, and it works on any list type:

```blimp
[1 | [2, 3]]      # => [1, 2, 3]
["a" | []]        # => ["a"]
[bike | bikes]    # one bike in front of an existing bike list
```

Cons is fast.
It allocates one "head plus pointer-to-tail" pair, regardless of how long the tail is.
The original list is untouched, since lists are immutable.

The most common use of cons inside a handler is to add to a state-held list and `become` the result:

```blimp
on :record(event: String) do
  become events: [event | events]
  reply :ok
end
```

`:dock` does the same dance.
The state field is `bikes` instead of `events`, the argument is a `Bike` instead of a `String`, but the rhythm is identical: typed arg in, cons onto state, become, reply `:ok`.

**Your task:** in the editor, fill in `on :dock(b: Bike)` so it prepends `b` onto `bikes` and replies `:ok`.
Run Tests.
"dock replies :ok" and "dock increments count" should both go green.

## Step 2: fill in the empty `:rent` clause

Two clauses for `:rent`, same as Chapter 2.
The fallback is easier so we'll do it first.

It runs when the guarded clause didn't match, which on the `DockingStation` means the bikes list is empty.
An empty station stays empty when somebody tries to rent from it, so the body has no `become`, just a reply with a tagged error tuple in the `{:error, reason}` shape from Chapter 2.

The reason atom should be `:empty` so callers can pattern-match on a specific cause and tell the user "this station has no bikes right now."

**Your task:** fill in the unguarded `on :rent`.
"rent on empty station returns {:error, :empty}" should go green.

## Step 3: fill in the guarded `:rent` clause

The guarded clause is where the chapter's whole point lives.
Five new pieces show up here, none of them complicated; the trick is fitting them together.

### The guard: `when length(bikes) > 0`

`length` returns the number of elements in a list:

```blimp
length([])           # => 0
length(["a", "b"])   # => 2
```

A guard is just a boolean expression that has access to state.
The same `when ... do` shape from Chapter 2's `on :rent when status == :available do`, with a different test:

```blimp
on :rent when length(bikes) > 0 do
  ...
end
```

If the list is empty, the guard fails, Blimp moves on to the fallback clause from Step 2, and that one replies `{:error, :empty}`.
Together the two clauses cover both cases without an `if` in sight.

### `head` and `tail`: pulling the front off a list

Two builtins for taking a list apart:

```blimp
head([10, 20, 30])    # => 10
tail([10, 20, 30])    # => [20, 30]
tail([10])            # => []
head([])              # crash
```

`head` is the front, `tail` is everything else.
`head` on an empty list crashes, which is why the guard above exists; once you're inside the body, you've already proven the list isn't empty.

The "pop the front" pattern is a `head` to grab the value, then a `become` with `tail` to commit the shorter list:

```blimp
actor Stack do
  state items: [Int] :: []
  on :pop when length(items) > 0 do
    top = head(items)
    become items: tail(items)
    reply top
  end
end
```

`top = head(items)` binds a local variable.
Local variables live for the duration of one handler invocation; they aren't state, they don't survive past the `end`, and they aren't visible to other actors.

The order matters in spirit if not in fact: bind `top` *before* you change the list.
Lists are immutable so it doesn't actually break, but "look first, then write" is the habit that will protect you in any language.

`:rent` does the same dance with a `Bike` reference instead of an `Int`.

### `b <- :rent`: sending into another actor from inside a handler

So far every `<-` you've seen has been at the top level of a script.
A handler body is also a place where ordinary expressions can sit, and a `<-` send is an ordinary expression.
Nothing about the actor model says handlers are sealed.

```blimp
on :poke(other: Counter) do
  other <- :put(1)
  reply :ok
end
```

That handler sends `:put(1)` to whatever `Counter` reference was passed in.
The send is synchronous: this handler pauses until `:put(1)` has been processed and replied to.
While it's paused, messages arriving at *this* actor queue up in its mailbox.
The reply value is discarded (the line doesn't bind it to anything), which is fine if you don't need it.

For `:rent`, the `<- :rent` send goes to the bike you just popped off the front of `bikes`.
The bike's own `:rent` handler from Chapter 2 will check its status, flip it to `:rented`, and reply `:ok`.
Two actors changed state because of one external message.

A more paranoid handler would bind the reply and check it; we know the bike was available because we just popped it off a dock, so we let it go.

### `{:ok, b <- :id}`: a send inside an expression

A `<-` send is an expression that evaluates to the reply.
You can use it anywhere an expression goes, including inside a tuple literal:

```blimp
{:ok, counter <- :get}    # build a tuple containing the counter's reply
```

`:rent` will use the same trick to ask the bike for its id and wrap the answer in a success tuple, so the caller gets back something like `{:ok, "b-77"}`.

That's three sends in one handler: one to `:rent` the bike, one to ask its `:id`, one `:reply` back to whoever invoked `:rent`.
Three message exchanges to handle one outside request, which is normal in actor systems and not worth worrying about until benchmarks tell you to.

### Composing it

Five moves: a guard, a `head` into a local, a `become tail`, a discarded send, and a reply that contains a send.
The exercise file has the `case`-free pattern for each piece elsewhere; the new thing is wiring them together in one handler.

**Your task:** fill in the body of the guarded `on :rent`.
The remaining tests should all go green.
The interesting one is "rent flips the bike's own status to `:rented`": the test asserts state on a *different* actor than the one it sent the message to, and the assertion succeeds because your handler reached out and told the bike to change.

## Who owns what?

The `Bike` actor owns one piece of state: its status.
Nothing outside the `Bike` can read or write that field directly.
The only way to make a bike `:rented` is to send the bike a `:rent` message and let the bike's own handler do the work.
That's true even when the sender is another actor, like our `DockingStation`.

The `DockingStation` actor owns one piece of state: its inventory list.
Nothing outside the station can read or write that list.
The only way to add a bike to the inventory is to send the station a `:dock` message.
The only way to remove one is to send `:rent`.

There is no part of the program where both pieces of state are visible.
The station can read the bike's status by asking, and the bike can be told to flip its status by being asked, but neither one is ever holding both clipboards at once.

This is what people mean by "isolation by construction."
The language handed you this isolation the moment you defined two actors instead of one, not because you wrote careful code or remembered a convention.
A bug in the `Bike`'s status logic cannot corrupt the station's list because it can't reach the list.
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

A `DockingStation` actor that keeps a list of references to `Bike` actors.
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

The `DockingStation` has no `:return` handler.
A rented bike never comes back, which is a bug a real bike share would notice on day one.
You can write it yourself right now if you want the practice; it's the mirror of `:dock`.

The bigger thing: this chapter has one `DockingStation` and a couple of bikes.
A real bike share has dozens of stations across a city, and somebody has to manage them all.
That's Chapter 4, where you'll meet supervision trees and Blimp's dotted naming convention.
You'll see how the runtime groups actors under shared parents, and you'll use that grouping to decide what should crash together and what shouldn't.

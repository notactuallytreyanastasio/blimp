# Chapter 4: Zoom out

Three chapters in, you have a `Bike` that knows its own mind and a `DockingStation` that holds a list of bikes and hands them out.
That's a working two-actor system, but it's still small.
A real bike share has dozens of stations across a city, and somebody has to be able to ask the whole system a question.
"How many bikes are out right now?"
"Which stations have any bikes left?"
At three actors your program is a flowchart; at thirty it's a network, and the way you ask a network a question is by giving the network its own actor.

This chapter builds that actor.
A `BikeShare` that holds a list of `Station` references, registers new ones as they come online, and fans questions out to all of them at once.

The new language ground in this chapter is anonymous functions and the three list builtins that take them as arguments: `map`, `filter`, and `reduce`.
By the end you'll have seven tests passing, a parent actor that asks every child the same question and combines the answers, and a feel for what one level of zoom looks like in an actor system.

## Why a parent at all?

You could imagine writing the system-wide questions at the top level of a script.
A loop over every station, a counter, a print at the end.
That works for ten lines and stops working as soon as you want the same question asked from somewhere else, or asked many times, or asked in response to a message arriving from outside.

So we put the coordination inside an actor.
The `BikeShare` actor holds a list of `Station` references the same way a `Station` (back in chapter 3) held a list of `Bike` references.
When you want to know the total bike count, you send `:total_bikes` to the `BikeShare`, and the `BikeShare` is the one that asks each station for its count and adds them up.

This is the same shape as chapter 3 with the names shifted up.
A `Station` is to a `Bike` as a `BikeShare` is to a `Station`.
What's new in this chapter is the inside of the handler, where the parent has to *iterate* over its list of children and combine the answers.

A small note on what we're modeling.
At this zoom level the `BikeShare` doesn't care about individual `Bike` actors.
It only cares about counts: how many bikes a station has, which ones have any.
The `Station` in this chapter tracks bikes by an integer counter rather than by holding actor references.
Chapter 3 already showed how a station can hold the actual bikes; layering both at once would just hide the lesson here.

## The shape of a `BikeShare`

```blimp
actor BikeShare do
  state name: String :: "default"
  state stations: [Station] :: []
end
```

Two state fields, both shapes you've seen before.
A `String` for the name of the system.
A `[Station]` list for the stations registered to it, defaulting to empty.

What's new is going to be the handlers, specifically the ones that read every entry in the `stations` list and compute something across all of them.
That work needs a tool we haven't introduced yet: anonymous functions.

## Anonymous functions

A function in Blimp is a value, the same as an integer or a string or an atom.
You can put one in a variable, pass it as an argument, store it in state, send it to another actor in a message.

The syntax is short:

```blimp
double = fn(x: Int) do x * 2 end
double(5)              # => 10
```

`fn(x: Int) do ... end` defines a function that takes one argument named `x`, of type `Int`.
The body is the block between `do` and `end`, exactly the same shape as a handler body.
The value of the last expression in the body is the return value, again the same as a handler.

The argument list can have multiple parameters with their own types:

```blimp
add = fn(a: Int, b: Int) do a + b end
add(2, 3)              # => 5
```

Functions can capture variables from the surrounding scope.
A function that does this is called a closure, and Blimp's are closures by default.
Inside the function body, you can refer to any variable that was in scope where the function was *defined*, including state fields of the surrounding actor:

```blimp
actor Greeter do
  state prefix: String :: "hello "

  on :greet(names: [String]) do
    reply map(names, fn(n: String) do prefix ++ n end)
  end
end
```

The `prefix` inside the closure is the `Greeter`'s own state field.
When the closure runs (inside `map`, see below), `prefix` resolves to the value the actor had when the closure was created.
You don't need to pass it in, the closure carries it along.

## `map`, `filter`, `reduce`

Three list builtins that take a function as their last argument.

`map` applies the function to every element and returns a new list of the results:

```blimp
map([1, 2, 3], fn(x: Int) do x * 2 end)   # => [2, 4, 6]
```

`filter` keeps the elements where the function returns truthy:

```blimp
filter([1, 2, 3, 4, 5], fn(x: Int) do x > 2 end)   # => [3, 4, 5]
```

`reduce` folds a list down to a single value, using a starting value and a two-argument function:

```blimp
reduce([1, 2, 3, 4], 0, fn(acc: Int, x: Int) do acc + x end)   # => 10
```

The first argument to the reduce function is the accumulator (the value built up so far), the second is the current element.

These three are enough to express most of what a `for` loop would handle in another language.
Blimp doesn't have a `for` keyword, and you won't miss it for the kinds of work this chapter does.

## What a session looks like

Before you fill in any handlers, look at how the finished `BikeShare` is used:

```blimp
brooklyn = spawn BikeShare, name: "brooklyn"

fulton = spawn Station, name: "fulton"
atlantic = spawn Station, name: "atlantic"

brooklyn <- :open(fulton)
brooklyn <- :open(atlantic)

fulton <- :add_bike
fulton <- :add_bike
atlantic <- :add_bike

brooklyn <- :total_bikes      # => 3
brooklyn <- :busy_stations    # => ["atlantic", "fulton"]
```

Three things showing up here for the first time.

`brooklyn <- :open(fulton)` registers a station with the bike share.
The bike share now holds a reference to `fulton` in its own state.
After both `:open` calls, the bike share's `stations` list has two entries.

`brooklyn <- :total_bikes` is the first handler that goes outside the bike share.
The bike share has zero direct knowledge of how many bikes are at each station.
To answer the question, the bike share has to send `:count` to each station and add the replies up.
That's the fan-out, and it's the chapter's main idea.

`brooklyn <- :busy_stations` is the same shape with a filter step.
"Which stations are not empty?"
The bike share asks each station for its count, keeps the ones with at least one bike, and replies with their names.

Open `exercises/ch04_zoom_out/01_bikeshare.blimp` in the editor on the right.
You'll see a `Station` with a `:count` and an `:add_bike` already wired, and a `BikeShare` with three `:TODO` handlers.
Two tests already pass (`name`, `starts with zero stations`).
The other five are red until you fill in the handlers.

## Step 1: fill in `:open`

Exactly the shape as `:dock` from Chapter 3, with the names shifted up one level: a typed message arg holding a `Station` reference, a cons onto the `stations` list, a `:become`, a `reply :ok`.
Nothing new.

**Your task:** in the editor, fill in `on :open(s: Station)`.
"open replies :ok" and "open registers the station" should both go green, leaving three.

## Step 2: `:total_bikes`

Two builtins, two closures, one binding, one reply.
Build it up from the pieces.

The summing pattern with `reduce`, on a list of integers you already have:

```blimp
reduce([2, 1, 7], 0, fn(acc: Int, n: Int) do acc + n end)   # => 10
```

The transform pattern with `map`, on a list you already have:

```blimp
map([1, 2, 3], fn(x: Int) do x * 10 end)                    # => [10, 20, 30]
```

The new move in this chapter is a closure that *sends a message* instead of doing arithmetic.
The closure body is just code, so a `<-` works there as it works anywhere else:

```blimp
fn(s: Station) do s <- :count end
```

That function, given a station reference, sends `:count` to the station and evaluates to whatever the station replies.
Pass it to `map` over the `stations` list and you get back a list of integers, one per station.
Pass *that* list to `reduce` with `0` as the seed and an `acc + n` adder, and you get the total.

The handler is two lines: a `map` to produce the per-station counts, then a `reply` whose value comes from a `reduce` over those counts.

A lot happens in those two lines.
One outer message in, a `map` of N synchronous sends to children, a fold, one reply.
The whole exchange is synchronous from end to end, which is why you can write it as if it were a list comprehension instead of as a callback nightmare.
For ten or twenty stations this is fine; for thousands you'd want non-blocking sends, which we'll see later in the tutorial.

**Your task:** fill in `on :total_bikes`.
"total_bikes is 0 when empty" and "total_bikes sums across stations" should both go green.

## Step 3: `:busy_stations`

Same fan-out shape, swapped pieces.
The work is to keep some stations and drop the rest, then turn each survivor into its name.

`filter` is the keep-some part:

```blimp
filter([1, 2, 3, 4, 5], fn(x: Int) do x > 2 end)   # => [3, 4, 5]
```

It calls the closure on every element and keeps the ones where the closure returns truthy.
The predicate can do anything, including sending a message to an actor and comparing the reply against zero.

The "extract a field" pattern is `map` again, with a closure that sends one message and returns the reply:

```blimp
map(bikes, fn(b: Bike) do b <- :id end)
```

For `:busy_stations` you want the same shape: filter `stations` by `(s <- :count) > 0`, then map the survivors to their `:name`.

This handler is doing two passes over the same list.
A more efficient version could combine them into a single `reduce` that builds the answer in one walk.
For seven stations the difference is invisible; for seven thousand it would matter, and the same `reduce` builtin is the way out.

**Your task:** fill in `on :busy_stations`.
"busy_stations names only the non-empty ones" goes green and that's all seven.

## What you built

A small system.
A `BikeShare` actor that holds a list of `Station` references and answers questions about the whole list at once.
The questions go in as one message and come back as one reply, but the work happens in a fan-out: the `BikeShare` asks every station the same thing, gathers the answers, combines them.

Three new pieces of language ground:

1. Anonymous functions (`fn(x: Type) do ... end`), which are first-class values you can pass around like any other.
2. Closures over enclosing scope, including the actor's own state fields.
3. `map`, `filter`, and `reduce` for transforming lists, with closures as the per-element work.

The fan-out pattern you used for `:total_bikes` and `:busy_stations` shows up everywhere once a system has more than two layers.
A monitoring actor that polls every backend, a cache that needs the total bytes across all its shards, anywhere a parent owns many children and the outside world wants one number summarizing them.
Hold the children as a list, fan out a query with `map`, combine the replies with `reduce`. That's the move.

## Why this isn't supervision yet

The chapter 0 roadmap put "supervision tree" against this slot, and the network of actors you have now does sit in a tree shape, with `BikeShare` at the root and a row of `Station`s under it.
What's missing is anything that handles failure.
If a `Station` were to crash mid-`:count`, the closure would never get its reply, the handler would block forever, and the `BikeShare` would freeze.
There's nothing here that says "if a station dies, give up on that one and continue with the others."
That's supervision, and it's chapter 5.
We'll come back with `bubble`, with the `Foo.Bar.Baz` dotted-name convention, and with a way to choose what should crash together and what shouldn't.

## What's next

Chapter 5 puts the supervision in.
You'll meet `bubble` for unrecoverable failures, the dotted-name convention for grouping related actors, and the language's answer to "which set of things should restart together when one of them breaks."
The fan-out you wrote in this chapter will get its first test against a station that refuses to answer, and you'll see how Blimp handles that without freezing the rest of the system.

# Chapter 0: Why Actors?

Setup, philosophy, and what you'll build.

## The simulation

By the end of these twelve chapters you'll have a bike share running on your machine. It has real actors for bikes, stations, and riders. A live clock pushes time forward. Bikes phone home with GPS on every tick. Stations notice when a bike's been out too long and fine the rider. Districts crash and restart without taking the whole system with them. And at the end there's a dashboard with buttons you can click to watch the thing move.

Every piece gets built with failing tests first. You run them, see red, fill in a handler, see green, move on.

I picked bike share because a real bike share has all the shapes I want you to feel in an actor system: independent things with private state, containers that manage them, supervisors that restart what breaks, a clock that moves time, side characters who come and go, sensors pushing data, and policies that get applied. It's a small society, and society-shaped problems are what actors are good at.

## The mental model

Picture a dispatcher at a call center with a clipboard. On it: a list of bikes, which ones are out, who has them, which ones need a mechanic. When a call comes in to rent a bike, the dispatcher looks at the clipboard, updates it, calls back with an answer. If two calls come in at once they wait in line. One clipboard, one pair of eyes, no tangled stacks of notes from different callers.

That's the actor model.

An actor is something with private state (the clipboard) and a mailbox (the queue of callers). Nothing outside the actor touches the clipboard directly. You leave a message and wait for a reply. The actor processes its mail one at a time, in order. There's only one pair of eyes on any given clipboard at any given moment, so you never get tangled.

That's the whole idea. A lot of actors, each with their own clipboard, talking to each other by mail. No shared memory, no locks, nothing to coordinate.

The part that takes getting used to is what happens when you build a real system out of it. Your program stops being a flowchart and becomes a network, and that network has to hold a specific shape or things fall over.

## Functional core, imperative shell

The organizing idea for this whole tutorial, and for Blimp programs in general, is that most of the interesting logic is pure transformation from message and state to new state and reply. That's the functional core, and it's where testing actually works: deterministic inputs, deterministic outputs, easy to reason about.

The imperative shell is everything that touches the outside world: buttons, sockets, the wall clock, the screen. You can't really assert your way through a button click, you have to run the thing and click the button. The shell is where you drop into the REPL and play with it instead.

This tutorial follows that split. Chapters 1 through 9 are TDD: you fill in handlers, tests go green. Chapter 10 is the dashboard, which has no tests at all, just a view you run and click around in. That's on purpose, because eyeballing the parts that aren't worth testing is fine as long as you know which parts those are.

## How the exercises work

Each chapter ships with one or more exercise files at `exercises/chNN_topic/`. A file has a working actor skeleton with `:TODO` placeholders and comments telling you what each hole should do. There's a test actor at the bottom with assertions already written.

You run:

```
$ blimp exercises/ch01_first_actor/01_bike.blimp --test
```

See red. Open the file, edit, save, rerun. When all dots are green, move on.

Each exercise has a matching `solutions/` sibling. The reference answer. Try not to peek. The reason you're doing this is to build the motor memory.

## What you need

- The `blimp` binary on your PATH, or run it directly from `chunks/lang/zig-out/bin/blimp`
- A text editor
- A terminal

There's no package manager, no build step per exercise, no config file. Every exercise is one file that runs standalone.

## A note on credentials

I am a novice at programming language design and at the actor model. I've read Erlang docs and Hewitt papers, and I've ripped off ideas from Elixir and Pony and wherever else they seemed good. If you come from one of those, some things will feel familiar and some will feel a little off. Blimp is its own thing and I'm still figuring out where the edges are. If something looks wrong, it might be. File an issue.

## The roadmap

- Chapter 1: a single `Bike` actor, four handlers
- Chapter 2: guards and the free mutex the actor model hands you
- Chapter 3: actors talking to actors, a `DockingStation`
- Chapter 4: zoom out, anonymous functions, fan out from a parent actor
- Chapter 5: the supervision tree, dotted names, bulkheads, crash isolation
- Chapter 6: `Rider` as its own actor
- Chapter 7: the `Clock`, our first live loop
- Chapter 8: stale rentals and fines
- Chapter 9: GPS phoning home
- Chapter 10: the dashboard, eyeball mode
- Chapter 11: where to go next

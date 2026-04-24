# The Blimp Bike Share Tutorial

Twelve chapters that build a bike share simulation one actor at a time. Each chapter ships failing tests for you to make pass, and the last chapter pulls everything into a live dashboard you can click around in.

This is how I'd teach the actor model to someone who has heard of it and nothing more.

## What you'll have when you're done

A working bike share system with:

- Bikes, riders, docking stations, and a clock, all running as actors
- A real supervision tree with bulkheads that isolate faults
- GPS pings from bikes phoning home every clock tick
- Stale rental detection that fines riders when a bike is overdue
- A dashboard view with buttons that actually moves the system forward

The whole thing is testable except the dashboard, which is fine. That split (testable core, eyeballed shell) is how I think about Blimp programs in general.

## Chapters

| Ch | Concept | Build |
|----|---------|-------|
| [00](00-why-actors.md) | Why actors, and functional core / imperative shell | (setup) |
| [01](01-first-actor.md) | Your first actor | A single `Bike` |
| [02](02-state-and-locks.md) | State, `become`, guards, and the free lock | Double-rental refusal |
| 03 | Actors talking to actors | `DockingStation` holds bikes |
| 04 | Supervision tree | `BikeShare.Fleet.Bike.001`, dotted names |
| 05 | Bulkheads | `bubble`, `orelse`, crash isolation |
| 06 | Riders | `Rider` actor, trip history |
| 07 | The clock | `Clock` with `:tick`, live loop |
| 08 | Stale rentals | Timeouts and fines |
| 09 | GPS phone-home | `GPSTracker` collects pings |
| 10 | The dashboard | Full view, eyeball mode |
| 11 | Where to go next | Pointers and suggestions |

## Prerequisites

- The `blimp` binary built. If you cloned this repo, `cd chunks/lang && zig build` should give you `chunks/lang/zig-out/bin/blimp`
- A text editor
- That's everything

## Running an exercise

```
$ blimp exercises/ch01_first_actor/01_bike.blimp --test
```

Open the file, edit the handler bodies, save, rerun. When everything goes green, move on.

## If you get stuck

Every chapter's exercise has a matching `solutions/` file. Try not to peek until you've tried for real. The muscle you're building here comes from getting the tests green yourself.

## Feedback

Tutorials get stale. If something is wrong or unclear, file an issue on the repo.

# Blimp: A Radical Approach to Programming

*March 18, 2026*

## Why Not

Things are just different now, man. I don't work the way I used to, and I have been programming for 20 out of my 33 years on this planet. I can make shit in weeks that would have taken me years previously. I'm working on more projects than I ever dreamed of, and I'm having a lot of damn good fun doing it. The gap of idea to thing is basically "can you specify what you *really* want" and then if you can, it's made.

My boss was working on another language and I often rip people's ideas off, so I took some of the cool ideas he had and I ran with it and added a bunch of weird sauce on top and this is what I'm getting. It's a total wild take on how to work in a programming environment and goes far beyond a language. It's a language and tools and a philosophy of design that is a vast departure from anything that exists now.

I have been working with the folks behind Temper and it's really gotten my mind to expand, so I'm here to make this and try to do exactly that. Mike's work is really novel and inspiring and he has also taught me a lot. I just had my first patch merged into Temper proper after discovering a bug in the compiler's Rust backend this weekend while implementing multiplayer, agent-driven snake after writing some new IO primitives and a websocket-based network stack into the language between 1 and 5am on a Saturday just because I was pretty high and it sounded fun.

So anyways, this is Blimp. It is an experiment, you shouldn't take it seriously. But I am going to meticulously document my process here as I go because it's pretty interesting to see how this will fly. I am a pretty weird person making a pretty weird thing and this is as much art project and craft experiment as it is any real attempt at making a useful tool.

## The Magic Session

So what does this actually look like? Let me paint you a picture.

You open Blimp and you're building a programming language. Yeah, a language inside a language. I told you this was weird.

You've got a parser, a type checker, and an IR generator, and they're all actors. The parser is receiving source code as messages and spitting out ASTs. The type checker is consuming those ASTs and annotating them. The IR generator is turning annotated trees into LLVM IR. Three actors, talking to each other, and you can see all of it.

```
blimp> open Loom

  Loom (supervisor)
  ├── Parser (actor) idle
  ├── TypeChecker (actor) idle
  ├── IRGen (actor) idle
  └── TestRunner (actor) idle

blimp> cd Parser
  [inside Loom.Parser]
```

But here's where it gets interesting. You don't just have your REPL. You have agents. And they're doing things while you think.

You start writing a new parsing rule for match expressions. As you type, two things happen at once. First, autocomplete suggestions are streaming in, built from how you've written every other parser rule in this project. It saw your pattern. `tokenize |> parse_something |> build_ast`. Hit `tab` and the suggestion fills in, placeholders and all.

But at the same time, the agents are leaving annotations on your code. Google Docs style, right there inline. The scout noticed you're not handling nested match expressions. The explorer found three different approaches to match parsing and left a note comparing them. These aren't in your way. They're just there, little markers in the gutter. Hit `shift+tab` and they expand so you can read them.

And meanwhile, you flip to the multiplexer and there are three agents working in parallel. One is exploring what happens if you use a PEG grammar for this. Another is stress testing your existing parser with edge cases it generated. A third is reading your IR output and checking that the types line up.

You drop into explorer and it's got a working PEG prototype already. It didn't wait for you to ask. It saw you were working on match expressions and just went and tried an approach. And it remembers last Tuesday when you rejected a recursive descent approach for the if-expression parser. It's not going to suggest that again. Its decision graph has that whole history. You look at the diff between your current parser and what explorer came up with, leave a comment saying "I like the precedence handling but keep my tokenizer," and pop back out. Explorer takes the note, revises, and records why in its graph.

That's the thing. You're not writing every line. You're not delegating everything either. You're steering. You look at diffs. You leave comments. You write the tricky bits by hand and let the agents handle the scaffolding. It feels like pair programming with a team that never sleeps, has read every PL paper ever written, and actually remembers what you told them last week.

And because everything is an actor, you can send your parser a test case right from the REPL and watch the AST come out the other side.

```
blimp> Parser <- :parse("match x { 1 -> :one, 2 -> :two }")
=> %AST{type: :match, subject: :x,
     arms: [{1, :one}, {2, :two}]}

blimp> Parser @ t1 <- :parse("match x { 1 -> :one }")
=> error: :match not recognized
   (rule didn't exist at t1)
```

That last bit is the time travel. You sent a match expression to the version of the parser from before you added match support, and it correctly failed. The history is right there. You can scrub through every version of your parser and see exactly when each feature started working.

## Your Hands, Their Eyes

So here's the thing about working with AI right now. You either hand it everything and hope for the best, or you write everything yourself and it's like the AI isn't even there. And even when you do hand it off, you spend so long reviewing the output that you might as well have written it yourself. The review takes as long as the writing used to. That's the dirty secret nobody talks about. Both approaches suck.

Blimp sits in the middle. You are always the one writing code. But you're not writing alone. The agents are watching what you type, and they have opinions. Not in an annoying way. In a useful way.

There are two channels and they never step on each other. When you're typing and a suggestion appears, you hit `tab` to accept it. That's autocomplete. The agents are watching your patterns, they know what you tend to write next, and they're offering to fill it in. Including the `_` placeholders in your pipes so you don't have to remember which argument position you need.

But the other channel is the interesting one. As you write, agents are leaving annotations on your code. Little marks in the gutter, like comments in a Google Doc. The scout noticed a potential nil. The explorer found a paper that's relevant to what you're doing. The tracer sees that this function is called by three other actors and one of them passes bad data sometimes. You don't have to look at any of this. But when you want to, you hit `shift+tab` and the annotations expand inline.

And here's the thing that makes this different from every AI coding tool that exists right now. These agents remember. Not just inside a session but across sessions, across days, across weeks. The scout doesn't warn you about the same nil risk twice after you've already decided to handle it. The explorer doesn't re-suggest approaches you've already rejected. They have living memory. Every interaction, every decision, every "good catch" and every "nah that's fine" gets recorded in their decision graph and it sticks.

This is how you actually work in Blimp. You write a few lines. You glance at the annotations. You accept a suggestion or you don't. You pull up a diff that an agent prepared and leave a comment on it saying "this part is good, that part is wrong, try again." The agent revises and shows you another diff. You're not writing prompts. You're not copy-pasting from a chat window. You're looking at code, reacting to code, and writing code. It just happens that some of that code was drafted by something that isn't you.

## The Multiplexer

Let me be more specific about what the multiplexer actually is because I keep talking about it.

It's a grid. Each cell is an agent's workspace. You see a little preview of what they're doing, their status, how deep their reasoning tree is. Your REPL is one of the cells. You're not special, you're just the one with the final say.

Every agent has a living memory. Not just a context window that evaporates when the session ends. An actual persistent decision graph that tracks what it noticed, what it tried, what worked, what didn't. When you come back tomorrow, the scout still remembers it found that nil risk yesterday. The explorer still has its PEG prototype from last week. The reasoning doesn't disappear. It accumulates. And these graphs can merge when agents agree on something and diverge when they're exploring different directions. Your graph is there too, tracking every decision you made and why.

When you want to get closer to what an agent is doing, you drop in. Now you're looking at their full REPL. Their history. Their annotations. Their decision tree on the right side, showing you every step of how they got to where they are. You can talk to them here. You can ask questions. You can tell them to change direction. When you're done you type `back` and you're looking at the grid again.

The semantic diff viewer works the same way. When an agent prepares a change, you're not looking at a text diff with green and red lines. You're looking at a structural diff. It knows that a function moved, not that 30 lines were deleted and 30 lines were added somewhere else. It knows that a type changed, and it can show you every callsite that's affected. And just like everything else in the multiplexer, you can comment on it, annotate it, tell the agent what to fix. The diff viewer isn't a separate tool, it's just another pane in the grid.

The reason this is what we build first is because everything else is just a REPL inside it. The code editor is a REPL. The diff viewer is a REPL. The agent workspaces are REPLs. If we get the multiplexer right, we get the container that holds all the other pieces. The rest is filling in the boxes.

And because we're targeting WASM and shipping this in a browser, the multiplexer is basically a web app. It's a grid of panes. Each pane is a little terminal. The agents are processes running in the background. We compile to LLVM IR, target WASM, and the whole thing runs in a tab. You send someone a URL and they're looking at your multiplexer, your agents, your running system. That's collaboration without git.

And pretty soon this design journal is going to get very meta, because we're going to be building Blimp using the multiplexer we built for Blimp. Dogfooding it from day one. The tool builds the tool.

## Supervisors All the Way Down

Okay so let's talk about how the code is actually organized because this is where Blimp does something that no other language does.

In Erlang and Elixir you have this split brain thing going on. Your code lives in modules and your running processes live in supervision trees and they have nothing to do with each other. You can have a module called `Checkout` that spawns processes supervised by something called `PaymentSupervisor` and there's no relationship between the names or the structure. You end up maintaining two mental maps of your system and they never line up.

In Blimp, they're the same thing. Your code structure IS your runtime structure. When you write `Shop.Checkout.TaxCalculator`, that's where the code lives, that's where the process runs, and that's what supervises it. One tree. One map. One thing to navigate.

An actor that contains other actors is automatically a supervisor. You don't configure it separately. You don't import a supervision behavior. If it has children, it supervises them. If a child crashes, the parent restarts it. Sane defaults, and the agents will tell you what those defaults are if you care.

This is why "cd into a module" works. When you type `cd Shop.Checkout` in the REPL, you're not just scoping to a namespace. You're entering a supervisor that contains live actors. You can see them, talk to them, inspect their state. The code and the runtime are the same place.

And because supervisors are namespaces, sibling actors just know about each other. `TaxCalculator` doesn't need a PID or a registry lookup to talk to `PaymentProcessor`. They're siblings. They share a supervisor. They can just use each other's names.

But here's where it gets really interesting. A supervisor isn't just a container. It's an actor too. It has state. It handles messages. The `Checkout` supervisor doesn't just babysit `TaxCalculator` and `PaymentProcessor`. It IS the checkout system. It receives `:add` and `:checkout` messages and it coordinates its children to get the work done. The organizational unit and the computational unit are the same thing.

Think about what this means for the REPL. You open your project and you see a tree. That tree is simultaneously your file system, your module hierarchy, your supervision tree, and your runtime topology. You navigate it like a directory. You interact with it like a running system. There is no gap between "how is this organized" and "how does this run" because the answer to both questions is the same tree.

And think about what this means for the agents. When the scout is analyzing your code, it doesn't need to figure out the relationship between your module structure and your process architecture. There is no relationship to figure out. They're the same thing. The scout can walk the tree and know exactly which actor supervises which, who talks to who, and what happens when something crashes. The living memory of every agent in the system is organized around this same tree.

This also means that when you look at an actor's decision graph in the multiplexer, you can see it in context. You're not just looking at the scout's thoughts about `TaxCalculator` in isolation. You can zoom out and see how `TaxCalculator` fits into `Checkout` which fits into `Shop`. The reasoning tree and the supervision tree mirror each other. Context is never lost because the structure gives it to you for free.

Erlang people will tell you this is an anti-pattern. They'll say you shouldn't put business logic in supervisors. And they're right, in Erlang, because Erlang's supervisors and business logic actors have different callback contracts and different responsibilities. But Blimp doesn't inherit that constraint. In Blimp, an actor is an actor. Some actors have children and some don't. The ones that have children automatically supervise them. There's no separate concept to learn.

## Why the Web

Blimp compiles to LLVM IR and targets WASM. That means it runs in a browser.

I know what you're thinking. "A programming language that runs in a browser? That sounds like a toy." But think about what we just described. The multiplexer is a grid of panes. Each pane is a terminal. The agents are background processes. The REPL is an interactive session with a side panel. That's a web app. That's literally just a web app.

And honestly, the web is where I live. I grew up on it. I've spent my whole career on it. From janky PHP sites as a teenager to Elixir and Phoenix and LiveView, the web has been home the entire time. It has a soft spot in my heart and I'm not going to pretend otherwise. If I'm making something new, I'm making it for the web first. That's just who I am.

The browser is the one runtime that everyone already has. No install. No dependencies. No "works on my machine." You open a URL and you're in your Blimp environment. Your actors are running. Your agents are thinking. Your decision graphs are right where you left them.

And here's the thing that makes this more than just convenience. Collaboration becomes trivially easy. You send someone a URL and they're looking at your running system. Not a screenshot. Not a recording. The actual live multiplexer with your actual agents and their actual decision graphs. They can drop into the explorer's REPL and see what it's been working on. They can look at the tracer's view of your actor tree. They can leave annotations on your code that show up in your gutter the next time you glance at it.

That's not git. That's not pull requests. That's two people looking at the same living system at the same time.

We're compiling through LLVM so we're not locked into WASM forever. The same frontend that targets `wasm32` today can target `x86_64` or `aarch64` tomorrow. The desktop version of the multiplexer, the standalone editor, the semantic diff viewer as its own application, all of that is just a different compile target. Same language. Same compiler. Same IR. Different backend.

But the web comes first because the web is where you can share things, and sharing is how this gets interesting.

## What's Next

So that's Blimp. Or at least that's what Blimp wants to be. Right now it's a bunch of ideas in a design journal and a decision graph and a lot of enthusiasm.

Here's what I actually need to figure out:

The multiplexer comes first. It's the shell that holds everything. Before I can build a language I need a place to build it in. That means a web-based grid of panes that can host REPLs, diff viewers, and agent workspaces. That's the first real piece of code.

After that it's the language itself. The syntax is starting to take shape. Actors with `become` for state transitions. Pipes with `_` placeholders. Pattern matching everywhere. Supervisors that are namespaces. But there's a lot I haven't figured out yet. What about pure functions and data types that aren't actors? What's the type system look like? How do you define protocols and interfaces? Where do plain old helper functions live?

And then there's the agent protocol. How are agents defined? Are they written in Blimp? Are they special actors with a standard interface? How do their decision graphs actually get persisted and queried? How does the merge logic work when two agents reach contradictory conclusions?

I don't have answers to any of this yet. That's the point. This is an experiment. I'm going to build it in public, document every decision, and see what happens. The next post will probably be about the multiplexer because that's what I'm building next.

If any of this sounds interesting to you, stick around. It's going to be a weird ride.

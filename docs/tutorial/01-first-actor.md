# Chapter 1: Your First Actor

By the end of this chapter you'll have a single Bike that can tell you its id, tell you its status, and flip between rented and available when asked.
Four handlers, four tests, walked through one small piece at a time.

If you've never used an actor-model language, this chapter goes slowly on purpose.
If you've written Erlang or Elixir or Akka, skim the concept boxes and go to the exercise steps.

## What is an actor?

An actor is a small self-contained thing made of three parts: some private state that nothing outside can touch directly, a mailbox queue of messages other parts of the system are sending it, and a set of handlers that run one at a time, each pulling a message off the mailbox and doing something with it.
That's the whole model, and the rest of this chapter is about one concrete example of it.

Blimp's actors are Carl Hewitt's actors.
In 1973 Hewitt wrote a paper proposing a computing model where every piece of state is owned by some small independent process, and the only way to do anything with that state is to send the process a message and wait for it to reply.
The process reads its mail one message at a time.
It can compute things, change itself, and send messages to other actors.
Everything Erlang, Elixir, Akka, Pony, and Blimp do with actors falls out of those three moves.

The word Hewitt emphasized in the original paper, which got watered down in some descendant languages, is "become."
An actor doesn't mutate its state, it *becomes* its next state.
You start with one version of the actor, you process a message, and when you're done the actor has become a new version.
The old version isn't current anymore, though it still existed and the runtime remembers it.
Blimp keeps this word because Blimp keeps the model.

Blimp's surface looks a lot like Ruby, with `do/end` blocks, optional parens, and readable almost-English sentences.
The data model is Elixir's: immutable values, pattern matching everywhere, pipe operators, atoms.
You'll feel both influences in these chapters.
If you haven't used either language, don't worry, everything you need gets introduced as we go.

## The shape of a Bike

The smallest Bike actor that means anything is five lines of shell, no handlers yet:

```blimp
actor Bike do
  state id: String :: "unknown"
  state status: Atom :: :available
end
```

Three pieces worth walking through.

### `actor Bike do ... end`

Defines an actor template.
A template, not a live instance.
The block between `do` and `end` is where state fields and message handlers go.
When you eventually write `spawn Bike` to bring a Bike to life, this template is what the runtime clones.

Names starting with a capital letter are types.
Lowercase names are variables and functions.
The uppercase `Bike` tells Blimp you're declaring a type of actor, not a particular bike.

### `state id: String :: "unknown"`

A state field has three parts: a name (`id`), a type (`String`), and a default value (`"unknown"`).
Both the type and the default are **required**, and you'll see that pattern repeated throughout the tutorial.
Two reasons.

First, the type gives the runtime and the reader the shape of the actor at a glance.
You can't spawn a Bike and then find out three function calls later that its `id` is actually an integer.

Second, the default means you can always write `spawn Bike` and get a usable actor with zero arguments.
No constructors, no "I forgot to initialize this field" bugs.
An actor is a thing that starts working the moment it's born.

Notice the `::`.
Those are two colons, Blimp's default-assignment operator.
It has to be two colons because a single colon already means something else in Blimp: a single colon in front of an identifier makes it an atom.
To keep atoms readable without ambiguity, default assignments got their own operator.

### `state status: Atom :: :available`

Same shape as before.
Here the field is typed as `Atom` and its default is `:available`.

**Atoms** are Blimp's interned symbols.
They look like `:rented`, `:broken`, `:ok`.
They're the same thing as Ruby symbols or Elixir atoms: a constant whose identity is its name, compared by identity rather than content, cheap at runtime, and perfect for things like states, tags, and message names.

Atoms show up everywhere in Blimp.
The messages you send are atoms, the states an actor can be in are usually atoms, replies often start with atoms like `:ok` and `:error`.
Get comfortable with them early.

The skeleton above has shape but no behavior, which is what handlers are for.

## Step 1: fill in `on :id`

Open `exercises/ch01_first_actor/01_bike.blimp` in the editor on the right.
The file has the skeleton above plus four handler stubs, each of which currently replies `:TODO` and does nothing else.
You'll fill them in one at a time, watching tests turn green as you go.

A handler looks like this:

```blimp
on :id do
  reply id
end
```

`on :id do ... end` means "when I receive the message `:id`, run this block."
Inside the block, state fields are in scope as ordinary variables.
`id` in the handler body is the same `id` you declared as a state field.
You don't need `self.id` or `this.id`, just `id`.

`reply id` sends a value back to whoever sent the message.
Every handler can call `reply` to produce a return value.
If you don't call `reply` you still get a default reply (nil or the next state depending on context), but being explicit is clearer to read and easier to test.

Before you fill it in, look at what using a Bike actually looks like in a program:

```blimp
b = spawn Bike, id: "b-001"
b <- :id           # => "b-001"
```

Two things are happening on the first line.

`spawn Bike` creates a live instance of the Bike template, and `, id: "b-001"` overrides the `id` state field for this specific bike.
Any state field can be overridden at spawn time.
If you skip the override, you get the defaults you declared; `spawn Bike` with nothing after it gives you a Bike whose id is `"unknown"` and status is `:available`.

The variable `b` holds a reference to the actor, not the actor itself.
Actors don't live in your expression's scope, they live in the runtime registry.
When you write `b <- :id`, the runtime looks up `b`, finds the actor, delivers the `:id` message, and gives you the reply.
Two variables can point at the same actor, and an actor can outlive the variable that first named it.

`<-` is the send operator.
Read it as "send this message to that actor, wait for the reply, and evaluate to the reply."
In today's Blimp, every send blocks until the reply comes back.
That's a real constraint of the current runtime and we'll talk about its consequences in later chapters when they start mattering.

**Your task:** in the editor, find `on :id`, change `reply :TODO` to `reply id`, click Run Tests.
The test called "reports its id" should go green.

## Step 2: fill in `on :status`

Same pattern, different field.
Also an atom this time instead of a string, but that doesn't change how you write the handler.

```blimp
on :status do
  reply status
end
```

**Your task:** replace the `:TODO` in `on :status` with `reply status`.
Run tests.
"starts available" should now also be green, and that's two handlers down.

## Why `become` exists

The next two handlers will change the bike's state.
Before you write them, stop for a minute and think about what "change" even means here.

In a language with ordinary mutable variables, changing the bike's status would be one line:

```python
bike.status = "rented"
```

You mutate the field.
The old value is overwritten.
If anything else was looking at that field, it sees the new value next time it reads.

Blimp doesn't do this.
Actor state is immutable.
What you CAN do is declare what the actor is going to become next:

```blimp
become status: :rented
```

Read it out loud.
"Become: status is rented."
A bike that had `status == :available` a moment ago is now a bike that has `status == :rented`.
The old version still exists in the actor's history, but from this line on, the new version is the one the runtime hands to any incoming message.

Two reasons Blimp is built this way.

The first reason is that it's Hewitt's original formulation.
In the 1973 paper, an actor's response to a message is two things: a reply to send back, and the actor the actor should *become* next.
The handler's output is an entire next-actor, not a diff against the current one.
Actors are values in a sequence, and each handler's job is to produce the next value in that sequence.

The second reason is that immutable snapshots give you things imperative state does not.
In Chapter 2 you'll see how `become` plus Blimp's mailbox gives you mutual exclusion without any locks.
Later in the tutorial, the chain of `become` calls becomes a natural history of the actor, and you'll be able to browse past snapshots, send them messages, see what they would have replied.
Time-travel debugging comes for free once the actor is built out of snapshots in the first place.

For now, the rule is simple.
Inside a handler, if you want the actor to change, call `become` with the fields you want to update.
Anything you don't list stays the same.

## Step 3: fill in `on :rent`

Here's what the `:rent` handler looks like when it's done:

```blimp
on :rent do
  become status: :rented
  reply :ok
end
```

Three beats, and this rhythm is the one Blimp's design doc calls out as **compute, transition, communicate**.
The first beat (compute) is empty in this handler, we have nothing to calculate.
The second beat is `become status: :rented`, which declares the next state.
The third beat is `reply :ok`, which sends the atom `:ok` back to whoever sent the `:rent` message.

`:ok` is a Blimp convention.
It's the atom you reply with when a handler did what was asked and there's no other meaningful value to hand back.
You'll see `:ok`, `{:ok, something}`, `:error`, and `{:error, reason}` all over Blimp code.
Starting a reply with an atom lets callers branch on success or failure with a pattern match, which is exactly how you'd do it in Elixir.

**Your task:** replace the `on :rent` body with a `become` and a `reply :ok`, save, rerun the tests.
"rent flips status to :rented" should go green, leaving one handler left.

## Step 4: fill in `on :return`

The `:return` handler is the mirror of `:rent`, going the other direction.

```blimp
on :return do
  become status: :available
  reply :ok
end
```

Nothing new to learn, it's the same pattern with a different target value.

**Your task:** fill it in.
All four tests should go green.

## What you built

A Bike actor with four handlers.
You can ask it for its id, ask it for its status, rent it, and return it.
It remembers what happened, because the `become` inside `:rent` committed a new version of the actor's state, and the next `:rent` or `:status` message reads that new version.

There's a bug in it, though.
Watch what happens if you send two `:rent` messages in a row:

```blimp
b = spawn Bike, id: "b-001"
b <- :rent
b <- :rent
```

Nothing stops the second `:rent` from succeeding.
Try it in your editor if you want to see.
After two `:rent` messages, the status is still `:rented` and the reply is still `:ok`, which means the bike has effectively been rented twice.
In a real bike share, that's a problem.
Two people would try to ride the same bike.

Fixing that bug is Chapter 2, and the fix is where the actor model starts earning its keep: you'll add a guard to `:rent` so it only succeeds when the bike is available, and you'll discover that the guard gives you thread-safe rental refusal for free, with no locks anywhere.

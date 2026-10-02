# Initial Charter: Blimp

Blimp is a new type of programming language.

It works with a few concepts that are met for people who still want to _craft_ software but are working in modern paradigms.

Some features of Blimp:

1. REPL driven development. An agent is always listening and offering input/insight and analyzing your code. You can also guide the agent.

2. Actor model. It is a process oriented (think Erlang) actor model with simple syntax to allow for deep interactivity.

3. Highly contextual data awareness. It can time travel debug. It can tell you what variables are in scope and their values. It can provide documentation on the fly. It's agents have living memory.

This is just the start with some higher order ideas, but imagine this:

You open the REPL and your project is loaded, an e-commerce site.

You have a bug in the checkout system.

First, you dispatch an agent to begin working on it, by "cd-ing" into the module that handles checkout.

Now, the system has loaded all this code and is a live, acting system via simulated activity from the working AIs inside it that help you resemble the real world.

You begin to type out some commands to the model who will be assisting you, but first see a bug in some loop.

You start to type, another agent sees your input and offers autocomplete suggestions.

As you do this, another agent is analyzing all this and crawling the language tree to see if it has impact on any other state of any otehr system as you go and modify things to add your fix.

Then you flip to the multiplexer which shows you all these agents working together and can talk to or command any one.

Where do we even start with something like this? Well, lets see and begin.

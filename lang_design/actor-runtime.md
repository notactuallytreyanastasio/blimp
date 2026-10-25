# Actor Runtime: Memory, Scheduling, and the Registry

> The runtime is the language. Code structure is runtime structure. The namespace is the supervision tree is the blast radius.

## The Three Pillars

1. **Per-actor arenas with Perceus RC** -- each actor owns its memory, `become` reuses in place, actor death is O(1)
2. **Preemptive scheduling via reduction counting** -- BEAM-style, no actor can starve others
3. **Actor registry** -- global lookup for message routing, supervision, and lifecycle

## Memory Model

### Per-Actor Arenas

Every actor gets its own arena allocator. All allocations during handler execution come from this arena. This gives us:

- **Cache locality** -- an actor's working set is contiguous in memory
- **O(1) actor death** -- free the entire arena, no individual frees, no GC coordination
- **Isolation** -- no actor can touch another actor's memory, period

```
Actor A's arena:          Actor B's arena:
+------------------+     +------------------+
| state: count=5   |     | state: name="bob"|
| locals: x=10     |     | locals: y=42     |
| temp: [1,2,3]    |     | temp: %{k: v}    |
+------------------+     +------------------+
     ^                         ^
     |                         |
  only A can                only B can
  read/write this           read/write this
```

### Perceus Reference Counting

Inside an actor's arena, values are reference counted using Perceus RC. The key insight: **if the refcount is 1 (unique owner), mutate in place instead of copying.**

```
on :increment do
  become count: count + 1   # count has refcount 1 -> rewrite in place
  reply count + 1            # count still has old value in this scope
end
```

What happens at the instruction level:

1. `count` has refcount 1 (only the state struct points to it)
2. `become` sees refcount 1, calls `rc_reuse` instead of `rc_alloc`
3. The integer is overwritten in the same memory location
4. No allocation, no free, no GC pause

When refcount > 1 (value is shared within the actor):

```
on :store(item) do
  x = item              # item now has refcount 2 (param + x)
  become items: [item | items]  # item refcount 3 (param + x + list)
  reply x                # x still valid, points to same memory
end
# after handler: param dropped (rc--), x dropped (rc--)
# item now refcount 1 in the list, eligible for reuse next time
```

### Message Boundary: Deep Copy

When a value crosses an actor boundary (via `<-`), it is **deep copied** into the receiving actor's arena. The sender's reference stays in the sender's arena.

```
# In Actor A's arena:
result = Counter <- :get   # Counter replies with value from its arena
                           # Runtime deep-copies the reply into A's arena
                           # result now lives in A's memory
```

**Actor references are NOT copied.** They are lightweight handles -- just an atom ID that resolves through the registry. Sending an actor reference in a message is like sending a PID in Erlang: cheap, just an integer.

```
# Sending an actor ref costs nothing:
Logger <- :set_target(Counter)   # Counter is just an atom ID, no copy

# Sending data costs a copy:
Logger <- :log(big_list)         # big_list is deep-copied into Logger's arena
```

### What Gets Copied at Boundaries

| Type | Copy cost | How |
|------|-----------|-----|
| Int, Float, Bool | Trivial | Value copy (8 bytes) |
| Atom | Trivial | ID copy (4 bytes) |
| Nil, Hole | Trivial | Tag only |
| String | O(n) | Allocate in target arena, memcpy bytes |
| List | O(n) | Recursive deep copy of elements |
| Tuple | O(n) | Copy each element |
| Map | O(n) | Copy each key-value pair |
| Actor ref | Trivial | Copy atom ID (4 bytes) |

**Design rule: send small messages.** If you need to share large data, put it in a data actor and let consumers query it.

## Preemptive Scheduling

### Reduction Counting

Every operation costs one reduction. After N reductions (default 4000), the scheduler suspends the actor and runs the next one in the queue.

The BEAM does exactly this. It's how Erlang guarantees soft real-time properties -- no process can hog the CPU for more than ~1ms (at ~4M reductions/second, 4000 reductions is about 1ms).

### Where Yield Checks Go

In the tree-walking interpreter (REPL):
- Every call to `eval()` decrements the reduction counter
- When it hits 0: save evaluator state, yield to scheduler, resume later

In compiled code (LLVM IR):
- Codegen inserts a reduction check at:
  - Top of every handler body
  - Top of every loop iteration
  - Before every function call
  - Before every message send
- Each check is a conditional branch: `if (reductions <= 0) goto yield_point;`

```
; LLVM IR for a yield check
%reds = load i32, i32* @thread_reductions
%exhausted = icmp sle i32 %reds, 0
br i1 %exhausted, label %yield, label %continue

yield:
  call void @blimp_yield()    ; save context, switch to next actor
  br label %continue

continue:
  %new_reds = sub i32 %reds, 1
  store i32 %new_reds, i32* @thread_reductions
  ; ... actual instruction ...
```

### Context Save: Full Stack Snapshot

When an actor yields, we save:
- The instruction pointer (which AST node / which LLVM basic block)
- The entire local variable stack
- The current scope chain
- The reduction counter

On resume, we restore all of it and continue from exactly where we left off.

For the interpreter, this means the `Evaluator` struct itself IS the context. We just store a pointer to it and swap to a different evaluator.

For compiled code, this is trickier -- we need to use Zig's `async`/`suspend` or setjmp/longjmp to capture the native stack. The Zig `async` model is actually perfect: each actor runs as a Zig async frame, and `suspend` saves the full stack automatically.

### Run Queue: FIFO

Simple FIFO queue of runnable actors. The scheduler:

```
loop:
  actor = run_queue.dequeue()
  if actor == nil: sleep or poll I/O
  actor.reductions = 4000
  resume(actor)
  // actor ran until it yielded or completed handler
  if actor.status == :waiting:
    // actor is blocked on message receive, don't re-queue
  else if actor.status == :runnable:
    run_queue.enqueue(actor)  // back of the line
  else if actor.status == :dead:
    free(actor.arena)         // O(1) cleanup
```

Actors enter the run queue when they receive a message. They leave when their mailbox is empty and they're waiting for the next message.

### WASM Considerations

WASM has no threads, no `async`/`suspend` in the traditional sense. Options:

1. **Compile each actor as a state machine** -- instead of suspending a stack, transform the handler into a state machine with explicit continuation points. Like C# async/await compilation. This is the most portable approach.

2. **WASM stack switching proposal** -- the WebAssembly stack switching proposal (Phase 3) would give us native coroutine support. Not widely available yet but coming.

3. **setTimeout(0) for browser** -- yield to the browser event loop between actor slices. This keeps the UI responsive but adds latency.

For now, we target native (aarch64) with Zig async. WASM can come later with the state machine approach.

## Actor Registry

### Why Not Just Variables

Right now, actors are values in the environment. `Counter` is a variable that holds an `ActorInstance`. This is wrong because:

- Two scopes can shadow the same actor name
- No global lookup for message routing
- Can't spawn multiple instances
- Supervision needs to enumerate all actors
- Actor references in messages need stable resolution

### The Registry

A global, flat map from actor name (atom ID) to actor metadata:

```
Registry = %{
  :Counter => %ActorEntry{
    id: 1,
    arena: *Arena,
    state: *State,
    handlers: *HandlerTable,
    mailbox: *Mailbox,
    status: :idle | :running | :waiting | :dead,
    supervisor: ?AtomId,     # parent actor name
    children: []AtomId,      # supervised actors
    restart_strategy: :permanent | :temporary | :transient,
  },
  :"Shop.Checkout" => %ActorEntry{ ... },
  :"Shop.Inventory" => %ActorEntry{ ... },
}
```

### Registration

When you define an actor, it registers in the registry:

```
actor Counter do        # Registers :Counter in registry
  state count: Int :: 0 # Allocates arena, initializes state
  on :increment do ...  # Stores handler in handler table
end
```

The variable `Counter` in the environment becomes a lightweight handle (just the atom `:Counter`) that resolves through the registry for message sends.

### Message Routing

```
Counter <- :increment
```

1. Resolve `Counter` to atom ID in the environment
2. Look up atom ID in the registry -> get `ActorEntry`
3. Deep copy message args from sender's arena into a message struct
4. Enqueue message in the actor's mailbox
5. If actor status is `:waiting`, move to run queue
6. Return (for sync sends: block sender until reply arrives)

### Supervision

The dot notation in actor names defines the supervision tree:

```
actor Shop do ... end              # root supervisor for Shop.*
actor Shop.Checkout do ... end     # supervised by Shop
actor Shop.Inventory do ... end    # supervised by Shop
```

When `Shop.Checkout` bubbles:
1. Registry looks up `Shop.Checkout`'s supervisor: `Shop`
2. Registry looks up `Shop`'s children: `[Shop.Checkout, Shop.Inventory]`
3. Bubble strategy (CascadeBubble) says: restart all children
4. Registry kills `Shop.Checkout` and `Shop.Inventory` (free arenas)
5. Registry re-initializes both from their definitions

### Actor Lifecycle

```
:unregistered -> :registered -> :idle -> :running -> :idle -> ... -> :dead
                                  |                    |
                                  +--- :waiting <------+
                                  (mailbox empty)
```

## Implementation Order

### Phase 1: Registry (interpreter only)
- `src/registry.zig` -- global actor registry
- Modify `eval.zig` to register actors on definition
- Message sends resolve through registry
- Actor handles in environment (atom IDs, not instances)

### Phase 2: Per-actor arenas
- Each registered actor gets its own `ArenaAllocator`
- Handler execution allocates from actor's arena
- Message boundary does deep copy between arenas
- `become` allocates new state in actor's arena

### Phase 3: Perceus RC
- Reference counting on values within an arena
- `rc_inc`, `rc_dec`, `rc_reuse` operations
- `become` checks refcount for in-place reuse
- Drop unused values when refcount hits 0

### Phase 4: Scheduler
- FIFO run queue
- Reduction counter in evaluator
- Yield when reductions exhausted
- Mailbox per actor (simple linked list to start)
- Async message sends (enqueue, don't block)

### Phase 5: Supervision
- Parent/child relationships from dot notation
- Bubble propagation through registry
- Restart strategies per handler (`bubbles()` annotation)
- Actor re-initialization from stored definitions

## Open Questions

- **Synchronous vs async sends**: should `Counter <- :increment` block until reply, or return a future? BEAM is async by default, `gen_server:call` adds sync on top. We currently do sync in the REPL which feels right for interactive use.

- **Actor spawning**: should you be able to `spawn Counter` to get a second instance? Or is each actor name unique? Right now names are unique (like named GenServers in Elixir). Multiple instances would need auto-generated names or explicit IDs.

- **Perceus RC and cycles**: reference cycles within an actor would leak. In practice, Blimp's data structures are trees (lists, maps) not graphs, so cycles shouldn't occur. But if they do, the arena free on actor death catches them.

- **Mailbox overflow**: no back-pressure yet. A fast sender can overflow a slow receiver's mailbox. BEAM doesn't solve this either (it's a known Erlang footgun). Could add mailbox size limits with configurable overflow behavior.

## Files

```
src/registry.zig    -- Actor registry (Phase 1)
src/arena.zig       -- Per-actor arena allocator (Phase 2)
src/rc.zig          -- Perceus RC operations (Phase 3)
src/scheduler.zig   -- Preemptive scheduler (Phase 4)
src/mailbox.zig     -- Actor mailbox (Phase 4)
src/supervisor.zig  -- Supervision tree (Phase 5)
```

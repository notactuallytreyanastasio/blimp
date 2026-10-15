# sched: runScheduler visits the actors that have mail, not every actor

The probe from the assignment, 20,000 actors spawned and then 100,000
`a <-- :bump` to one of them followed by `schedule(100)`, took 1585 ms on the
base and 22 ms with this change. Each async send ends in runScheduler(1), and
runScheduler walked every instance looking for a non-empty mailbox, so a send
cost as much as the number of actors alive. A Temper program has an actor per
object.

ab2.sh, base (A) against this change (B), user seconds:

    bench             A        B
    markdown       1.76     1.51
    core           2.51     2.26
    webtest        1.39     1.36
    markdown       1.76     1.50
    core           2.49     2.23
    webtest        1.40     1.36
    markdown       1.73     1.49
    core           2.48     2.22
    webtest        1.37     1.34

Two changes made this. The bitset alone (an earlier ab2 run) gave markdown
1.88 to 1.71, core 2.60 to 2.55, webtest 1.43 to 1.42. The reductions change
gave the rest, about 0.2 s on markdown and core.

The queue is not a FIFO. The old walk visited actors in instance order, and
mail a handler sent to a later actor was handled in the same pass, while mail
to an earlier one waited for the next tick. A FIFO of ids would change that.
Ids ascend with instance order and are never reused, so the registry keeps
the set of ids with mail as a two-level bitset (`Registry.pending`,
`pending_words`) and a pass asks for the smallest pending id above its
cursor. That visits in the same order, nested runScheduler calls included,
each with its own cursor. Order of message processing is unchanged. With no
mail a call is one comparison of `pending_count` with zero. The `Scheduler`
in src/scheduler.zig is used nowhere (`Evaluator.scheduler` is never set) and
is left alone: its `enqueue` is a linear dedupe and its `dequeue` a memmove,
so it was not usable as the outline lookups.md suggested.

The invariant: bit set if and only if the mailbox is non-empty. `Registry.send`
(replacing both `mailbox.enqueue` sites in eval.zig) sets it;
processMailboxMessage clears it when its dequeue empties the mailbox, before
the handler runs, so a handler that sends to itself sets it again.
Compaction copies the instances into a new allocator and the bitset lived in
the old one, so `reindex`, which already rebuilds `by_id`, rebuilds the
bitset from the copied mailboxes. A dropped entry had an empty mailbox
(reachableInstances treats mail as a root), so it was never in the set.
gc.zig's loop over `sched.run_queue` is over the unused Scheduler and stays.
`Registry.migrate` replaces state and handlers and leaves the mailbox alone,
so nothing to do. The fork-per-request server copies the whole process,
bitset included; nothing to do.

The reductions counter was decremented on every evalNode and every tail call.
It now ticks in evalFuncCall, in evalTail's closure branch, and in
callClosureWithValues (closures applied by map, each and the like), through
one inline `countReduction`. Every loop in Blimp is a call, so async mail
still waits a bounded number of calls; the slice stays 4000 and a send still
drains itself at once. A reduction is now a call rather than a node, so the
periodic drain fires less often in wall time. That matters only for mail left
in a mailbox by something other than a send, which none of the suites do;
I did not measure how much less often.

Gates: zig build test passes, with a new test of the pending set across word
boundaries. webtest 43, html 646, core 51, works 160, reading 190 and
pages_show 293 cases, zero failures each. The Markdown bench differs from the
base only in its millisecond numbers.

Not done: Mailbox.dequeue shifts the whole message array, so a mailbox with n
queued messages costs n per message. The probe does not hit it because every
send drains, but a producer that queues thousands before a drain would.

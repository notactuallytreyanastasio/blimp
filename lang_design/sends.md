# a send lends the actor's state and finds its handler by hash; no benchmark in the set moves

A synchronous send is 34% cheaper on a loop that does nothing else, and
none of the three ab2 benchmarks changes. `markdown` spends its time in
functions, not sends, and `webtest` is not actor-heavy at all: a native
sample of it puts about 60% of the working thread in pbkdf2, sha2 and hmac (the
router's password tests), and eval, lookup and defineIn together under 15%. The change is correct and measurable, and it is
not a win on the numbers this series is judged by.

What a send did. `evalMessageSend` walked `entry.handlers` comparing names
byte by byte, then `define`d every state field into the handler's scope
(nameBit, hashName, append, per field, per message). A thirteen-field object
paid thirteen defines to read one field. A guard paid them twice.

What it does now.

State is lent. Each instance keeps a `StateLend`: its fields in the shape
`Scope.captured` borrows (name, value, hash), plus the names mask, built on
the first send. `enterHandler` binds the parameters, then hands the scope
that slice through `Environment.lendState`. Lookup already searches the
captured tier after the scope's own bindings, so a local assigned in the
handler still shadows a field, as before. Every site that bound state uses
`enterHandler`: the sync send, the guard, the piped send, and
`processMailboxMessage`, so async messages behave identically.

Handlers carry a hash. `HandlerDef.hash` is `hashName(name)`, set when the
actor is defined and carried through `gc.compact`. A send hashes its message
once and compares integers before bytes. After lending, `mem.eqlBytes` was
10% of the work in the microbenchmark, nearly all of it this scan.

Why lending the live array is wrong. `become` writes `entry.state_fields`
in place for the next message, and the running handler must keep the values
it started with. A scope that borrowed the live array would see its own
`become`. So the lent copy is separate from `state_fields`, and each running
handler counts itself in `StateLend.borrowers`. `become` writes the lent copy
in place only while no handler holds it; otherwise it makes a fresh copy
and swaps it in, and the handlers that are running keep the old one. Because
a handler is always inside its own `become`, in practice every become copies
once (13 fields: 416 bytes from the evaluator's arena, which frees nothing
until compaction). A second `become` in the same handler writes to the
fresh copy, which nobody holds yet. I did not stage `become`'s writes until
the handler returns: that would hide a handler's own become from a nested
send back into the same actor, which the base shows today.

The parameter case. `define` let a state field overwrite a parameter of the
same name (`on :set(n: Int)` against `state n` read the field). A lent tier
would let the parameter win. `enterHandler` checks parameter names against
field names and falls back to defining everything when one collides.

Not kept in step: `registry.migrate` and the restart functions replace
`state_fields` wholesale, so they drop `entry.lent`; a compaction builds
entries without it. Both rebuild on the next send.

Measurement, `sh ab2.sh lang-base lang-sends 3` (user seconds):

    bench             A        B
    markdown       1.77     1.79
    core           2.56     2.56
    webtest        1.40     1.39
    markdown       1.77     1.76
    core           2.58     2.56
    webtest        1.42     1.41
    markdown       1.80     1.80
    core           2.55     2.56
    webtest        1.41     1.42

The microbenchmark (a 13-field, 36-handler object; 2,000,000 iterations of a
getter on the last field and a method on the last method, 4M sends):

    base          1.14 s
    state lent    0.87 s
    + hash        0.76 s

Tests. `zig build test` passes, with a new test, "become is a snapshot for
the running handler": a become then a read, two becomes, a guard, a closure
made before a become, a handler sending to another instance and back to
itself, and a parameter named like a field. Its expected values were taken
from the base interpreter. Suites: webtest 43, html 646, core 51, works 160,
reading 190, pages_show 293, zero failures each. The Markdown bench prints
the same lines as the base apart from milliseconds.

Not done: the handler scan is still linear in the number of same-hash
candidates (in practice one); a per-template table would remove it, and I
did not measure it as mattering once the compare is an integer.

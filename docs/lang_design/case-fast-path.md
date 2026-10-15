# `true ->` and `_ ->` branches skip matchPattern, and a branch that cannot define skips its scope; core is 2.5% faster, the rest is unmoved

Temper compiles every `if` to `case cond do true -> .. _ -> .. end`. In the compiled core library that is 3,270 `true ->` arms, 0 `false ->` arms and 3,317 `_ ->` arms, in 2,531 `case ... do` heads, 1,856 of which have a comparison or equality as the subject. So the whole population is one shape: a boolean subject, a `true` arm, a wildcard arm.

The parser now marks each branch. `Branch.mode` is `.wild` (pattern `_`, body not a lone hole), `.is_true`, `.is_false` or `.general` (the old path, and the default for a Branch built by hand). `Branch.scoped` says whether taking the branch needs a scope of its own. evalSituationTail switches on the mode before it looks at the pattern:

    .wild            -> evalBodyTail                       (no matchPattern, no guard, as before)
    .is_true/false   -> subject is a boolean of that value? then
                          not scoped: guard, evalBodyTail   (no scope)
                          scoped:     pushScope, branchBody (the old tail, now shared)

Why the obvious version is wrong: "a literal binds nothing, so no scope" ignores that the body runs in that scope. `true -> x = 2; ...` defines `x` in it, and without the scope the assignment overwrites the caller's `x` and outlives the `end`. So `scoped` is computed by the parser, once: the pattern binds (not a literal or hole), or the guard or any body statement is not on a whitelist of node kinds that provably define nothing (`Node.mayDefine`: literals, identifiers, binary and unary operators, calls whose arguments qualify, dot access, list and tuple literals, nested case and situation of the same). Everything else, assignments, `fn` literals, pipes, `become`, `reply`, keeps its scope. This is the rule and the whitelist from the earlier match attempt (patches/match.patch), reused unchanged; what is new is that it is applied only to the two shapes that matter, and that the wildcard arm and the `true` arm no longer go through matchPattern's switch at all. The wildcard arm never pushed a scope and still does not (an assignment there leaks into the enclosing frame; that is existing behaviour and changing it is a semantic change, not an optimisation). A wildcard arm has never run its guard; kept.

Guards, binding order and tail-call scope ownership are as before: a scoped branch pushes, runs the guard (an erroring guard counts as false and pops), and leaves its scope for a pending tail call to collapse; an unscoped branch has nothing above `base` to own, and resolveTail's `popTo(base)` tolerates that.

Measurement, ab2.sh, three rounds, user seconds, A = lang-base9, B = this:

    bench             A        B
    markdown       0.77     0.77
    core           1.17     1.14
    webtest        1.23     1.23
    markdown       0.77     0.77
    core           1.17     1.14
    webtest        1.23     1.23
    markdown       0.77     0.77
    core           1.17     1.13
    webtest        1.23     1.24

Core is 2 to 3% faster in every round; markdown and webtest do not move. The earlier attempt on a base twice as slow measured nothing; the same work is now a visible share of a shorter run, but it is still small. evalSituationTail's 7% on the Markdown bench is the subject evaluation, the loop and the body's own evaluation, which are counted under their own names; the dispatch overhead this removes is a fraction of it.

Two parts of the assignment are not in the patch.

checkType: resolving the annotation to an enum at parse time (`TypeTag`, set by both parameter parsers, with a string fallback for a hand-built param) was built and measured against the part-one binary: markdown 0.77/0.76/0.76 against 0.78/0.75/0.75, core 1.13/1.13/1.14 against 1.11/1.12/1.12, webtest 1.20/1.21/1.19 against 1.19/1.19/1.19. About 1% on core, nothing elsewhere, under the 2% bar everywhere, so it was reverted. Typed parameters are rare in the compiled library, and the string compares fail on length before reaching the bytes.

Fusing the comparison with its case was not built. The boolean is already an interned pointer, so the fusion would save one eval dispatch per `case`, and calling evalBinaryOp directly would skip eval's error location (`locate`) and the reductions counter that schedules actors, both of which a case's subject currently gets for free. That is a semantic risk for a saving below what the whole of part one measured.

Gates: `zig build test` and `zig build wasm` pass, with one new test (an assigning `true` arm leaves the caller's variable alone; a `when` guard falls through to the next arm; a 100,000-deep tail recursion through a `true`/`_` pair; a non-boolean subject reaches `_`). webtest 43 cases, html 646, core 51, works 160, reading 190, zero failures each; the Markdown bench prints the same 656 lines as the base apart from milliseconds. pages_show was not run: no actor or compaction code is touched.

Not done: an arm that contains an assignment keeps its scope, and that is the common reason the fast path does not apply (in the earlier count, about 40% of arms with a pattern). Pushing the scope lazily at the first define would need Environment changes.

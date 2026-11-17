# The checker reads the bodies it skipped

*November 16, 2026*

A comment says Blimp's type checker is mandatory, with no bypass, and it runs before every `blimp FILE`. Until this branch it skipped most of the program. Its statement walker handled twelve node kinds and ended in `else => {}`, and its expression inferrer ended in `else => .hole`. The walker passed over a `case`, a `for`, a `try` or a bare expression on a line of its own without looking inside. It never entered a fn body, and it typed a list by its first element alone.

We wrote 24 small files, each putting one obvious error in a different position, and ran `blimp FILE --ast` on both builds. All 24 passed the checker on the parent. Five of them:

```blimp
1 + :a
ys = map([1, 2], fn(x: Int) do x + :a end)
y = case 1 do _ -> 1 + :a end
x = [1, 1 + :a]
print("#{1 + :a}")
```

On this branch each file reports one error. A reply inside a case branch was the case we least expected to be missed:

```blimp
actor A do
  on :m(k: Int) -> Int do
    case k do _ -> reply :a end
  end
end
```

```
Type error at line 3, col 20: reply type mismatch: expected Int, got Atom
```

The handler used to check its `-> Int` only against a `reply` at the top of its body. `inferExpr` now names every node kind, so a kind someone adds later fails the Zig build until the checker handles it.

## Tuple was an actor

`Tuple` appears 57 times in the repository's `.blimp` files, and `parseTypeName` had no case for it. The name fell through to the rule "anything else starting with uppercase is an actor type", and no tuple is a subtype of an actor. This failed even at top level on the parent:

```blimp
actor A do
  on :m(o: Tuple) -> Tuple do reply o end
end
a = spawn A
r = a <- :m({1, 2})
```

```
Type error at line 5, col 13: argument 1 to :m expected Tuple, got {...}
```

We built this branch with the fix removed. Tetris then fails at line 440, `fn(o: Tuple) do o == {px, py} end`, with `cannot compare Tuple with {...}`. `Tuple` is now `Any`. The obvious fix, a tuple type, would be wrong: the lattice's tuples have a fixed arity, and `Tuple` means any arity.

On the parent, `x = length(1 + :a)` produced three errors. The arithmetic error appeared twice, because the builtin's arguments were inferred by the call and again by the signature. Then came `length() expects a list, got Never`, where `Never` is the type the checker hands back after it reports an operand. On this branch the output is one line.

## A wrong turn on assignments

After `for i in xs do x = i end`, what type is `x`? The third commit guessed. It widened every outer name that a branch, loop or try assigned to hole, on the grounds that `x = nil; for i in xs do x = i end; y = x + 1` "is fine at run time if the loop's assignment reaches the outer x". Nobody ran that program first. In the interpreter the assignment never reaches the outer x, so the program stops with TYPE MISMATCH. The parent's checker had refused it, correctly, with "Nil and Int", and the widening let it through. A checker test asserted that it passes.

We found that while writing up the first version of this branch, and the fifth commit measures the interpreter and adopts its rules. We repeated the measurement on the new tip. Each program starts `x = 1`, assigns `x = 2` inside the body, then runs `puts(x)`:

```
                           interpreter   compiled
for body                   1             2
case 1 -> / n -> / true -> 1             2
case or situation _ ->     2             2
try body                   2             2
catch body (it ran)        1             2
```

A `_ ->` branch runs in the enclosing scope and every other branch gets a scope of its own. That asymmetry lives in the interpreter's `evalSituationTail`, which the commit leaves alone. The checker now copies it. For, catch, test and non-`_` branches leave outer types untouched. A try body and a leading `_ ->` (which always runs) update them. A later `_ ->` might not run, so the checker refuses an assignment there that changes a name's type:

```
x = 1; case 2 do 1 -> 0  _ -> x = :a end; y = x + 1
Type error at line 4, col 8: 'x' is Int before this case and the `_ ->` branch makes
it Atom; only a `_ ->` branch's assignment is seen after the case, so after it 'x' is Int
or Atom depending on which branch ran
```

The two programs the wrong turn let through are refused again, and `x = :none; try do x = 2 ... end; y = x + 1`, which the parent refused, now passes and prints 3.

That message first ended at "so afterwards it is either", and the fifth commit left a name first bound in a later `_ ->` unknown to the checker, so `case 2 do 1 -> 0  _ -> z = :a end; y = z + 1` passed and failed at run time. The seventh commit finishes the sentence and binds such a name with the branch's type, so that program is now refused.

Three gaps remain. The refusal fires even when `x` is never used again: `puts(1)` in place of `y = x + 1` is refused, and the interpreter prints 1. A try body that faults before its assignment leaves the old type in place at run time, which the checker does not model. And the compiled column disagrees with the interpreter on three rows. For `blimp-compile`, the checker is wrong about those three.

## What changed verdict

We ran 225 of the 229 tracked `.blimp` files through `--ast` on both builds, skipping four that call a paid model. 211 pass on the parent and 208 here. Two of the three that changed are `examples/errors/03` and `04`, which exist to fail. The compiler now refuses them with a report where it used to emit invalid LLVM. In the interpreter they got worse. File 03 says it "Shows: Operator-specific advice (use ++ for strings/lists)", and on the parent the runtime report gave that advice. Now the checker runs first and prints one line, `arithmetic on incompatible types: String and Int`, without the hint.

The third is `lib/operator_test.blimp`, which tests that `"hello" + " world"` and `42 && true` work. They do work in the interpreter. The checker has always refused them, and until now it never read test bodies. This shows the inconsistency we most want fixed next. `blimp FILE --test` respects the checker, but `blimp test DIR` calls it and throws the result away. As a result the command in that file's header stops on 14 type errors, while `blimp test lib`, which `make check` runs, reports `144 tests passed`.

Chapter 77's runner fixture collided with this branch in the same way. Four of its deliberately failing tests do `1 + "a"`, and the checker refused the whole file before any test ran, which broke `make check`. The last commit routes those values through `def dyn(v: Any) -> Any do v end`, which hides their types from the checker. It could have moved the fixture to `blimp test DIR` instead, but that would have worked only because of the defect above.

`make check` passes on both builds, and `zig build test` goes from 1076 to 1095.

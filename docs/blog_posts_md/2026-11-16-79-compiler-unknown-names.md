# A def Named printf

*November 16, 2026*

Chapter 71's harness found that most of the compiler's failures traced back to one branch in `codegen.zig`. When the compiler met a call to a name it did not recognise, it emitted a call to an external C function with exactly that name. Every argument and the result were declared i64, and at most eight arguments were passed. The comment above it said `call extern blimp_<name>`, but the code never added the prefix. Most of the time the link failed on `_rem` or `_f`. The bad case was a name libc already had:

```
$ printf 'abs(0 - 5000000000)\n' > abs.blimp
$ blimp abs.blimp --print-last
5000000000
$ blimp-compile abs.blimp -o a && ./a; echo "exit $?"
705032704
exit 0
```

That number comes from C's `int abs(int)`, which got the low 32 bits of the argument. `puts(3)` gave libc's `puts` the address 3, and the binary died with exit 139. This branch removes that path, so no Blimp call by name ever reaches C.

## The other direction

Before we got to the calls, we found that defs had the same hole facing the other way. A compiled def used its Blimp name as its C symbol, with external linkage, in the same namespace as libc and our runtime:

```
def printf(n: Int) -> Int do n + 100 end
def malloc(n: Int) -> Int do n + 1 end
printf(malloc(7))
```

The interpreter prints `108`. On chapter 78 the compiled program printed nothing and exited 0. The runtime's `blimp_print_int` calls `printf`, and in that binary `printf` was the def, which added 100 and printed nothing. We then added one `spawn` to a program with `def malloc` in it, and the binary exited 139, since the compiler finds `malloc` by name in the module and got the def. `def main()` failed LLVM verification because it collided with the i32 `main` the compiler generates.

The first commit renames every def to `def.<name>` with internal linkage:

```
define internal i64 @def.printf(i64 %0) {
define internal i64 @def.malloc(i64 %0) {
```

No C identifier can start with `def.`, and an internal symbol is invisible to the linker. All three programs now print what the interpreter prints.

## Resolving a name the way the interpreter does

The tempting fix for the calls was to keep the extern branch and add a check that the symbol exists in the runtime. We decided against it because the check would keep the bug. Blimp has no foreign function interface, so no Blimp program has a call by name that should end up in C. The branch only ever found symbols by accident, and the accidental matches that linked are the ones that gave wrong answers instead of failing.

So the second commit resolves a call in the interpreter's order. The compiler first looks for a local holding a value (a fn is one), then a def, unless a local of that name hides it, then its own builtins. It refuses anything else and says why:

```
-- CANNOT COMPILE ──────────────────────────────────────────

  There is no `lenght` in compiled code: it is not a def in this file, and not one of the builtins the compiler provides (max, min, rem, abs, puts).

2| lenght(items)
    ^
```

That order also fixed two bugs that had nothing to do with libc. `def max(a: Int, b: Int) -> Int do 99 end` followed by `max(1, 2)` used to print `2`, because the inline `max` came first. It prints `99` now, as in the interpreter. A def with nine parameters, called with 1 to 9, used to print `36` and exit 0. The call passed only eight arguments to a nine-parameter function, and LLVM's verifier allowed it. The compiler now counts the arguments, checks them against the def's arity, and requires each one to be an Int or an actor, since a compiled def takes every parameter as an i64.

The compiler is now stricter than the interpreter, which reports an undefined name only when the call runs. `examples/case_statement.blimp` calls an undefined `validate` from a handler that nothing ever sends to. The interpreter runs it and exits 0, and the compiler refuses it. We would rather refuse that program than compile one that prints a wrong number.

## Three builtins, compiled exactly

The third commit gives compiled code `rem`, `abs` and `puts`. We ran each one's edge cases on both sides:

```
m = 0 - 9223372036854775807 - 1
puts(abs(m))         -9223372036854775808
puts(rem(m, 0 - 1))  0
rem(0 - 7, 2)        -1
```

`abs` of minInt wraps, because the interpreter computes `0 -% n`, so the compiler's subtraction has no overflow flag. LLVM's `srem` of minInt by -1 is undefined behaviour, so a divisor of -1 is replaced by 1, which gives the same remainder. `rem(x, 0)` raises the same fault as `x / 0`. `try` catches it as `:division_by_zero`, and when nothing catches it the compiled program's stderr matches the interpreter's byte for byte. `puts` takes an Int or a String. We left Floats out, since the runtime prints them with `%g`, and it would print `0.3` where the interpreter prints `0.30000000000000004`.

## Calling a fn value

`f = fn(x: Int) do x * 2 end; f(21)` used to fail at link on `_f`. The closure already existed at run time. The compiler just never emitted a call to it. The fourth commit adds the call. A list and a fn look the same to the compiler, so the runtime checks the value at the call site. On a bad call it prints the interpreter's report:

```
-- WRONG ARGUMENT COUNT ──────────────────────────

  Handler :fn expects 1 argument(s), got 2.

2| f(1, 2)
     ^
```

The same commit refuses fn bodies that do not end in an Int. On chapter 78, `fn(x: Int) do true end` boxed the `true` as the Int 1.

## The count

We ran the harness on chapter 78 and on this branch, over the same 148 programs:

```
                chapter 78   this branch
agree               64           70
unsupported         23           39
compile-error       32           12
diverge             18           17
crash                1            0
```

Twenty compile-errors became refusals that name the call, and `length` is now the most common name in them, with six programs. The commit messages give the intermediate counts as 63, 68 and 69. Those were counted on the corpus from before chapters 76 to 78 and are one short. The table shows the real before and after.

## What it still gets wrong

`puts(1 < 2)` prints `1`, because a comparison is still tagged Int. `puts("a\nb")` prints a backslash and an `n`, because the compiler does not unescape string literals. If a local Int hides a def, the refusal claims the def does not exist: with `def double(x: Int)` and `double = 5`, `double(3)` says "it is not a def in this file". The compiler refuses a `try` around a fn call even when the fn cannot fault. And every builtin except these five is still refused, so programs that call `length` are next.

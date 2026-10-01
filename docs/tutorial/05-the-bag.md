# Chapter 5: The bag

By the end of this chapter `Tetris.Bag` deals the next piece: all seven kinds in a shuffled order, then another shuffled seven, forever.
You'll write a shuffle from `reduce`, `random` and `set_at`, and test something random without knowing what it will say.

Open `exercises/ch05_bag/01_bag.blimp`.
Everything from Chapters 1 to 4 is finished at the top.
`Tetris.Bag` is the only actor below the line, with two handlers stubbed.

## Why not `random(1, 7)`

The obvious way to pick the next piece is to roll a seven-sided die.
`random(a, b)` gives you an `Int` from `a` to `b`, both ends included:

```blimp
print(for i in range(1, 10) do random(1, 3) end)
```

```
[1, 2, 2, 3, 1, 3, 2, 2, 1, 1]
```

Three 2s in the first seven draws there, and nothing stops a run of them.
A die has no memory, so it can deal four S pieces in a row, or go thirty pieces without the long I you are waiting for.
Players call that a drought, and it is why modern Tetris doesn't roll dice.

It deals from a bag instead.
Put one of each kind in, shuffle, hand them out in order, and when the bag is empty put all seven back and shuffle again.
Every run of seven is all seven kinds.
The longest you can ever wait for a piece is when it comes first in one bag and last in the next: twelve other pieces in between.

## The state is what is left

```blimp
actor Tetris.Bag do
  state bag: List :: []
```

The bag starts empty.
That looks backwards, but it means `:next` has one rule: if the bag is empty, fill it first.
The very first draw fills it, and so does the eighth, and the fifteenth.
`:reset` is written for you and does nothing but empty it again, and the next `:next` takes care of the rest.

## `head` and `tail`

`head(list)` is the first element.
`tail(list)` is everything after it, as a new list:

```blimp
print(head([4, 5, 6]))
print(tail([4, 5, 6]))
print(tail([4]))
```

```
4
[5, 6]
[]
```

Dealing a piece is `head` for the reply and `tail` for the new state.

Here is why the refill is not optional.
`head` of an empty list is not an error.
It is `nil`:

```blimp
actor Bag do
  state bag: List :: [1, 2]
  on :next do
    become bag: tail(bag)
    reply head(bag)
  end
end
b = spawn Bag
print(for i in range(1, 4) do b <- :next end)
```

```
[1, 2, nil, nil]
```

No crash in the Bag.
The `nil` goes out as the next piece kind, and whatever breaks, breaks somewhere else, later.

(That actor is named `Bag`, not `Tetris.Bag`, so it doesn't collide with yours; it is a probe, not part of the game.)

## Matching on the empty list

You've used `case` to pull apart tuples.
It matches lists too, and `[]` as a pattern matches only the empty list:

```blimp
full = case bag do
  [] -> ...
  _ -> ...
end
```

When the bag is empty, `full` should be a freshly shuffled seven, which is exactly what `self <- :shuffled` replies.
Otherwise it is the bag as it stands.
Either way, `full` is not empty, so `head(full)` is a real piece.

Then `become bag:` the tail of `full` and reply its head.
Read both from `full`, not from `bag`.
`bag` is still the empty list if you just refilled, and after Chapter 4 you know `become` doesn't change it for you.

## Shuffling with nothing but swaps

There is no shuffle builtin:

```
-- UNKNOWN FUNCTION ──────────────────────────────

  I don't know a function called `shuffle`.
```

So you write the one everybody should use, Fisher-Yates.
Start with `range(1, 7)`, the list `[1, 2, 3, 4, 5, 6, 7]`.
Walk an index `i` from the last position down to 1.
At each step pick `j = random(0, i)`, somewhere from the front up to and including `i`, and swap positions `i` and `j`.
After that step, position `i` never gets touched again: it is final.
When `i` reaches 1 the whole list is shuffled, and position 0 is whatever is left.

The positions are 0 to 6, so the walk is 6, 5, 4, 3, 2, 1.
`reverse` gives you that:

```blimp
print(reverse(range(1, 6)))
```

```
[6, 5, 4, 3, 2, 1]
```

### A swap is two `set_at`s

You met `set_at(list, index, value)` in the Board: a new list with one position changed.
A swap is two of them, one inside the other.

In a language with arrays, swapping needs a temporary variable, because after `a[i] = a[j]` the old `a[i]` is gone.
In Blimp it isn't gone.
`set_at` never changed the list you passed in, so you can read both old values from it after building the new one:

```blimp
acc = [10, 20, 30, 40]
print(set_at(set_at(acc, 0, elem(acc, 3)), 3, elem(acc, 0)))
print(acc)
```

```
[40, 20, 30, 10]
[10, 20, 30, 40]
```

The solution still names the two values `a` and `b` first, because a swap is easier to read that way, not because it has to.

### The list is the accumulator

`reduce` over the indexes, with `range(1, 7)` as the starting accumulator.
Each step takes the list so far and an index `i`, and returns the list with one more swap in it:

```blimp
reduce(reverse(range(1, 6)), range(1, 7), fn(acc: List, i: Int) do
  ...
end)
```

This is the same shape as the Board's `:lock`, which folded cells into the rows one `set_at` at a time.

## Why the obvious shuffle is wrong

The shuffle most people write first swaps *every* position with *any* position: for `i` from 0 to 6, `j = random(0, 6)`.
It looks fairer, since every swap can reach the whole list.
It isn't fair.
Seven swaps with seven choices each is 7^7 = 823543 equally likely runs, and there are 5040 orders of seven things.
823543 doesn't divide by 5040, so some orders have to come up more often than others.

You can see it with three elements.
This probe shuffles `[1, 2, 3]` six thousand times each way and counts how often each of the six orders comes out:

```blimp
fisher = fn(xs: List) do
  reduce(reverse(range(1, 2)), xs, fn(acc: List, i: Int) do
    j = random(0, i)
    a = elem(acc, i)
    b = elem(acc, j)
    set_at(set_at(acc, i, b), j, a)
  end)
end
naive = fn(xs: List) do
  reduce(range(0, 2), xs, fn(acc: List, i: Int) do
    j = random(0, 2)
    a = elem(acc, i)
    b = elem(acc, j)
    set_at(set_at(acc, i, b), j, a)
  end)
end
perms = [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]]
f = for t in range(1, 6000) do fisher([1, 2, 3]) end
n = for t in range(1, 6000) do naive([1, 2, 3]) end
print(map(perms, fn(p: List) do length(filter(f, fn(x: List) do x == p end)) end))
print(map(perms, fn(p: List) do length(filter(n, fn(x: List) do x == p end)) end))
```

```
[1023, 1000, 1008, 1030, 922, 1017]
[910, 1141, 1100, 1109, 869, 871]
```

Fisher-Yates lands near 1000 for every order.
The naive version has 27 runs to spread over 6 orders; three orders get 5 runs each and three get 4, and the counts sit near 1111 and 889 accordingly.
With seven pieces the imbalance is smaller and harder to see, but it is there: some orders of pieces are dealt more often than others, nobody would notice by playing, and every test that only checks "is it a permutation" passes.

**Your task:** fill in `:shuffled`.
Reply with the shuffled list.
Then fill in `:next`.

## Testing something random

You can't `assert_eq` a shuffle against a particular order.
You don't know the order; that is the point.
What you do know is what has to stay true however it comes out.

The first property: seven draws are the numbers 1 to 7, each once.
`sort` puts a list in order, so a permutation of 1 to 7 sorts to `[1, 2, 3, 4, 5, 6, 7]` and anything with a repeat or a gap doesn't:

```blimp
test "seven draws are a permutation of 1..7" do
  bag = spawn Tetris.Bag
  draws = for i in range(1, 7) do bag <- :next end
  assert_eq(sort(draws), [1, 2, 3, 4, 5, 6, 7])
end
```

The second test does it for two bags in a row, which checks the refill.
The third draws two, resets, and checks the next seven are a whole bag, which checks that `:reset` really throws the leftovers away.

Those three have a hole.
A `:shuffled` that replies `range(1, 7)` without shuffling at all passes every one of them, because 1 to 7 in order is a permutation of 1 to 7.
So there is a fourth property: the bag doesn't always come out the same.

```blimp
test "not every bag comes out in the same order" do
  bag = spawn Tetris.Bag
  first = bag <- :shuffled
  others = for i in range(1, 10) do bag <- :shuffled end
  refute(empty?(filter(others, fn(s: List) do s != first end)))
end
```

Eleven shuffles, and at least one differs from the first.
That fails the do-nothing shuffle, and it also fails one that always replies the same fixed "random-looking" order, which a check against `range(1, 7)` would miss.

It does not catch the biased shuffle from the section above.
Nothing short of counting thousands of runs would, which is why that section shows the counts instead of a test.

### Will that test ever flake?

Not in any way you will see, and the reason is worth knowing.
Run the die-roll line from the top of this chapter twice with the native `blimp` and you get the same list both times:

```
[1, 2, 2, 3, 1, 3, 2, 2, 1, 1]
[1, 2, 2, 3, 1, 3, 2, 2, 1, 1]
```

`random` is a generator with a fixed starting seed.
Until something calls `seed(n)`, every fresh run deals the same numbers, and the same seed replays the same numbers:

```blimp
seed(42)
print(for i in range(1, 5) do random(1, 100) end)
seed(42)
print(for i in range(1, 5) do random(1, 100) end)
```

```
[57, 11, 91, 54, 41]
[57, 11, 91, 54, 41]
```

So `blimp 01_bag.blimp --test` on your machine sees the same shuffles every time: if it passes once, it passes always.

The page is slightly different.
**Run Tests** keeps one interpreter for as long as the page is open and never calls `seed`, so the second click carries on from where the first one's numbers stopped and sees different shuffles.
That is still not a flaky test in practice.
For a correct shuffle to fail it, ten shuffles in a row would all have to match the first, a chance of one in 5040 multiplied by itself ten times.

**Play** does call `seed(Date.now())` before each game, because the browser build has no clock of its own and otherwise every game would deal the same pieces.
Randomness in Blimp is a value you can replay when you want to and vary when you want to, which is what makes it testable at all.

## The exercise

Two handlers, `:shuffled` first because `:next` uses it:

- `:shuffled`: Fisher-Yates over `range(1, 7)`, with `reduce` over `reverse(range(1, 6))`, `random(0, i)` and two `set_at`s per step. Reply the list.
- `:next`: `case` on `bag`; if it is `[]`, the full bag is `self <- :shuffled`, otherwise it is `bag`. `become bag:` its tail, reply its head.

Run the tests with **Run Tests** or ⌘⏎, or locally:

```
blimp exercises/ch05_bag/01_bag.blimp --test
```

All four should go green.
The **Cheat** tab has the solution.

## What you learned

`head` and `tail` take a list apart, and `head([])` is `nil`, quietly, so the empty case is yours to handle.
`case` matches `[]` like any other pattern.
Fisher-Yates is a `reduce` whose accumulator is the list being shuffled, and a swap needs no temporary because `set_at` leaves the old list alone.
The shuffle that swaps with anywhere looks fairer and isn't.
You test randomness by properties that hold however it comes out, `sort` turns "is a permutation" into an `assert_eq`, and a property test can still have a hole that a lazy implementation walks through.
And `random` replays from a seed: a fresh run always deals the same numbers until something calls `seed`.

That is every actor the Game needs except the Game.
Chapter 6 writes the coordinator that holds a Board, a Piece, a Bag and a Score and makes them into Tetris.

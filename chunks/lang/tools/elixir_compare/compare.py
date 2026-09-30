#!/usr/bin/env python3
"""compare.py corpus.tsv elixir.tsv blimp.tsv -- the agreement table, and
every disagreement spelled out."""
import sys
from collections import OrderedDict, defaultdict

FIELDS = ["valid", "scrub", "cp length", "grapheme length", "graphemes",
          "upcase", "downcase", "take 3", "cp slice 1,2", "grapheme slice 1,2"]


def load(p):
    with open(p, encoding="utf-8") as f:
        return [l.rstrip("\n").split("\t") for l in f if l.strip()]


corpus, ex, bl = (load(p) for p in sys.argv[1:4])
assert len(corpus) == len(ex) == len(bl), (len(corpus), len(ex), len(bl))

stats = OrderedDict()
diffs = defaultdict(list)
for (label, h), (l1, e), (l2, b) in zip(corpus, ex, bl):
    assert label == l1 == l2
    st = stats.setdefault(label, [0, 0])
    st[0] += 1
    ef, bf = e.split("|"), b.split("|")
    bad = [FIELDS[i] for i in range(len(FIELDS)) if ef[i] != bf[i]]
    if bad:
        st[1] += 1
        diffs[label].append((h, bad, ef, bf))

def show(h):
    b = bytes.fromhex(h)
    try:
        s = b.decode("utf-8")
    except UnicodeDecodeError:
        return "bytes " + h
    if len(s) > 12:
        return f"{len(s)} code points"
    return " ".join(f"U+{ord(c):04X}" for c in s) + f"  {s!r}"

print(f"{'category':24} {'strings':>7} {'agree':>7}")
tot = [0, 0]
for label, (n, d) in stats.items():
    print(f"{label:24} {n:7} {n - d:7}")
    tot[0] += n
    tot[1] += d
print(f"{'total':24} {tot[0]:7} {tot[0] - tot[1]:7}")
for label, ds in diffs.items():
    print(f"\n## {label}")
    for h, bad, ef, bf in ds:
        print(f"  {show(h)}")
        for f in bad:
            i = FIELDS.index(f)
            print(f"    {f:18} elixir={ef[i][:60]}  blimp={bf[i][:60]}")

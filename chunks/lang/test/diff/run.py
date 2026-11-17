#!/usr/bin/env python3
"""Differential test: the interpreter against the compiler, program by program.

From chunks/lang, with zig 0.16.0 and an LLVM the C API builds against:

  zig build -Dllvm=/opt/homebrew/opt/llvm@22
  python3 test/diff/run.py            # exit 0: nothing new, nothing fixed
  python3 test/diff/run.py -v         # every program's category
  python3 test/diff/run.py --only corpus/arith

Each side runs twice per program (a different second result is `flaky`).
Each .blimp program in the corpus is run two ways:

  interp    zig-out/bin/blimp PROG --print-last
  compiled  zig-out/bin/blimp-compile PROG -o BIN && BIN

and the two results are compared: stdout byte for byte, exit status exactly,
and whether stderr is empty. (The two error renderers share no text, so stderr
is compared for presence only; its first line is kept in the record.)

Every program lands in exactly one category:

  agree           both ran; stdout, exit status and stderr-presence match
  both-reject     both refused it before running (parse or type error)
  unsupported     blimp-compile refused it by name: a located `CANNOT COMPILE`
                  report (or the bare `error.UnsupportedNode` it replaced)
  compile-error   blimp-compile failed any other way (LLVM verification,
                  link, parse) on a program the interpreter accepted, or
                  the other way round
  diverge         both ran and the results differ
  crash           either side died on a signal or ran past the timeout
  flaky           one side gave two different results for one program
                  (each side runs twice)

Only `agree` and `both-reject` are agreement. A crash, a timeout or a compile
failure is never counted as agreement.

Every program that is not in agreement must be listed in known.json with its
category and its fingerprint (both outputs). The run fails, exit 1, when

  NEW      a program not in agreement is not listed
  FIXED    a listed program now agrees: delete its entry
  CHANGED  a listed program's category or outputs changed
  MISSING  a listed program is no longer in the corpus

so the list cannot rot in either direction. `--record` rewrites known.json
from the current run; review the diff before committing it.
"""

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LANG = os.path.normpath(os.path.join(HERE, "..", ".."))
KNOWN = os.path.join(HERE, "known.json")

# Corpus: the focused programs here, plus every existing program that can run
# unattended. Paths are relative to chunks/lang.
CORPUS_GLOBS = [
    "test/diff/corpus",
    "examples",
    "examples/errors",
    "test",
    "benchmarks",
    "lib",
]

# Programs left out, and why. Each one would otherwise be a timeout or a
# result that depends on the machine, not on the implementation.
EXCLUDE = {
    "examples/jetstream.blimp": "opens a network connection",
    "examples/jetstream_serve.blimp": "serves HTTP forever",
    "examples/web_push.blimp": "network",
    "examples/tetris.blimp": "interactive terminal game",
    # A Hole the interpreter reaches runs `claude -p` and writes the answer
    # into the .blimp file in place of the Hole. These three reach one.
    "examples/content_pipeline.blimp": "a Hole calls the claude CLI and rewrites the file",
    "examples/game_rules.blimp": "a Hole calls the claude CLI and rewrites the file",
    "examples/rate_limiter.blimp": "a Hole calls the claude CLI and rewrites the file",
    "examples/bench_fib.blimp": "fib(40): a benchmark, not a test; fib is in corpus/",
    "benchmarks/fib.blimp": "benchmark sized for timing",
    "benchmarks/ring.blimp": "benchmark sized for timing",
    "benchmarks/spawn.blimp": "benchmark sized for timing",
    "test/native_ext_test.blimp": "loads a native extension",
}

# Only the `*_test.blimp` files from lib/: the rest are the self-hosted
# compiler's sources, which define things and run nothing.
LIB_ONLY_TESTS = True


def corpus():
    progs = []
    for d in CORPUS_GLOBS:
        full = os.path.join(LANG, d)
        if not os.path.isdir(full):
            continue
        for name in sorted(os.listdir(full)):
            if not name.endswith(".blimp"):
                continue
            if d == "lib" and LIB_ONLY_TESTS and not name.endswith("_test.blimp"):
                continue
            rel = os.path.join(d, name)
            if rel in EXCLUDE:
                continue
            progs.append(rel)
    return progs


def run(argv, cwd, timeout):
    """Run argv; return a dict that says how it ended. Never raises."""
    try:
        p = subprocess.run(
            argv,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as e:
        return {
            "end": "timeout",
            "stdout": (e.stdout or b"").decode("utf-8", "replace"),
            "stderr": (e.stderr or b"").decode("utf-8", "replace"),
            "exit": None,
        }
    end = "exit" if p.returncode >= 0 else "signal %d" % -p.returncode
    return {
        "end": end,
        "stdout": p.stdout.decode("utf-8", "replace"),
        "stderr": p.stderr.decode("utf-8", "replace"),
        "exit": p.returncode,
    }


def first_line(text, tmp):
    for line in text.replace(tmp, "<tmp>").splitlines():
        line = line.strip()
        # ANSI colour and blank lines say nothing.
        while "\x1b[" in line:
            i = line.index("\x1b[")
            j = line.find("m", i)
            line = line[:i] + (line[j + 1:] if j >= 0 else "")
        line = line.strip()
        if line and not line.startswith("ld: warning"):
            return line
    return ""


def compiler_error(text, tmp):
    """First line of the compiler's complaint; for a link failure, the symbol.

    Codegen turns a call to any name it does not know into a call to an
    extern C function of that name, so "Linker failed" alone hides which
    name it was.
    """
    line = first_line(text, tmp)
    if "CANNOT COMPILE" in line:
        # The report's first line is a rule; the sentence under it names the
        # construct, and that is what a changed refusal should show up as.
        rest = text[text.index("CANNOT COMPILE"):].split("\n", 1)
        line = "CANNOT COMPILE: " + first_line(rest[1] if len(rest) > 1 else "", tmp)
    if line.startswith("Linker failed"):
        syms = [l.strip().split('"')[1] for l in text.splitlines()
                if l.strip().startswith('"_') and '"' in l.strip()[1:]]
        if syms:
            line += " undefined: " + ", ".join(syms)
    return line


def side(r, tmp):
    """The part of a run that is compared and recorded."""
    out = {"end": r["end"], "exit": r["exit"], "stdout": r["stdout"].replace(tmp, "<tmp>")}
    out["stderr"] = first_line(r["stderr"], tmp)
    return out


def rejected_before_running(r):
    text = r["stdout"] + r["stderr"]
    return r["exit"] not in (0, None) and (
        "Parse error" in text or "type error(s) found" in text
    )


def classify(prog, interp, compiler, timeout):
    path = os.path.join(LANG, prog)
    tmp = tempfile.mkdtemp(prefix="blimp-diff-")
    try:
        # `# diff: plain` on the first line runs the interpreter the way a
        # user does, without --print-last.
        with open(path, errors="replace") as fh:
            plain = fh.readline().strip() == "# diff: plain"
        iargv = [interp, path] if plain else [interp, path, "--print-last"]
        i1 = run(iargv, tmp, timeout)
        i2 = run(iargv, tmp, timeout)
        binary = os.path.join(tmp, "prog.bin")
        c = run([compiler, path, "-o", binary], tmp, timeout)
        compiled_ok = c["end"] == "exit" and c["exit"] == 0 and os.path.exists(binary)
        b = run([binary], tmp, timeout) if compiled_ok else None
        b2 = run([binary], tmp, timeout) if compiled_ok else None

        rec = {"interp": side(i1, tmp)}
        if b is not None:
            rec["compiled"] = side(b, tmp)
        else:
            rec["compiler"] = {
                "end": c["end"],
                "exit": c["exit"],
                "error": compiler_error(c["stdout"] + "\n" + c["stderr"], tmp),
            }

        if side(i1, tmp) != side(i2, tmp):
            rec["category"] = "flaky"
            rec["interp_second_run"] = side(i2, tmp)
        elif b is not None and side(b, tmp) != side(b2, tmp):
            # A compiled program that prints a heap address, say: ASLR moves it.
            rec["category"] = "flaky"
            rec["compiled_second_run"] = side(b2, tmp)
        elif i1["end"] != "exit" or c["end"] != "exit" or (b is not None and b["end"] != "exit"):
            rec["category"] = "crash"
        elif b is None:
            ctext = c["stdout"] + c["stderr"]
            if "error.UnsupportedNode" in ctext or "CANNOT COMPILE" in ctext:
                rec["category"] = "unsupported"
            elif rejected_before_running(c) and rejected_before_running(i1):
                rec["category"] = "both-reject"
            else:
                rec["category"] = "compile-error"
        elif rejected_before_running(i1):
            rec["category"] = "compile-error"  # compiler accepted what the interpreter refused
        else:
            same = (
                i1["stdout"] == b["stdout"]
                and i1["exit"] == b["exit"]
                and (i1["stderr"] == "") == (b["stderr"] == "")
            )
            rec["category"] = "agree" if same else "diverge"
        return prog, rec
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


AGREEMENT = {"agree", "both-reject"}


# A flaky program is flaky because two runs of one side disagree, and the
# disagreement can itself fail to show: the compiled actor_reply_string prints
# a String as its address, and two runs printed the same one on try 584 of a
# loop here (about 3000 distinct addresses under ASLR), which made it
# `diverge` and the whole run red on an unchanged tree. A program listed as
# flaky that comes back as something else is therefore run again, up to this
# many times, before that is believed. Programs not listed as flaky are never
# rerun.
FLAKY_RETRIES = 5


def fingerprint(rec):
    """What must stay the same for a listed program to count as unchanged.

    A flaky program's varying output is by definition not reproducible, so for
    it the category, which side varied, the other side in full, and the varying
    side's end, exit status and stderr are held fixed: only the varying stdout
    is let go.
    """
    if rec["category"] == "flaky":
        varied = "interp" if "interp_second_run" in rec else "compiled"
        fp = {"category": "flaky", "side": varied}
        for name in ("interp", "compiled", "compiler"):
            if name not in rec:
                continue
            if name == varied:
                fp[name] = {k: rec[name][k] for k in ("end", "exit", "stderr")}
            else:
                fp[name] = rec[name]
        return fp
    return {k: v for k, v in rec.items() if k != "note"}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--interp", default=os.path.join(LANG, "zig-out/bin/blimp"))
    ap.add_argument("--compiler", default=os.path.join(LANG, "zig-out/bin/blimp-compile"))
    ap.add_argument("--known", default=KNOWN, help="the known-divergences file (default: known.json here)")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--only", help="run only programs whose path contains this")
    ap.add_argument("--record", action="store_true", help="rewrite known.json from this run")
    ap.add_argument("-v", "--verbose", action="store_true", help="print every program's category")
    args = ap.parse_args()

    for tool in (args.interp, args.compiler):
        if not os.access(tool, os.X_OK):
            print("cannot run %s: build it first, from chunks/lang with zig 0.16.0:\n"
                  "  zig build -Dllvm=/opt/homebrew/opt/llvm@22" % tool)
            return 2

    progs = corpus()
    if args.only:
        progs = [p for p in progs if args.only in p]

    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(classify, p, args.interp, args.compiler, args.timeout) for p in progs]
        for f in concurrent.futures.as_completed(futs):
            prog, rec = f.result()
            results[prog] = rec

    known = {}
    KNOWN_PATH = args.known
    if os.path.exists(KNOWN_PATH):
        with open(KNOWN_PATH) as fh:
            known = json.load(fh)

    for prog, rec in list(results.items()):
        listed = known.get(prog)
        if listed is None or listed["category"] != "flaky":
            continue
        tries = 0
        while rec["category"] != "flaky" and tries < FLAKY_RETRIES:
            tries += 1
            rec = classify(prog, args.interp, args.compiler, args.timeout)[1]
        if tries and rec["category"] == "flaky":
            print("note: %s is listed as flaky and its first two runs agreed; run %d more time(s) before it varied"
                  % (prog, tries))
        results[prog] = rec

    if args.record:
        notes = {k: v.get("note") for k, v in known.items() if v.get("note")}
        out = {}
        for prog in sorted(results):
            rec = results[prog]
            if rec["category"] in AGREEMENT:
                continue
            if args.only is None or args.only in prog:
                rec = dict(rec)
                if prog in notes:
                    rec["note"] = notes[prog]
                out[prog] = rec
        if args.only:  # keep entries outside the filter
            for k, v in known.items():
                if args.only not in k:
                    out[k] = v
        with open(KNOWN_PATH, "w") as fh:
            json.dump(dict(sorted(out.items())), fh, indent=2, sort_keys=False)
            fh.write("\n")
        print("wrote %s (%d entries); review `git diff` before committing" % (KNOWN_PATH, len(out)))
        known = out

    failures = []
    by_cat = {}
    for prog in sorted(results):
        rec = results[prog]
        cat = rec["category"]
        by_cat.setdefault(cat, []).append(prog)
        if args.verbose:
            print("%-14s %s" % (cat, prog))
        listed = known.get(prog)
        if cat in AGREEMENT:
            if listed is not None:
                failures.append(("FIXED", prog, "now %s; listed as %s. Delete its entry from known.json." % (cat, listed["category"])))
            continue
        if listed is None:
            failures.append(("NEW", prog, json.dumps(rec, indent=2)))
        elif fingerprint(listed) != fingerprint(rec):
            failures.append(("CHANGED", prog, "listed:\n%s\nnow:\n%s" % (
                json.dumps(fingerprint(listed), indent=2), json.dumps(rec, indent=2))))
    if args.only is None:
        for prog in sorted(known):
            if prog not in results:
                failures.append(("MISSING", prog, "listed in known.json but not in the corpus"))

    print()
    print("%d programs (%d excluded)" % (len(results), len(EXCLUDE)))
    for cat in ["agree", "both-reject", "unsupported", "compile-error", "diverge", "crash", "flaky"]:
        print("  %-14s %d" % (cat, len(by_cat.get(cat, []))))
    if failures:
        print()
        for kind, prog, detail in failures:
            print("%s %s\n%s\n" % (kind, prog, detail))
        print("FAIL: %d program(s) differ from known.json" % len(failures))
        return 1
    print("\nOK: every program agrees or matches its known.json entry")
    return 0


if __name__ == "__main__":
    sys.exit(main())

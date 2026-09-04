#!/usr/bin/env python3
"""Feed a running Blimp program's trace to the receipt printer.

    ./blimp examples/bank.blimp --trace 2>&1 >/dev/null | scripts/trace_receipt.py --backend usb

The runtime writes one tab-separated record per event to stderr:

    spawn <actor>
    send  <from> <to> <msg> <args> <reply>      (from is empty for the top level)
    cast  <from> <to> <msg> <args>              (async, no reply yet)
    state <actor> <field> <value>

Nested sends arrive as they complete, so the top-level send that started a
frame is the last line of that frame. Frames are batched into one receipt
every --every seconds (the console rate-limits to 5 prints a minute by
default) and POSTed as markdown to nerves_receipts' /api/print.
"""
import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request

COLS = 56  # font B columns on the TM-T88VI; code blocks print in font B


def parse(line):
    parts = line.rstrip("\n").split("\t")
    kind = parts[0]
    if kind == "spawn" and len(parts) >= 2:
        return {"kind": "spawn", "actor": parts[1]}
    if kind == "send" and len(parts) >= 6:
        return {"kind": "send", "from": parts[1], "to": parts[2], "msg": parts[3], "args": parts[4], "reply": parts[5]}
    if kind == "cast" and len(parts) >= 5:
        return {"kind": "cast", "from": parts[1], "to": parts[2], "msg": parts[3], "args": parts[4], "reply": None}
    if kind == "state" and len(parts) >= 4:
        return {"kind": "state", "actor": parts[1], "field": parts[2], "value": parts[3]}
    return None


def clip(s, width=COLS):
    return s if len(s) <= width else s[: width - 1] + "…"


def call(rec):
    return ":" + rec["msg"] + ("(" + rec["args"] + ")" if rec["args"] else "")


class Framer:
    """Groups records into frames. A frame is everything that happened
    because of one top-level send or cast, in the order it was reported."""

    def __init__(self):
        self.pending = []   # records waiting for their top-level line
        self.frames = []    # completed frames: (head record, body records)

    def push(self, rec):
        if rec is None:
            return
        top = rec["kind"] in ("send", "cast") and rec["from"] == ""
        if rec["kind"] == "spawn":
            self.frames.append((rec, []))
        elif top and rec["kind"] == "send":
            self.frames.append((rec, self.pending))
            self.pending = []
        elif top and rec["kind"] == "cast":
            # a cast returns at once; whatever the mailbox did follows later
            self.frames.append((rec, self.pending))
            self.pending = []
        else:
            self.pending.append(rec)

    def take(self):
        frames, self.frames = self.frames, []
        return frames


def render(frames, title="BLIMP TRACE", when=None):
    when = when or time.strftime("%H:%M:%S")
    out = ["# " + title, "", when, ""]
    for head, body in frames:
        if head["kind"] == "spawn":
            out.append("spawn **" + head["actor"] + "**")
            out.append("")
            continue
        arrow = "->" if head["kind"] == "send" else "~>"
        out.append("## " + head["to"] + " " + call(head))
        out.append("")
        lines = []
        for rec in body:
            if rec["kind"] == "state":
                lines.append(clip("  * " + rec["actor"] + "." + rec["field"] + " = " + rec["value"]))
            elif rec["kind"] == "spawn":
                lines.append(clip("  + spawn " + rec["actor"]))
            else:
                a = "->" if rec["kind"] == "send" else "~>"
                tail = (" => " + rec["reply"]) if rec.get("reply") is not None else ""
                lines.append(clip("  " + rec["from"] + " " + a + " " + rec["to"] + " " + call(rec) + tail))
        if head.get("reply") is not None:
            lines.append(clip("  => " + head["reply"]))
        else:
            lines.append("  " + arrow + " queued")
        out.append("```")
        out.extend(lines)
        out.append("```")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


class RateLimited(Exception):
    def __init__(self, seconds):
        super().__init__("rate limited, retry in %ss" % seconds)
        self.seconds = seconds


def post(url, markdown, backend, path=None, host=None, port=None, token=None):
    body = {"markdown": markdown, "backend": backend}
    if path:
        body["path"] = path
    if host:
        body["host"] = host
    if port:
        body["port"] = port
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"content-type": "application/json"})
    if token:
        req.add_header("authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        text = e.read().decode(errors="replace")
        if e.code == 429:
            m = re.search(r"(\d+)s", text)
            raise RateLimited(int(m.group(1)) if m else 15)
        raise RuntimeError("%d %s" % (e.code, text.strip()))


class Feeder:
    """Turns trace lines into receipts. `sender(markdown)` does the printing
    and may raise RateLimited; the frames stay queued and go out with the
    next flush after the wait."""

    def __init__(self, sender, every=15.0, max_frames=40, title="BLIMP TRACE", log=None, sleep=time.sleep):
        self.framer = Framer()
        self.sender = sender
        self.every = every
        self.max_frames = max_frames
        self.title = title
        self.log = log or (lambda msg: None)
        self.sleep = sleep
        self.printed = 0
        self.last_flush = time.monotonic()

    def line(self, text):
        self.framer.push(parse(text))
        due = time.monotonic() - self.last_flush >= self.every
        if len(self.framer.frames) >= self.max_frames or (due and self.framer.frames):
            self.flush()

    def flush(self):
        frames = self.framer.take()
        if not frames:
            return False
        md = render(frames, title=self.title)
        for attempt in range(3):
            try:
                self.sender(md)
                self.printed += 1
                self.last_flush = time.monotonic()
                self.log("receipt %d: %d frame(s)" % (self.printed, len(frames)))
                return True
            except RateLimited as rl:
                self.log("rate limited, waiting %ds" % rl.seconds)
                self.sleep(rl.seconds + 0.5)
            except Exception as e:  # keep the trace flowing, report the loss
                self.log("print failed: %s" % e)
                break
        # give the frames back so nothing is lost
        self.framer.frames = frames + self.framer.frames
        self.last_flush = time.monotonic()
        return False

    def finish(self):
        while self.framer.frames:
            if not self.flush():
                break


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://localhost:4090/api/print")
    ap.add_argument("--backend", default="usb", choices=["usb", "tcp", "file"])
    ap.add_argument("--path", help="file backend: where the console writes the ESC/POS bytes")
    ap.add_argument("--host")
    ap.add_argument("--port", type=int)
    ap.add_argument("--token")
    ap.add_argument("--every", type=float, default=15.0, help="seconds between receipts (rate limit is 5/min)")
    ap.add_argument("--max-frames", type=int, default=40, help="flush early once this many frames are waiting")
    ap.add_argument("--title", default="BLIMP TRACE")
    ap.add_argument("--dry-run", action="store_true", help="print the markdown instead of posting it")
    args = ap.parse_args(argv)

    def send(md):
        if args.dry_run:
            sys.stdout.write(md + "\n")
            sys.stdout.flush()
        else:
            post(args.url, md, args.backend, args.path, args.host, args.port, args.token)

    feeder = Feeder(send, every=args.every, max_frames=args.max_frames, title=args.title,
                    log=lambda m: sys.stderr.write(m + "\n"))
    try:
        for line in sys.stdin:
            feeder.line(line)
    except KeyboardInterrupt:
        pass
    feeder.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())

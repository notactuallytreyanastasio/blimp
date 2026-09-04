# BlimpLang

This is the Blimp language implementation

## Live trace to a receipt printer

`--trace` makes the interpreter write one tab-separated line to stderr for
every spawn, send, cast and state change while a program runs:

```
spawn   Counter#1
state   Counter#1   count   1
send    <from>      Counter#1   increment   <args>   1
cast    <from>      Sink#1      put         7
```

`scripts/trace_receipt.py` reads those lines, groups them into one frame
per top-level send (nested sends and `become` state changes underneath),
renders markdown, and posts a receipt to a running
[nerves_receipts](../../../nerves_receipts) console every 15 seconds:

```sh
./blimp examples/counter.blimp --trace 2>&1 >/dev/null | scripts/trace_receipt.py             # usb printer
./blimp examples/tetris.blimp --trace 2>&1 >/dev/null | scripts/trace_receipt.py --dry-run   # markdown to stdout
scripts/trace_receipt.py --backend file --path /tmp/trace.bin < trace.txt                     # ESC/POS bytes, no hardware
```

The console rate-limits to five prints a minute; the feeder waits and
retries when it is told to, and nothing is dropped. Unit tests:
`python3 -m unittest scripts/trace_receipt_test.py` from `scripts/`.

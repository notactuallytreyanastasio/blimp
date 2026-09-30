#!/bin/sh
# Compare the utf8_* and grapheme* builtins with Elixir's String module.
#
#   tools/elixir_compare/run.sh <ucd_dir> [blimp]
#
# <ucd_dir> holds the UCD files gen_unicode_tables.py reads. Writes
# corpus.tsv, elixir.tsv and blimp.tsv to $OUT (default: a temp dir) and
# prints the agreement table with every disagreement spelled out.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ucd=$1
blimp=${2:-$here/../../zig-out/bin/blimp}
out=${OUT:-$(mktemp -d)}
python3 "$here/gen_corpus.py" "$ucd" > "$out/corpus.tsv"
elixir "$here/oracle.exs" "$out/corpus.tsv" > "$out/elixir.tsv"
"$blimp" "$here/blimp_side.blimp" "$out/corpus.tsv" > "$out/blimp.tsv" 2>/dev/null
python3 "$here/compare.py" "$out/corpus.tsv" "$out/elixir.tsv" "$out/blimp.tsv"

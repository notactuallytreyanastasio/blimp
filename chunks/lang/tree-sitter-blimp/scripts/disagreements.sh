#!/bin/sh
# Every tracked .blimp file on which tree-sitter and the interpreter's
# parser disagree about whether it parses. Run from chunks/lang after
# `zig build interp`:
#
#   tree-sitter-blimp/scripts/disagreements.sh
#
# Prints one line per disagreement and exits 1 if there are any; exits 2,
# saying so, if tree-sitter did not parse every file:
#
#   ts-error   FILE:LINE:COL  SOURCE LINE      tree-sitter has an ERROR or
#                                              MISSING node there; parser.zig
#                                              parses the file
#   ts-clean   FILE  INTERPRETER MESSAGE       parser.zig refuses the file;
#                                              tree-sitter has no ERROR
#
# "Parses" for the interpreter means `blimp FILE --ast` prints no
# "Parse error"; a type error still counts as parsed. tree-sitter reports
# only the first ERROR of each file, so fixing one may uncover the next.
#
# This finds only the loud kind. Two parsers can both accept a file and
# build different trees (`x = 5` then a line `-x` was one); for those,
# compare trees by hand, as test/corpus/newlines.txt does.
#
# tree-sitter caches one compiled library per language name in its libdir
# and rebuilds it only when parser.c or scanner.c is newer than the
# library, so a shared ~/.cache/tree-sitter/lib/blimp.dylib can be another
# checkout's grammar. This script uses a fresh private libdir each run.

set -u

TREE_SITTER=${TREE_SITTER:-npx --yes -p tree-sitter-cli@0.25.10 tree-sitter}
BLIMP=${BLIMP:-zig-out/bin/blimp}

[ -x "$BLIMP" ] || { echo "no interpreter at $BLIMP; run zig build interp" >&2; exit 2; }
[ -d tree-sitter-blimp ] || { echo "run from chunks/lang" >&2; exit 2; }

root=$(git rev-parse --show-toplevel) || exit 2
tmp=$(mktemp -d "${TMPDIR:-/tmp}/blimp-disagree.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT
export TREE_SITTER_LIBDIR="$tmp/lib"
mkdir -p "$TREE_SITTER_LIBDIR"

git -C "$root" ls-files '*.blimp' | sed "s|^|$root/|" > "$tmp/files"

# tree-sitter: FILE <tab> first error, for each file with an ERROR or MISSING.
# --stat ends the output with "Total parses: N". A tree-sitter that did not
# run, or stopped early, prints no such line or a smaller N; without this
# check its silence would read as "no ERROR in any file".
(cd tree-sitter-blimp && $TREE_SITTER parse --quiet --stat --paths "$tmp/files") > "$tmp/out" 2> "$tmp/err"
want=$(wc -l < "$tmp/files" | tr -d ' ')
got=$(sed -nE 's/^Total parses: ([0-9]+);.*/\1/p' "$tmp/out")
if [ "$got" != "$want" ]; then
  echo "tree-sitter parsed ${got:-0} of $want files; nothing was compared. Its stderr:" >&2
  sed 's/^/  /' "$tmp/err" >&2
  exit 2
fi
sed -nE 's/^([^	]*[^ 	]) *	.*\((ERROR|MISSING)[^[]*\[([0-9]+), ([0-9]+)\].*/\1	\3	\4/p' "$tmp/out" > "$tmp/ts"

found=0
while read -r f; do
  rel=${f#"$root"/}
  ts=$(awk -F'	' -v f="$f" '$1 == f { print $2 " " $3; exit }' "$tmp/ts")
  # An integer literal too big for an Int is refused by parser.zig with a
  # "Parse error", but the digits are well-formed and a grammar has no way
  # to know 2^63 from 2^63-1. That refusal is about range, not syntax, so
  # it is the one parse error not counted here.
  msg=$("$BLIMP" "$f" --ast 2>&1 >/dev/null </dev/null | grep -m1 '^Parse error' |
    grep -v ': integer literal [0-9]* \(is one more than the largest Int\|does not fit in an Int\)')
  if [ -n "$ts" ] && [ -z "$msg" ]; then
    set -- $ts
    line=$(($1 + 1))
    src=$(sed -n "${line}p" "$f" | sed 's/^ *//' | cut -c1-80)
    printf 'ts-error\t%s:%d:%d\t%s\n' "$rel" "$line" "$(($2 + 1))" "$src"
    found=1
  elif [ -z "$ts" ] && [ -n "$msg" ]; then
    printf 'ts-clean\t%s\t%s\n' "$rel" "$msg"
    found=1
  fi
done < "$tmp/files"

exit $found

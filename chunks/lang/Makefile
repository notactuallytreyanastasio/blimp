# Blimp build. zig build is the build; these targets are short names for it.
#
# The targets that used to be here called `zig build-exe` / `build-lib` by
# hand, from when the zig 0.15 build runner would not link on macOS 26. Under
# zig 0.16 `zig build` works, and the hand-rolled lines did not: `make` stopped
# at "'sqlite3.h' not found" (the include path is in build.zig), and
# `make test` built libblimp.a, ran no test, and exited 0.

ZIG ?= zig

.PHONY: all blimp run server test check wasm clean

all: blimp

# zig-out/bin/blimp is what the PATH symlink points at; ./blimp is the copy
# checked in beside the source, refreshed when someone runs make.
blimp:
	$(ZIG) build interp
	cp zig-out/bin/blimp ./blimp

run: blimp
	./blimp

server: blimp
	./blimp web/server.blimp

# Zig unit tests only.
test:
	$(ZIG) build test --summary all

# Every suite: zig, blimp test test/lib, examples, node, python, tree-sitter.
# Exits 1 and names the suites that failed if any did.
check:
	ZIG=$(ZIG) scripts/check.sh

wasm:
	$(ZIG) build wasm
	cp zig-out/web/blimp.wasm web/blimp.wasm

clean:
	rm -f blimp blimp.wasm libblimp.a libblimp.a.o builtins.o value.o
	rm -rf .zig-cache zig-out

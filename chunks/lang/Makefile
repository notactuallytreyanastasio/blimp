# Blimp build — use make instead of zig build on macOS 26+
# (zig build runner fails to link on macOS 26 / Zig 0.15 due to SDK changes)

BINARY = blimp
ZIG    = zig
TARGET = aarch64-macos-none

.PHONY: all run server test wasm clean

all: $(BINARY)

$(BINARY): src/main.zig src/*.zig
	$(ZIG) build-exe src/main.zig --name $(BINARY) -target $(TARGET) -lSystem

run: $(BINARY)
	./$(BINARY)

server: $(BINARY)
	./$(BINARY) web/server.blimp

test:
	$(ZIG) build-lib -Mblimp=src/lib.zig -target $(TARGET) -lSystem

wasm:
	$(ZIG) build-exe -Mmain=src/wasm_api.zig --name blimp \
	  -target wasm32-freestanding \
	  -O ReleaseSmall \
	  -rdynamic \
	  -fno-entry
	cp blimp.wasm web/blimp.wasm

clean:
	rm -f $(BINARY) blimp.wasm libblimp.a libblimp.a.o builtins.o value.o
	rm -rf .zig-cache zig-out

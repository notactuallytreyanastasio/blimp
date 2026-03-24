# Blimp - A Radical Approach to Programming
# Top-level Makefile for common tasks

LANG_DIR = chunks/lang
TERM_DIFF_DIR = chunks/term_diff
BLOG_DIR = docs/blog

.PHONY: help build repl compile wasm web term-diff deploy test bench errors clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

# ── Language ─────────────────────────────────────

build: ## Build the Blimp compiler and interpreter
	cd $(LANG_DIR) && zig build

repl: build ## Launch the REPL in a terminal
	$(LANG_DIR)/zig-out/bin/blimp

compile: build ## Compile a .blimp file to native (usage: make compile FILE=examples/counter.blimp)
	$(LANG_DIR)/zig-out/bin/blimp-compile $(LANG_DIR)/$(FILE) --run

compile-out: build ## Compile to a binary (usage: make compile-out FILE=examples/counter.blimp OUT=counter)
	$(LANG_DIR)/zig-out/bin/blimp-compile $(LANG_DIR)/$(FILE) -o $(OUT)

wasm: ## Build the WASM module for the browser REPL
	cd $(LANG_DIR) && zig build wasm
	cp $(LANG_DIR)/zig-out/web/blimp.wasm $(LANG_DIR)/web/blimp.wasm
	cp $(LANG_DIR)/zig-out/web/blimp.wasm $(BLOG_DIR)/repl/blimp.wasm
	@echo "WASM built: $$(ls -la $(LANG_DIR)/zig-out/web/blimp.wasm | awk '{print $$5}') bytes"

web: wasm ## Start local web server for WASM REPL playground
	cd $(LANG_DIR)/web && python3 -m http.server 8080

# ── Testing ──────────────────────────────────────

test: build ## Run all tests
	cd $(LANG_DIR) && zig build test
	@echo "counter:" && $(LANG_DIR)/zig-out/bin/blimp-compile $(LANG_DIR)/examples/counter.blimp --run
	@echo "bank:" && $(LANG_DIR)/zig-out/bin/blimp-compile $(LANG_DIR)/examples/bank.blimp --run
	@echo "traffic:" && $(LANG_DIR)/zig-out/bin/blimp-compile $(LANG_DIR)/examples/traffic_light.blimp --run

bench: build ## Run benchmarks (fib, actors)
	cd $(LANG_DIR) && bash benchmarks/run.sh

errors: build ## Showcase all error messages
	cd $(LANG_DIR) && bash examples/errors/run_all.sh

# ── term_diff (Phoenix app) ──────────────────────

term-diff: ## Launch the diff viewer / multiplexer on a given directory
	cd $(TERM_DIFF_DIR) && mix phx.server

term-diff-setup: ## Install term_diff dependencies
	cd $(TERM_DIFF_DIR) && mix deps.get && mix compile --warnings-as-errors

# ── Deployment ───────────────────────────────────

deploy: ## Deploy blog + REPL to production
	bash deploy.sh

deploy-wasm: wasm deploy ## Rebuild WASM and deploy

# ── Cleanup ──────────────────────────────────────

clean: ## Remove build artifacts
	cd $(LANG_DIR) && rm -rf zig-out .zig-cache
	@echo "Cleaned build artifacts"

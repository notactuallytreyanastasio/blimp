#!/bin/bash
# elixir-compile-check.sh
# After any Bash tool use that looks like it touched Elixir files,
# compile with --warnings-as-errors and report any issues.
# Exit code 2 = block and show error to Claude so it fixes immediately.

# Only run if we're in a Mix project
if [ ! -f "mix.exs" ]; then
  # Check if we're in a subdirectory of a mix project
  if [ -f "../../mix.exs" ] || [ -f "../mix.exs" ]; then
    : # we might be in a mix project subdir, but let the explicit checks handle it
  else
    exit 0
  fi
fi

# Read the tool input to see what command was run
INPUT="$CLAUDE_TOOL_INPUT"

# Only trigger after commands that could have changed Elixir code
# Skip if the command was just a git, curl, ls, etc.
if echo "$INPUT" | grep -qE '(mix compile|mix test|mix phx|mix credo|mix dialyzer|mix format)'; then
  # This was already a mix command, don't double-compile
  exit 0
fi

# Check the tool output for Elixir compiler warnings
OUTPUT="$CLAUDE_TOOL_OUTPUT"

if echo "$OUTPUT" | grep -qiE 'warning:'; then
  cat >&2 << 'EOF'
+===================================================================+
|  ELIXIR: Compiler warnings detected!                              |
+===================================================================+
|  You MUST fix all warnings before continuing.                     |
|  Run: mix compile --warnings-as-errors                            |
|  Fix every warning, then retry.                                   |
+===================================================================+
EOF
  exit 2
fi

exit 0

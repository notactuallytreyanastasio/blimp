# TUI REPL: The Elm Architecture + Vim Navigation

> The REPL should feel like a modern editor married to a live programming environment. You navigate code like vim, see state like a debugger, and the whole thing follows TEA so every state transition is explicit and testable.

## Architecture: TEA (The Elm Architecture)

```
Model -> view(Model) -> Screen
  ^                        |
  |                        v
  +---- update(Model, Msg) <--- Events (keyboard, mouse, resize, eval result)
```

Every state change flows through `update`. Every frame flows through `view`. The model is the single source of truth. No hidden state, no callbacks, no observers.

### Model

```zig
const Model = struct {
    // Vim modes
    mode: Mode,

    // Input editing
    input: TextBuffer,       // multi-line text buffer with cursor
    cursor: Cursor,          // line, column in input buffer

    // Output
    history: ArrayList(HistoryEntry),  // past input/output pairs
    scroll_offset: usize,             // how far scrolled up in output

    // State sidebar
    state_vars: ArrayList(Binding),   // name -> value pairs
    state_scroll: usize,              // scroll position in state panel

    // Completion
    completion: ?CompletionState,     // active tab completion popup

    // Command line (vim : mode)
    command_buffer: ArrayList(u8),

    // Layout
    terminal_size: Size,
    left_width_pct: u8,     // default 75

    // The evaluator
    evaluator: *Evaluator,

    // History navigation
    history_index: ?usize,  // which history entry we're browsing (up/down)
};

const Mode = enum {
    insert,    // typing code, tab completion active (DEFAULT mode)
    normal,    // vim normal: navigate, scroll, search (Escape from insert)
    command,   // vim : command line (: from normal mode)
    search,    // / search in output (/ from normal mode)
};
```

### Messages

```zig
const Msg = union(enum) {
    // Input events
    key: KeyEvent,
    mouse: MouseEvent,
    resize: Size,

    // Eval lifecycle
    eval_complete: EvalResult,
    eval_error: BlimpError,

    // Completion
    completion_selected: []const u8,
    completion_dismissed,

    // Timer
    tick,  // for cursor blink, status updates
};
```

### Update

```zig
fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .key => |key| handleKey(model, key),
        .mouse => |mouse| handleMouse(model, mouse),
        .resize => |size| model.terminal_size = size,
        .eval_complete => |result| appendResult(model, result),
        .eval_error => |err| appendError(model, err),
        // ...
    }
}
```

Key handling dispatches on mode:

```zig
fn handleKey(model: *Model, key: KeyEvent) void {
    switch (model.mode) {
        .normal => handleNormalMode(model, key),
        .insert => handleInsertMode(model, key),
        .command => handleCommandMode(model, key),
        .search => handleSearchMode(model, key),
    }
}
```

### View

```zig
fn view(model: Model, surface: vaxis.Surface) void {
    const left_width = model.terminal_size.cols * model.left_width_pct / 100;
    const right_width = model.terminal_size.cols - left_width - 1;

    // Left panel: output history + input
    drawOutputPanel(model, surface.subSurface(0, 0, left_width, model.terminal_size.rows));

    // Vertical divider
    drawDivider(surface, left_width, model.terminal_size.rows);

    // Right panel: state
    drawStatePanel(model, surface.subSurface(left_width + 1, 0, right_width, model.terminal_size.rows));

    // Status bar at bottom
    drawStatusBar(model, surface.subSurface(0, model.terminal_size.rows - 1, model.terminal_size.cols, 1));

    // Completion popup (floating)
    if (model.completion) |comp| {
        drawCompletionPopup(comp, surface);
    }
}
```

## Vim Navigation

### Normal Mode

| Key | Action |
|-----|--------|
| `i` | Enter insert mode (cursor at end of input) |
| `I` | Enter insert mode (cursor at start of line) |
| `a` | Enter insert mode (cursor after current char) |
| `A` | Enter insert mode (cursor at end of line) |
| `o` | New line below, enter insert mode |
| `j/k` | Scroll output history up/down |
| `h/l` | Navigate horizontally in current input |
| `w/b/e` | Word forward/backward/end in input |
| `0/$` | Start/end of line |
| `#` | Search backward for word under cursor |
| `gg/G` | Top/bottom of output |
| `Ctrl-u/d` | Half-page up/down in output |
| `/` | Enter search mode |
| `:` | Enter command mode |
| `dd` | Clear current input |
| `yy` | Copy current input to clipboard |
| `p` | Paste from clipboard |
| `u` | Undo last input edit |

### Insert Mode

| Key | Action |
|-----|--------|
| `Escape` | Enter normal/command mode |
| `Enter` | Eval (or newline if inside `do` block) |
| `Tab` | Trigger completion |
| `Shift-Tab` | Previous completion |
| `Up/Down` | Browse history |
| `Ctrl-a/e` | Start/end of line |
| `Ctrl-w` | Delete word backward |
| `Ctrl-u` | Clear line |
| `Ctrl-l` | Clear screen |
| All other keys | Insert character |

### Command Mode (`:`)

| Command | Action |
|---------|--------|
| `:q` | Quit REPL |
| `:clear` | Clear output history |
| `:load <file>` | Load and evaluate a .blimp file |
| `:set wrap` | Toggle line wrapping |
| `:actors` | List all spawned actors with state |
| `:decisions` | Show agent decision trees (current + past) |
| `:help` | Show keybinding help |

### Search Mode (`/`)

- Type a pattern, matching output lines highlight
- `n/N` next/previous match
- `Escape` dismiss search

## Syntax Highlighting

In the input buffer AND in output history, Blimp code gets highlighted:

| Token | Color |
|-------|-------|
| Keywords (`actor`, `do`, `end`, `on`, `become`, `reply`, `spawn`, `when`, `bubbles`, `situation`, `case`, `orelse`) | Magenta/pink |
| Atoms (`:ok`, `:error`) | Yellow |
| Strings (`"hello"`) | Green |
| Numbers (`42`, `3.14`) | Purple |
| Operators (`|>`, `<-`, `->`, `+`, `-`, etc.) | Cyan |
| Comments (`# ...`) | Gray |
| Actor names (`Counter`, `Shop.Checkout`) | Bold green |
| Function calls (`length`, `max`) | Blue |
| Holes (`_`) | Red italic |

Use the existing lexer (`lexer.zig`) to tokenize input for highlighting. Same token stream, just map tokens to colors instead of AST nodes.

## Tab Completion

When the user presses Tab in insert mode:

1. Look at the word under the cursor
2. Generate candidates from:
   - Built-in functions (`length`, `max`, `min`, `append`, `reverse`, `lookup`, `put`, `keys`, `now`)
   - Variables in scope (from `evaluator.env.allBindings()`)
   - Actor template names (from `evaluator.registry.templates`)
   - Keywords (`actor`, `do`, `end`, `on`, `become`, `reply`, `spawn`, etc.)
   - Actor ref handler names (if completing after `<-`, show handlers for that actor type)
3. Show a popup with matching candidates
4. Tab/Shift-Tab cycles through candidates
5. Enter or space accepts, Escape dismisses

## Scrollable Panels

Both panels (output and state) should be independently scrollable:

- **Output panel**: `j/k` in normal mode scrolls line by line, `Ctrl-u/d` scrolls half page, `gg/G` goes to top/bottom. Auto-scrolls to bottom on new output. If user scrolled up, stays pinned until they press `G`.

- **State panel**: mouse scroll or dedicated keys (maybe `{/}` in normal mode) to scroll the state sidebar when it overflows.

## Mouse Support

- **Click on a value in state panel**: inspect it (expand lists/maps)
- **Click on output**: copy that line
- **Drag to resize panels**: drag the vertical divider to change the 75/25 split
- **Scroll wheel**: scroll the panel under the cursor

## TextBuffer

A proper multi-line text buffer for code editing:

```zig
const TextBuffer = struct {
    lines: ArrayList(ArrayList(u8)),  // line-based storage
    cursor: Cursor,
    undo_stack: ArrayList(Edit),

    fn insertChar(self, char) void
    fn deleteChar(self) void
    fn newline(self) void
    fn deleteLine(self) void
    fn moveUp/Down/Left/Right(self) void
    fn wordForward/Backward(self) void
    fn getContent(self) []const u8  // join all lines
    fn undo(self) void
    fn redo(self) void
};
```

## Status Bar

Bottom row shows:
```
[NORMAL] blimp  |  3 actors  |  12 vars  |  :help for commands
[INSERT] blimp  |  line 2, col 15  |  do...end (depth 1)
```

- Current mode (highlighted)
- Actor count and variable count
- In insert mode: cursor position and do/end depth
- Scrollback indicator if not at bottom

## Implementation Plan

### Phase 1: Libvaxis integration
- Add libvaxis as build.zig dependency
- Create `src/tui.zig` with Model/Msg/Update/View skeleton
- Basic split panel rendering (no interactivity)
- Replace the current `repl()` function in main.zig

### Phase 2: Insert mode + eval
- TextBuffer with basic editing (insert, delete, newline)
- Enter to eval
- Multi-line do/end detection
- Output rendering with history

### Phase 3: Normal mode + vim navigation
- Mode switching (i, Escape)
- j/k scroll, gg/G, Ctrl-u/d
- h/l/w/b cursor movement
- dd, yy, p
- : command mode

### Phase 4: Syntax highlighting
- Token-based highlighting using existing Lexer
- Apply colors in both input and output

### Phase 5: Tab completion
- Candidate generation from env/registry/builtins/keywords
- Popup rendering
- Tab/Shift-Tab cycling

### Phase 6: Mouse + polish
- Mouse click, scroll, panel resize
- History search with /
- Clipboard integration
- Undo/redo in text buffer

## Files

```
src/tui.zig           -- TEA runtime, Model, Msg, update, view
src/tui/text_buffer.zig  -- Multi-line text buffer with undo
src/tui/highlight.zig    -- Syntax highlighting via Lexer tokens
src/tui/completion.zig   -- Tab completion engine
src/tui/widgets.zig      -- Custom vaxis widgets (output panel, state panel, status bar)
```

## Dependencies

- [libvaxis](https://github.com/rockorager/libvaxis) -- TUI framework, Zig 0.15.1
- Existing: lexer.zig (for highlighting), eval.zig (for evaluation), env.zig (for state), registry.zig (for actors)

const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const Key = vaxis.Key;
const blimp = @import("blimp");
const Evaluator = blimp.Evaluator;
const Parser = blimp.Parser;
const Value = blimp.Value;
const Lexer = blimp.Lexer;
const Token = blimp.Token;

// ============================================================
// TEA Model
// ============================================================

const Mode = enum { insert, normal };

const EntryKind = enum { input, output, err };

const HistoryEntry = struct {
    kind: EntryKind,
    text: []const u8,
};

const Binding = struct {
    name: []const u8,
    value_text: []const u8,
};

const Model = struct {
    mode: Mode,
    // Input buffer: single line stored as ArrayList of bytes
    input_buf: std.ArrayList(u8),
    cursor_col: usize,
    // Output history
    history: std.ArrayList(HistoryEntry),
    scroll_offset: usize,
    // State sidebar
    state_vars: std.ArrayList(Binding),
    // Evaluator
    evaluator: Evaluator,
    arena: std.heap.ArenaAllocator,
    // Terminal dimensions
    terminal_rows: usize,
    terminal_cols: usize,
    // Quit flag
    should_quit: bool,
    // Input history for up/down browsing
    input_history: std.ArrayList([]const u8),
    history_index: ?usize,
    // Multi-line depth
    multi_buf: std.ArrayList(u8),
    depth: i32,
    // Allocator for non-arena stuff
    allocator: std.mem.Allocator,
    // Normal mode command buffer (for gg, dd, :q etc)
    cmd_buf: [8]u8,
    cmd_len: usize,

    fn init(allocator: std.mem.Allocator) Model {
        var arena = std.heap.ArenaAllocator.init(allocator);
        return .{
            .mode = .insert,
            .input_buf = .empty,
            .cursor_col = 0,
            .history = .empty,
            .scroll_offset = 0,
            .state_vars = .empty,
            .evaluator = Evaluator.init(arena.allocator()),
            .arena = arena,
            .terminal_rows = 24,
            .terminal_cols = 80,
            .should_quit = false,
            .input_history = .empty,
            .history_index = null,
            .multi_buf = .empty,
            .depth = 0,
            .allocator = allocator,
            .cmd_buf = undefined,
            .cmd_len = 0,
        };
    }

    fn deinit(self: *Model) void {
        self.input_buf.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.state_vars.deinit(self.allocator);
        self.input_history.deinit(self.allocator);
        self.multi_buf.deinit(self.allocator);
        self.arena.deinit();
    }
};

// ============================================================
// TEA Update
// ============================================================

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    mouse: vaxis.Mouse,
};

fn update(model: *Model, event: Event) void {
    switch (event) {
        .key_press => |key| handleKey(model, key),
        .winsize => |ws| {
            model.terminal_rows = ws.rows;
            model.terminal_cols = ws.cols;
        },
        else => {},
    }
}

fn handleKey(model: *Model, key: Key) void {
    switch (model.mode) {
        .insert => handleInsertMode(model, key),
        .normal => handleNormalMode(model, key),
    }
}

fn handleInsertMode(model: *Model, key: Key) void {
    const alloc = model.allocator;

    // Ctrl-C or Ctrl-D: quit
    if (key.matches('c', .{ .ctrl = true }) or key.matches('d', .{ .ctrl = true })) {
        model.should_quit = true;
        return;
    }

    // Escape: switch to normal mode
    if (key.matches(Key.escape, .{})) {
        model.mode = .normal;
        model.cmd_len = 0;
        return;
    }

    // Enter: evaluate or continue multi-line
    if (key.matches(Key.enter, .{})) {
        handleEnter(model);
        return;
    }

    // Backspace
    if (key.matches(Key.backspace, .{})) {
        if (model.cursor_col > 0) {
            _ = model.input_buf.orderedRemove(model.cursor_col - 1);
            model.cursor_col -= 1;
        }
        return;
    }

    // Left arrow
    if (key.matches(Key.left, .{})) {
        if (model.cursor_col > 0) {
            model.cursor_col -= 1;
        }
        return;
    }

    // Right arrow
    if (key.matches(Key.right, .{})) {
        if (model.cursor_col < model.input_buf.items.len) {
            model.cursor_col += 1;
        }
        return;
    }

    // Up arrow: browse history
    if (key.matches(Key.up, .{})) {
        browseHistory(model, .up);
        return;
    }

    // Down arrow: browse history
    if (key.matches(Key.down, .{})) {
        browseHistory(model, .down);
        return;
    }

    // Ctrl-A: start of line
    if (key.matches('a', .{ .ctrl = true })) {
        model.cursor_col = 0;
        return;
    }

    // Ctrl-E: end of line
    if (key.matches('e', .{ .ctrl = true })) {
        model.cursor_col = model.input_buf.items.len;
        return;
    }

    // Ctrl-U: clear line
    if (key.matches('u', .{ .ctrl = true })) {
        model.input_buf.clearRetainingCapacity();
        model.cursor_col = 0;
        return;
    }

    // Ctrl-W: delete word backward
    if (key.matches('w', .{ .ctrl = true })) {
        deleteWordBackward(model);
        return;
    }

    // Tab: insert 2 spaces
    if (key.matches(Key.tab, .{})) {
        model.input_buf.insertSlice(alloc, model.cursor_col, "  ") catch return;
        model.cursor_col += 2;
        return;
    }

    // Regular character input
    if (key.text) |text| {
        model.input_buf.insertSlice(alloc, model.cursor_col, text) catch return;
        model.cursor_col += text.len;
    }
}

fn handleNormalMode(model: *Model, key: Key) void {
    // Ctrl-C: quit
    if (key.matches('c', .{ .ctrl = true })) {
        model.should_quit = true;
        return;
    }

    // 'i': enter insert mode
    if (key.matches('i', .{})) {
        model.mode = .insert;
        model.cmd_len = 0;
        return;
    }

    // 'I': insert mode at start
    if (key.matches('I', .{})) {
        model.mode = .insert;
        model.cursor_col = 0;
        model.cmd_len = 0;
        return;
    }

    // 'a': insert mode after cursor
    if (key.matches('a', .{})) {
        model.mode = .insert;
        if (model.cursor_col < model.input_buf.items.len) {
            model.cursor_col += 1;
        }
        model.cmd_len = 0;
        return;
    }

    // 'A': insert mode at end
    if (key.matches('A', .{})) {
        model.mode = .insert;
        model.cursor_col = model.input_buf.items.len;
        model.cmd_len = 0;
        return;
    }

    // 'h': move left
    if (key.matches('h', .{})) {
        if (model.cursor_col > 0) {
            model.cursor_col -= 1;
        }
        return;
    }

    // 'l': move right
    if (key.matches('l', .{})) {
        if (model.cursor_col < model.input_buf.items.len) {
            model.cursor_col += 1;
        }
        return;
    }

    // 'w': word forward
    if (key.matches('w', .{})) {
        wordForward(model);
        return;
    }

    // 'b': word backward
    if (key.matches('b', .{})) {
        wordBackward(model);
        return;
    }

    // '0': start of line
    if (key.matches('0', .{})) {
        model.cursor_col = 0;
        return;
    }

    // '$': end of line
    if (key.matches('$', .{})) {
        model.cursor_col = model.input_buf.items.len;
        return;
    }

    // 'j': scroll down in output
    if (key.matches('j', .{})) {
        if (model.scroll_offset > 0) {
            model.scroll_offset -= 1;
        }
        return;
    }

    // 'k': scroll up in output
    if (key.matches('k', .{})) {
        model.scroll_offset += 1;
        return;
    }

    // 'G': scroll to bottom
    if (key.matches('G', .{})) {
        model.scroll_offset = 0;
        return;
    }

    // Check for multi-char commands: 'g', 'd', ':'
    if (key.text) |text| {
        if (text.len == 1) {
            const ch = text[0];
            // Track command buffer for gg, dd, :q
            if (model.cmd_len < model.cmd_buf.len) {
                model.cmd_buf[model.cmd_len] = ch;
                model.cmd_len += 1;
            }

            // Check for 'gg'
            if (model.cmd_len >= 2 and model.cmd_buf[model.cmd_len - 2] == 'g' and model.cmd_buf[model.cmd_len - 1] == 'g') {
                model.scroll_offset = if (model.history.items.len > 0) model.history.items.len - 1 else 0;
                model.cmd_len = 0;
                return;
            }

            // Check for 'dd'
            if (model.cmd_len >= 2 and model.cmd_buf[model.cmd_len - 2] == 'd' and model.cmd_buf[model.cmd_len - 1] == 'd') {
                model.input_buf.clearRetainingCapacity();
                model.cursor_col = 0;
                model.cmd_len = 0;
                return;
            }

            // ':q' handling: ':' puts us in a mini command mode
            if (ch == ':') {
                // Starting command sequence
                return;
            }

            if (model.cmd_len >= 2 and model.cmd_buf[model.cmd_len - 2] == ':' and model.cmd_buf[model.cmd_len - 1] == 'q') {
                model.should_quit = true;
                return;
            }
        }
    }
}

fn deleteWordBackward(model: *Model) void {
    if (model.cursor_col == 0) return;
    var i = model.cursor_col;
    // Skip trailing spaces
    while (i > 0 and model.input_buf.items[i - 1] == ' ') {
        i -= 1;
    }
    // Skip word chars
    while (i > 0 and model.input_buf.items[i - 1] != ' ') {
        i -= 1;
    }
    // Remove from i to cursor_col
    const remove_count = model.cursor_col - i;
    for (0..remove_count) |_| {
        _ = model.input_buf.orderedRemove(i);
    }
    model.cursor_col = i;
}

fn wordForward(model: *Model) void {
    const buf = model.input_buf.items;
    var i = model.cursor_col;
    // Skip current word
    while (i < buf.len and buf[i] != ' ') {
        i += 1;
    }
    // Skip spaces
    while (i < buf.len and buf[i] == ' ') {
        i += 1;
    }
    model.cursor_col = i;
}

fn wordBackward(model: *Model) void {
    if (model.cursor_col == 0) return;
    var i = model.cursor_col;
    // Skip spaces behind cursor
    while (i > 0 and model.input_buf.items[i - 1] == ' ') {
        i -= 1;
    }
    // Skip word
    while (i > 0 and model.input_buf.items[i - 1] != ' ') {
        i -= 1;
    }
    model.cursor_col = i;
}

fn browseHistory(model: *Model, direction: enum { up, down }) void {
    if (model.input_history.items.len == 0) return;

    switch (direction) {
        .up => {
            if (model.history_index) |idx| {
                if (idx > 0) {
                    model.history_index = idx - 1;
                }
            } else {
                model.history_index = model.input_history.items.len - 1;
            }
        },
        .down => {
            if (model.history_index) |idx| {
                if (idx + 1 < model.input_history.items.len) {
                    model.history_index = idx + 1;
                } else {
                    model.history_index = null;
                    model.input_buf.clearRetainingCapacity();
                    model.cursor_col = 0;
                    return;
                }
            } else {
                return;
            }
        },
    }

    if (model.history_index) |idx| {
        const text = model.input_history.items[idx];
        model.input_buf.clearRetainingCapacity();
        model.input_buf.appendSlice(model.allocator, text) catch return;
        model.cursor_col = model.input_buf.items.len;
    }
}

fn handleEnter(model: *Model) void {
    const alloc = model.allocator;
    const arena_alloc = model.arena.allocator();
    const input = model.input_buf.items;
    if (input.len == 0 and model.depth == 0) return;

    // Copy input for accumulation
    const line_copy = arena_alloc.alloc(u8, input.len) catch return;
    @memcpy(line_copy, input);

    // Accumulate into multi-line buffer
    if (model.multi_buf.items.len > 0) {
        model.multi_buf.append(alloc, '\n') catch return;
    }
    model.multi_buf.appendSlice(alloc, line_copy) catch return;

    model.depth += countDepthChange(line_copy);

    // Clear input for next line
    model.input_buf.clearRetainingCapacity();
    model.cursor_col = 0;

    // If still inside a block, stay in continuation mode
    if (model.depth > 0) return;

    // We have a complete input - evaluate it
    const source = arena_alloc.alloc(u8, model.multi_buf.items.len) catch return;
    @memcpy(source, model.multi_buf.items);
    model.multi_buf.clearRetainingCapacity();
    model.depth = 0;

    // Save to input history
    model.input_history.append(alloc, source) catch {};
    model.history_index = null;

    // Add to output history as input
    model.history.append(alloc, .{ .kind = .input, .text = source }) catch {};

    // Evaluate
    evaluate(model, source);

    // Refresh state vars
    refreshStateVars(model);

    // Auto-scroll to bottom
    model.scroll_offset = 0;
}

fn evaluate(model: *Model, source: []const u8) void {
    const alloc = model.allocator;
    const arena_alloc = model.arena.allocator();
    const is_multiline = std.mem.indexOf(u8, source, "\n") != null;

    if (is_multiline) {
        var parser = Parser.init(arena_alloc, source);
        const nodes = parser.parseFilePublic() catch {
            const err = blimp.errors.parseError(source);
            const err_text = formatBlimpError(err, arena_alloc);
            model.history.append(alloc, .{ .kind = .err, .text = err_text }) catch {};
            return;
        };

        model.evaluator.setSource(source);
        var last_result: ?*const Value = null;
        var had_error = false;
        for (nodes) |node| {
            last_result = model.evaluator.eval(node) catch {
                const err_text = if (model.evaluator.last_error) |rich_err|
                    formatBlimpError(rich_err, arena_alloc)
                else
                    "Unknown error";
                model.history.append(alloc, .{ .kind = .err, .text = err_text }) catch {};
                had_error = true;
                break;
            };
        }
        if (had_error) return;

        if (last_result) |result| {
            const result_text = formatValue(result, arena_alloc);
            model.history.append(alloc, .{ .kind = .output, .text = result_text }) catch {};
        }
    } else {
        var parser = Parser.init(arena_alloc, source);
        const node = parser.parseStatementPublic() catch {
            const err = blimp.errors.parseError(source);
            const err_text = formatBlimpError(err, arena_alloc);
            model.history.append(alloc, .{ .kind = .err, .text = err_text }) catch {};
            return;
        };

        model.evaluator.setSource(source);
        const result = model.evaluator.eval(node) catch {
            const err_text = if (model.evaluator.last_error) |rich_err|
                formatBlimpError(rich_err, arena_alloc)
            else
                "Unknown error";
            model.history.append(alloc, .{ .kind = .err, .text = err_text }) catch {};
            return;
        };

        const result_text = formatValue(result, arena_alloc);
        model.history.append(alloc, .{ .kind = .output, .text = result_text }) catch {};
    }
}

fn formatBlimpError(err: blimp.errors.BlimpError, alloc: std.mem.Allocator) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(alloc, "-- ") catch {};
    buf.appendSlice(alloc, err.title) catch {};
    buf.appendSlice(alloc, " -- ") catch {};
    buf.appendSlice(alloc, err.message) catch {};
    if (err.hint) |h| {
        buf.appendSlice(alloc, " | ") catch {};
        buf.appendSlice(alloc, h) catch {};
    }
    return buf.items;
}

fn formatValue(val: *const Value, alloc: std.mem.Allocator) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    val.format(buf.writer(alloc));
    return buf.items;
}

fn refreshStateVars(model: *Model) void {
    model.state_vars.clearRetainingCapacity();
    const arena_alloc = model.arena.allocator();
    const bindings = model.evaluator.env.allBindings(arena_alloc);
    for (bindings) |binding| {
        const val_text = formatValue(binding.val, arena_alloc);
        model.state_vars.append(model.allocator, .{
            .name = binding.name,
            .value_text = val_text,
        }) catch {};
    }
}

fn countDepthChange(line: []const u8) i32 {
    var delta: i32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == ' ' or line[i] == '\t' or line[i] == '\n' or line[i] == '\r') {
            i += 1;
            continue;
        }
        if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "do")) {
            const before_ok = (i == 0) or (line[i - 1] == ' ' or line[i - 1] == '\t' or line[i - 1] == '\n' or line[i - 1] == ')');
            const after_ok = (i + 2 >= line.len) or (line[i + 2] == ' ' or line[i + 2] == '\t' or line[i + 2] == '\n' or line[i + 2] == '\r');
            if (before_ok and after_ok) {
                delta += 1;
                i += 2;
                continue;
            }
        }
        if (i + 3 <= line.len and std.mem.eql(u8, line[i .. i + 3], "end")) {
            const before_ok = (i == 0) or (line[i - 1] == ' ' or line[i - 1] == '\t' or line[i - 1] == '\n');
            const after_ok = (i + 3 >= line.len) or (line[i + 3] == ' ' or line[i + 3] == '\t' or line[i + 3] == '\n' or line[i + 3] == '\r');
            if (before_ok and after_ok) {
                delta -= 1;
                i += 3;
                continue;
            }
        }
        while (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '\n' and line[i] != '\r') {
            i += 1;
        }
    }
    return delta;
}

// ============================================================
// TEA View
// ============================================================

fn view(model: *const Model, win: vaxis.Window) void {
    const total_rows = win.height;
    const total_cols = win.width;

    if (total_rows < 4 or total_cols < 20) return;

    // Layout: left panel (75%), divider (1 col), right panel (25%), status bar (1 row)
    const left_cols: usize = (total_cols * 3) / 4;
    const right_cols: usize = total_cols - left_cols - 1;
    const content_rows: usize = if (total_rows > 1) total_rows - 1 else 1;

    // Clear screen
    win.clear();

    // Draw left panel (output + input)
    drawLeftPanel(model, win, content_rows, left_cols);

    // Draw divider
    drawDivider(win, left_cols, content_rows);

    // Draw right panel (state)
    drawRightPanel(model, win, content_rows, left_cols, right_cols);

    // Draw status bar
    drawStatusBar(model, win, total_rows, total_cols);
}

fn drawLeftPanel(model: *const Model, win: vaxis.Window, content_rows: usize, left_cols: usize) void {
    // Reserve bottom row for input area
    const input_row = content_rows - 1;
    const history_rows = if (content_rows > 2) content_rows - 2 else 0;

    // Draw header
    const header = " BLIMP REPL ";
    writeStr(win, 0, 1, header, .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true });
    // Fill rest of header with dimmed dashes
    var hcol: usize = header.len + 1;
    while (hcol < left_cols) : (hcol += 1) {
        writeChar(win, 0, hcol, 0x2500, .{ .fg = .{ .rgb = .{ 80, 80, 80 } } });
    }

    // Draw history entries (scroll from bottom)
    if (history_rows > 0) {
        drawHistory(model, win, 1, history_rows, left_cols);
    }

    // Draw input line
    const prompt_text = if (model.depth > 0) "  ... " else "blimp> ";
    const prompt_color: Cell.Color = if (model.depth > 0) .{ .rgb = .{ 100, 100, 100 } } else .{ .rgb = .{ 100, 200, 100 } };
    writeStr(win, input_row, 1, prompt_text, .{ .fg = prompt_color, .bold = true });

    // Draw input with syntax highlighting
    const input_start_col = prompt_text.len + 1;
    drawHighlightedInput(model, win, input_row, input_start_col, left_cols);

    // Draw cursor (block cursor via reverse video)
    if (model.mode == .insert) {
        const cursor_actual_col = input_start_col + model.cursor_col;
        if (cursor_actual_col < left_cols and input_row < win.height) {
            const ch_under_cursor: u21 = if (model.cursor_col < model.input_buf.items.len)
                @intCast(model.input_buf.items[model.cursor_col])
            else
                ' ';
            var cbuf: [4]u8 = undefined;
            const clen = std.unicode.utf8Encode(ch_under_cursor, &cbuf) catch 1;
            win.writeCell(@intCast(cursor_actual_col), @intCast(input_row), .{
                .char = .{ .grapheme = cbuf[0..clen], .width = 1 },
                .style = .{
                    .fg = .{ .rgb = .{ 0, 0, 0 } },
                    .bg = .{ .rgb = .{ 200, 200, 200 } },
                },
            });
        }
    } else {
        // Normal mode: underline cursor
        const cursor_actual_col = input_start_col + model.cursor_col;
        if (cursor_actual_col < left_cols and input_row < win.height) {
            const ch_under_cursor: u21 = if (model.cursor_col < model.input_buf.items.len)
                @intCast(model.input_buf.items[model.cursor_col])
            else
                ' ';
            var cbuf: [4]u8 = undefined;
            const clen = std.unicode.utf8Encode(ch_under_cursor, &cbuf) catch 1;
            win.writeCell(@intCast(cursor_actual_col), @intCast(input_row), .{
                .char = .{ .grapheme = cbuf[0..clen], .width = 1 },
                .style = .{
                    .fg = .{ .rgb = .{ 200, 200, 100 } },
                    .bg = .{ .rgb = .{ 60, 60, 70 } },
                },
            });
        }
    }
}

fn drawHistory(model: *const Model, win: vaxis.Window, start_row: usize, max_rows: usize, max_cols: usize) void {
    const history = model.history.items;
    if (history.len == 0) return;

    // We want to show the most recent entries, scrolled by scroll_offset
    // Collect entries that fit in the visible area
    const total_entries = history.len;
    const visible_end = if (total_entries > model.scroll_offset) total_entries - model.scroll_offset else 0;

    if (visible_end == 0) return;

    // Walk backward from visible_end, collect up to max_rows entries
    var entries_to_show: usize = 0;
    var idx = visible_end;
    while (idx > 0 and entries_to_show < max_rows) {
        idx -= 1;
        entries_to_show += 1;
    }
    const visible_start = idx;

    // Render from visible_start to visible_end
    var row = start_row;
    var ei = visible_start;
    while (ei < visible_end and row < start_row + max_rows) {
        const entry = history[ei];
        var col: usize = 1;

        switch (entry.kind) {
            .input => {
                writeStr(win, row, col, "blimp> ", .{ .fg = .{ .rgb = .{ 100, 200, 100 } } });
                col += 7;
                const text = truncate(entry.text, if (max_cols > col + 1) max_cols - col - 1 else 0);
                writeStr(win, row, col, text, .{ .fg = .{ .rgb = .{ 220, 220, 220 } } });
            },
            .output => {
                writeStr(win, row, col, "=> ", .{ .fg = .{ .rgb = .{ 150, 150, 150 } } });
                col += 3;
                const text = truncate(entry.text, if (max_cols > col + 1) max_cols - col - 1 else 0);
                writeStr(win, row, col, text, .{ .fg = .{ .rgb = .{ 255, 255, 255 } } });
            },
            .err => {
                const text = truncate(entry.text, if (max_cols > col + 1) max_cols - col - 1 else 0);
                writeStr(win, row, col, text, .{ .fg = .{ .rgb = .{ 255, 80, 80 } } });
            },
        }
        row += 1;
        ei += 1;
    }
}

fn drawHighlightedInput(model: *const Model, win: vaxis.Window, row: usize, start_col: usize, max_col: usize) void {
    const input = model.input_buf.items;
    if (input.len == 0) return;

    // Use lexer to tokenize for syntax highlighting
    var lexer = Lexer.init(input);
    var col = start_col;

    while (true) {
        const tok = lexer.next();
        if (tok.kind == .eof) break;
        if (tok.kind == .newline) continue;

        const color = tokenColor(tok.kind);
        const style: vaxis.Style = .{
            .fg = color,
            .bold = isTokenBold(tok.kind),
        };

        for (tok.lexeme) |ch| {
            if (col >= max_col) break;
            writeChar(win, row, col, @intCast(ch), style);
            col += 1;
        }
    }
}

fn tokenColor(kind: Token.Kind) Cell.Color {
    return switch (kind) {
        // Keywords: magenta
        .kw_actor, .kw_do, .kw_end, .kw_state, .kw_on, .kw_become, .kw_reply, .kw_when, .kw_bubbles, .kw_def, .kw_situation, .kw_case, .kw_orelse, .kw_spawn => .{ .rgb = .{ 200, 100, 200 } },
        // Atoms: yellow
        .atom => .{ .rgb = .{ 230, 200, 80 } },
        // Strings: green
        .string => .{ .rgb = .{ 100, 200, 100 } },
        // Numbers: purple
        .integer, .float => .{ .rgb = .{ 180, 130, 230 } },
        // Booleans: magenta
        .true_lit, .false_lit => .{ .rgb = .{ 200, 100, 200 } },
        // Nil: gray
        .nil_lit => .{ .rgb = .{ 150, 150, 150 } },
        // Operators: cyan
        .plus, .minus, .star, .slash, .eq, .eq_eq, .bang, .bang_eq, .lt, .gt, .lt_eq, .gt_eq, .pipe_arrow, .send_arrow, .arrow, .pipe_pipe, .amp_amp, .pipe => .{ .rgb = .{ 100, 200, 230 } },
        // Upper identifiers (actor names): bold green
        .upper_identifier => .{ .rgb = .{ 100, 230, 100 } },
        // Hole: red
        .hole => .{ .rgb = .{ 255, 80, 80 } },
        // Everything else: white
        else => .{ .rgb = .{ 200, 200, 200 } },
    };
}

fn isTokenBold(kind: Token.Kind) bool {
    return switch (kind) {
        .kw_actor, .kw_do, .kw_end, .kw_state, .kw_on, .kw_become, .kw_reply, .kw_when, .kw_bubbles, .kw_def, .kw_situation, .kw_case, .kw_orelse, .kw_spawn => true,
        .upper_identifier => true,
        else => false,
    };
}

fn drawDivider(win: vaxis.Window, col: usize, rows: usize) void {
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        writeChar(win, row, col, 0x2502, .{ .fg = .{ .rgb = .{ 80, 80, 80 } } });
    }
}

fn drawRightPanel(model: *const Model, win: vaxis.Window, content_rows: usize, left_cols: usize, right_cols: usize) void {
    const start_col = left_cols + 2;

    // Header
    writeStr(win, 0, start_col, " STATE ", .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true });
    // Fill rest with dashes
    const header_end = start_col + 7;
    var hcol = header_end;
    while (hcol < start_col + right_cols -| 1) : (hcol += 1) {
        writeChar(win, 0, hcol, 0x2500, .{ .fg = .{ .rgb = .{ 80, 80, 80 } } });
    }

    if (model.state_vars.items.len == 0) {
        writeStr(win, 2, start_col, "(no variables)", .{ .fg = .{ .rgb = .{ 100, 100, 100 } } });
        return;
    }

    for (model.state_vars.items, 0..) |binding, i| {
        const row = i + 2;
        if (row >= content_rows) break;

        // Name in blue
        writeStr(win, row, start_col, binding.name, .{ .fg = .{ .rgb = .{ 100, 150, 255 } } });
        const name_end = start_col + binding.name.len;

        // " = " in gray
        writeStr(win, row, name_end, " = ", .{ .fg = .{ .rgb = .{ 100, 100, 100 } } });

        // Value in white, truncated to fit
        const val_start = name_end + 3;
        const max_val_len = if (start_col + right_cols > val_start + 1) start_col + right_cols - val_start - 1 else 0;
        const val_text = truncate(binding.value_text, max_val_len);
        writeStr(win, row, val_start, val_text, .{ .fg = .{ .rgb = .{ 220, 220, 220 } } });
    }
}

fn drawStatusBar(model: *const Model, win: vaxis.Window, total_rows: usize, total_cols: usize) void {
    const row = total_rows - 1;

    // Fill status bar with background
    var col: usize = 0;
    while (col < total_cols) : (col += 1) {
        writeChar(win, row, col, ' ', .{ .bg = .{ .rgb = .{ 40, 40, 50 } } });
    }

    // Mode indicator
    const mode_text = switch (model.mode) {
        .insert => " INSERT ",
        .normal => " NORMAL ",
    };
    const mode_bg: Cell.Color = switch (model.mode) {
        .insert => .{ .rgb = .{ 80, 150, 80 } },
        .normal => .{ .rgb = .{ 80, 80, 150 } },
    };
    writeStr(win, row, 1, mode_text, .{ .fg = .{ .rgb = .{ 0, 0, 0 } }, .bg = mode_bg, .bold = true });

    // "blimp" label
    writeStr(win, row, mode_text.len + 2, "blimp", .{ .fg = .{ .rgb = .{ 200, 200, 200 } }, .bg = .{ .rgb = .{ 40, 40, 50 } } });

    // Stats
    var stats_buf: [128]u8 = undefined;
    const vars_count = model.state_vars.items.len;
    const hist_count = model.history.items.len;
    const stats = std.fmt.bufPrint(&stats_buf, "  {d} vars | {d} entries | :q to quit  ", .{ vars_count, hist_count }) catch "  :q to quit  ";
    const stats_col = if (total_cols > stats.len + 2) total_cols - stats.len - 1 else 0;
    writeStr(win, row, stats_col, stats, .{ .fg = .{ .rgb = .{ 150, 150, 150 } }, .bg = .{ .rgb = .{ 40, 40, 50 } } });

    // Multi-line depth indicator
    if (model.depth > 0) {
        var depth_buf: [32]u8 = undefined;
        const depth_text = std.fmt.bufPrint(&depth_buf, " do..end depth: {d} ", .{model.depth}) catch "";
        const depth_col = mode_text.len + 8;
        writeStr(win, row, depth_col, depth_text, .{ .fg = .{ .rgb = .{ 230, 200, 80 } }, .bg = .{ .rgb = .{ 40, 40, 50 } } });
    }
}

// ============================================================
// View Helpers
// ============================================================

fn writeStr(win: vaxis.Window, row: usize, col: usize, text: []const u8, style: vaxis.Style) void {
    var c = col;
    for (text) |ch| {
        if (c >= win.width) break;
        writeChar(win, row, c, @intCast(ch), style);
        c += 1;
    }
}

fn writeChar(win: vaxis.Window, row: usize, col: usize, char: u21, style: vaxis.Style) void {
    if (row >= win.height or col >= win.width) return;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(char, &buf) catch return;
    win.writeCell(@intCast(col), @intCast(row), .{
        .char = .{ .grapheme = buf[0..len], .width = 1 },
        .style = style,
    });
}

fn truncate(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    if (max_len < 3) return text[0..max_len];
    return text[0..max_len];
}

// ============================================================
// Main Run Loop
// ============================================================

pub fn run(allocator: std.mem.Allocator) !void {
    // Initialize TTY
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    const writer = tty.writer();

    // Initialize Vaxis
    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, writer);

    // Event loop
    var loop: vaxis.Loop(Event) = .{
        .vaxis = &vx,
        .tty = &tty,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    // Enter alternate screen
    try vx.enterAltScreen(writer);

    // Query terminal capabilities
    try vx.queryTerminal(writer, 1 * std.time.ns_per_s);

    // Initialize model
    var model = Model.init(allocator);
    defer model.deinit();

    // Initial render
    {
        const win = vx.window();
        model.terminal_cols = win.width;
        model.terminal_rows = win.height;
        view(&model, win);
        try vx.render(writer);
        try writer.flush();
    }

    // Main event loop
    while (!model.should_quit) {
        const event = loop.nextEvent();
        update(&model, event);

        // Get the window and render
        const win = vx.window();
        model.terminal_cols = win.width;
        model.terminal_rows = win.height;
        view(&model, win);
        try vx.render(writer);
        try writer.flush();
    }
}

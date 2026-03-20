# Magit Architecture Study: Implementation Plan for term_diff

This document distills an 81-node decision graph built from a deep study of the Magit codebase (47 Emacs Lisp files, 13 major modes, 51 transient commands) into a concrete implementation plan for term_diff. Each section maps a Magit architectural concept to its Elixir/Phoenix LiveView equivalent, with implementation priorities, data structures, and key Magit source references.

---

## Current State of term_diff

| File | Lines | Responsibility |
|------|-------|----------------|
| `lib/term_diff_web/live/diff_live.ex` | 753 | Main LiveView: all UI state, rendering, event handling |
| `lib/term_diff/diff/navigation.ex` | 173 | Pure state machine: focus, indices, commit/amend mode |
| `lib/term_diff/git/diff.ex` | 143 | Unified diff parser: FileDiff/Hunk/DiffLine structs |
| `lib/term_diff/git/runner.ex` | 97 | Synchronous `System.cmd("git", ...)` wrapper |
| `lib/term_diff/git/types.ex` | 86 | Core structs: FileEntry, DiffLine, Hunk, FileDiff, RepoState |
| `lib/term_diff/git/log.ex` | 23 | Minimal `--oneline` log parser |
| `assets/js/app.js` | 127 | KeyNav hook: j/k/TAB/Enter/q/l/o/s/u/cc/a/F/Escape |

**What works:** Basic diff viewing, j/k navigation, hunk expand/collapse, file staging/unstaging, commit mode (cc chord), amend, basic log view, AI review integration, real-time file watching.

**What's missing:** Section tree, mode/keymap hierarchy, transient menus, hunk-level staging, word-level diffs, syntax highlighting in diffs, commit graph, blame/time-machine, interactive rebase, async git execution, process log.

---

## Implementation Phases

### Phase 1: Section System (Foundation)

**Why first:** Everything in Magit is a section. Navigation, visibility, keymaps, and rendering all depend on the section tree. Without this, every subsequent feature will be built on the wrong abstraction.

**Magit reference:** `magit-section.el` -- EIEIO class (line 416-431), insert macro (line 1359), toggle (line 966), identity (line 565), section-mode-map (line 445)

**Decision:** Hybrid architecture -- Elixir struct tree for data/navigation, LiveView function components for rendering.

#### 1.1 Create `TermDiff.Section` struct

```elixir
defmodule TermDiff.Section do
  defstruct [
    :type,       # :status_header | :untracked | :unstaged | :staged |
                 # :file | :hunk | :stash | :log | :commit | :branch
    :value,      # Domain data (file path, hunk struct, commit hash)
    :children,   # [%Section{}]
    :hidden,     # boolean -- collapsed state
    :level,      # depth in tree (for level-based visibility)
    :id          # {type, value} tuple for stable identity across refreshes
  ]
end
```

**File:** `lib/term_diff/section.ex` (new)

#### 1.2 Create `TermDiff.SectionTree` module

Operations to implement, mirroring Magit:

| Magit Function | Line | term_diff Equivalent |
|---------------|------|---------------------|
| `magit-section-forward` | 791 | `SectionTree.navigate_forward(tree, cursor_id)` |
| `magit-section-backward` | 810 | `SectionTree.navigate_backward(tree, cursor_id)` |
| `magit-section-up` | 848 | `SectionTree.navigate_up(tree, cursor_id)` |
| `magit-section-toggle` | 966 | `SectionTree.toggle(tree, section_id)` |
| `magit-section-show-level-N` | 1112 | `SectionTree.show_level(tree, n)` |
| `magit-section-cycle` | 1021 | `SectionTree.cycle(tree, section_id)` |
| `magit-section-ident` | 565 | `SectionTree.find_by_id(tree, {type, value})` |
| `magit-get-section` | 606 | `SectionTree.correlate(old_tree, new_tree)` |

**File:** `lib/term_diff/section_tree.ex` (new)

**Algorithm for `navigate_forward`** (from Magit line 791):
1. If current section has visible children, go to first child
2. Otherwise, find next sibling
3. If no next sibling, go to parent's next sibling (recurse up)

#### 1.3 Create function components for each section type

```elixir
# In a new components module
def file_section(assigns) do
  ~H"""
  <div class={["section", @section.hidden && "collapsed"]}
       id={section_dom_id(@section)}>
    <div class="section-heading">...</div>
    <div :if={!@section.hidden} class="section-body">
      <%= for child <- @section.children do %>
        <.render_section section={child} />
      <% end %>
    </div>
  </div>
  """
end
```

#### 1.4 Section identity for refresh stability

When the repo state refreshes, build the new section tree, then walk the old tree to restore:
- `hidden` state for sections with matching `{type, value}` IDs
- Cursor position by finding the closest matching section

This mirrors `magit-section-cache-visibility` (line 155).

**Refactor required:** Replace `Navigation`'s flat `file_index`/`hunk_index` with a single `cursor_section_id` that points into the section tree.

---

### Phase 2: Mode/Keymap Hierarchy

**Why second:** Sections give us context; keymaps give us context-sensitive behavior. The current flat `handle_key/2` can't distinguish between pressing `s` on a file (stage file) vs `s` on a hunk (stage hunk).

**Magit reference:** `magit-mode.el` (line 350-430 for 60+ bindings), `magit-section.el` (line 1459 for section-specific keymaps)

**Decision:** Pattern matching dispatch on `{mode, section_type, key}` tuples.

#### 2.1 Refactor `Navigation.handle_key`

```elixir
# Section-specific bindings (highest priority)
def handle_key(:diff_view, :hunk, "s", nav), do: {:stage_hunk, nav}
def handle_key(:diff_view, :file, "s", nav), do: {:stage_file, nav}
def handle_key(:diff_view, :hunk, "u", nav), do: {:unstage_hunk, nav}

# Mode-level bindings
def handle_key(:diff_view, _section, "TAB", nav), do: {:toggle_section, nav}
def handle_key(:log_view, _section, "Enter", nav), do: {:show_commit, nav}

# Global bindings (lowest priority -- fallback)
def handle_key(_mode, _section, "q", nav), do: {:go_back, nav}
def handle_key(_mode, _section, "g", nav), do: {:refresh, nav}
def handle_key(_mode, _section, "j", nav), do: {:move_down, nav}
def handle_key(_mode, _section, "k", nav), do: {:move_up, nav}
def handle_key(_mode, _section, "$", nav), do: {:process_log, nav}
```

#### 2.2 Full Magit keybinding map to port

| Key | Magit Command | term_diff Action |
|-----|--------------|-----------------|
| `n`/`j` | `magit-section-forward` | Move to next section |
| `p`/`k` | `magit-section-backward` | Move to previous section |
| `TAB` | `magit-section-toggle` | Expand/collapse section |
| `1`-`4` | `magit-section-show-level-N` | Set visibility depth |
| `^` | `magit-section-up` | Go to parent section |
| `s` | `magit-stage` | Stage file/hunk/region at cursor |
| `u` | `magit-unstage` | Unstage file/hunk/region at cursor |
| `c` | `magit-commit` | Open commit transient menu |
| `b` | `magit-branch` | Open branch transient menu |
| `l` | `magit-log` | Open log transient menu |
| `f` | `magit-fetch` | Open fetch transient menu |
| `F` | `magit-pull` | Open pull transient menu |
| `P` | `magit-push` | Open push transient menu |
| `r` | `magit-rebase` | Open rebase transient menu |
| `m` | `magit-merge` | Open merge transient menu |
| `z` | `magit-stash` | Open stash transient menu |
| `d` | `magit-diff` | Open diff transient menu |
| `g` | `magit-refresh` | Refresh buffer |
| `q` | `magit-mode-bury-buffer` | Go back / quit view |
| `$` | `magit-process-buffer` | Show process log |
| `B` | `magit-blame` | Enter blame mode |
| `Enter` | `magit-visit-thing` | Open/visit thing at cursor |
| `+`/`-` | `magit-diff-more/less-context` | Adjust diff context lines |

#### 2.3 Extend JS KeyNav hook

Update `assets/js/app.js` to send richer events:

```javascript
this.pushEvent("keydown", {
  key: e.key,
  ctrl: e.ctrlKey,
  meta: e.metaKey,
  shift: e.shiftKey
});
```

The LiveView handler resolves the current mode and section type from assigns, then calls `Navigation.handle_key(mode, section_type, key, nav)`.

---

### Phase 3: Diff Rendering Pipeline

**Why third:** With sections and keymaps in place, we can build proper diff rendering that creates section trees and responds to context-sensitive keys.

**Magit reference:** `magit-diff.el` (wash at 2574, paint at 3546, refine at 3701), `magit-apply.el` (hunk staging at 192, region staging at 206)

**Decision:** Use `git --word-diff=porcelain` for word-level diffs; `git apply --cached` for hunk staging.

#### 3.1 Three-phase rendering

| Phase | Magit | term_diff |
|-------|-------|-----------|
| **Wash** | `magit-diff-wash-diff` parses git output into section tree | Existing `Diff.parse/1` builds `FileDiff`/`Hunk`/`DiffLine`. Extend to build section tree. |
| **Paint** | `magit-section-paint` applies faces per line type | LiveView components apply Tailwind classes: `text-green-400` for additions, `text-red-400` for deletions. Already working. |
| **Refine** | `magit-diff-update-hunk-refinement` adds word-level diffs | New: parse `git diff --word-diff=porcelain` output into inline `{:add, text}` / `{:del, text}` spans within `DiffLine`. |

#### 3.2 Word-level diffs

```elixir
# In Runner
def word_diff(repo_path, opts \\ []) do
  args = ["diff", "--word-diff=porcelain"] ++ opts
  {output, 0} = System.cmd("git", args, cd: repo_path)
  output
end

# In Diff module -- parse porcelain format:
# ~[deleted text]  = deletion
# {+added text+}   = addition
# unchanged text   = context within line
```

#### 3.3 Hunk-level staging

```elixir
# In Runner
def apply_hunk(repo_path, file_diff, hunk, direction \\ :stage) do
  patch = PatchBuilder.build_hunk_patch(file_diff, hunk)
  args = case direction do
    :stage   -> ["apply", "--cached", "-"]
    :unstage -> ["apply", "--cached", "--reverse", "-"]
  end
  run_with_stdin(repo_path, args, patch)
end

def run_with_stdin(repo_path, args, stdin) do
  port = Port.open({:spawn_executable, git_path()},
    [:binary, :exit_status, args: args, cd: repo_path])
  Port.command(port, stdin)
  Port.command(port, "")  # EOF
  collect_output(port)
end
```

**Patch construction** (mirrors `magit-apply-hunk` at line 192):
1. Extract file diff header (`diff --git a/... b/...`, `index ...`, `--- a/...`, `+++ b/...`)
2. Append hunk content (`@@ ... @@` header + all lines)
3. Adjust hunk new-start offset if hunk is not the first in the file

#### 3.4 Region-level (partial hunk) staging

For staging individual lines within a hunk:
1. User selects lines (future: visual selection mode)
2. Build a synthetic hunk containing only selected `+`/`-` lines plus required context
3. Adjust line counts in `@@` header
4. Pipe to `git apply --cached`

#### 3.5 Syntax highlighting

Add `makeup` dependency for Elixir syntax highlighting within diff hunks. Detect language from file extension, tokenize the line content (stripping the `+`/`-` prefix), apply token CSS classes.

---

### Phase 4: Process Integration

**Why fourth:** Every git operation (staging, committing, rebasing) needs reliable process execution. Async execution enables responsive UI during long operations.

**Magit reference:** `magit-process.el` (async at 597, sentinel at 849, process log at 767)

#### 4.1 Async git execution

```elixir
def async_run(repo_path, args, opts \\ []) do
  Task.Supervisor.async_nolink(TermDiff.TaskSupervisor, fn ->
    result = System.cmd("git", args, cd: repo_path, stderr_to_stdout: true)
    Phoenix.PubSub.broadcast(TermDiff.PubSub, "git_events", {:git_complete, args, result})
    result
  end)
end
```

#### 4.2 Auto-refresh after mutations

After any mutation (`commit`, `stage`, `unstage`, `rebase --continue`, etc.), broadcast a `:git_mutation` event. `DiffLive` subscribes and triggers a full refresh -- mirroring `magit-process-sentinel` calling `magit-refresh` on completion.

#### 4.3 Process log

Store recent git commands in a ring buffer:

```elixir
%GitCommand{
  args: ["commit", "-m", "fix bug"],
  exit_code: 0,
  duration_ms: 142,
  output_preview: "1 file changed, 3 insertions(+)",
  timestamp: ~U[2026-03-20 12:30:00Z]
}
```

Accessible via `$` key (matching Magit). Renders as a scrollable section list.

---

### Phase 5: Transient Menu System

**Why fifth:** With keymaps and process integration in place, transient menus add the composable command interface that makes Magit powerful. Instead of hardcoded `cc` for commit, users press `c` to see all commit options with toggleable flags.

**Magit reference:** `magit-transient.el` (support classes), `magit-commit.el` (line 143), `magit-sequence.el` (line 523)

**Decision:** Navigation focus mode with dedicated menu rendering.

#### 5.1 TransientMenu struct

```elixir
defmodule TermDiff.Transient.Menu do
  defstruct [:name, :groups]

  defmodule Group do
    defstruct [:title, :items]
  end

  defmodule Infix do
    defstruct [:key, :description, :flag, :active]
  end

  defmodule Suffix do
    defstruct [:key, :description, :action, :if_predicate]
  end
end
```

#### 5.2 Menu definitions

**Commit menu** (pressing `c`):
```
Arguments:  -a Stage all  -v Verbose  -s Sign
Create:     c Commit  a Amend  e Extend
Edit HEAD:  r Reword  s Squash  A Augment
```

**Rebase menu** (pressing `r`):
```
Arguments:  -i Interactive  --autostash
Rebase:     u Upstream  p Pushremote  e Elsewhere
Edit:       i Interactively  s Subset  w Reword  m Modify
In-progress: c Continue  s Skip  a Abort    [shown only during active rebase]
```

#### 5.3 Navigation integration

Add `:transient_menu` to the focus enum. When active:
- Render menu as a bottom panel with key hints
- Letter keys toggle infixes or execute suffixes
- `Escape` or `q` dismisses the menu
- Accumulated flags are passed to the Runner function

Conditional display: check git state (e.g., `rebase-merge` dir exists) to show in-progress vs new-operation menus, mirroring `:if-not magit-rebase-in-progress-p`.

---

### Phase 6: Log and Graph

**Why sixth:** Independent feature that builds on sections and keymaps.

**Magit reference:** `magit-log.el` (wash at 1385, graph at 1189, margin at 1681, parent nav at 952)

#### 6.1 Rich log format

Replace current `--oneline` with:

```bash
git log --graph --format='%h%x00%an%x00%ar%x00%s' -n 256
```

Parse into `%LogEntry{hash, author, date, subject, graph_chars}`.

#### 6.2 Graph rendering

Parse ASCII graph characters (`|`, `*`, `/`, `\`, space) from git's `--graph` output. Render as HTML with color-coded branch lines using CSS `border-left` or inline SVG.

#### 6.3 Margin columns

Display alongside each commit:

```
* abc1234  John Doe   2 hours ago   Fix login bug
|
* def5678  Jane Smith 1 day ago     Add auth module
```

#### 6.4 Dynamic limits

- `+` key doubles visible commit count
- `-` key halves it
- `p` navigates to parent commit in the log

---

### Phase 7: Blame / Time-Machine

**Why seventh:** Independent feature. Provides the "who changed this line and when" capability with history traversal.

**Magit reference:** `magit-blame.el` (chunk class at 248, mode at 326, styles at 39, navigation at 877)

#### 7.1 BlameChunk struct

```elixir
defmodule TermDiff.Blame.Chunk do
  defstruct [
    :orig_rev,       # commit that introduced these lines
    :orig_line,      # line number in original file
    :final_line,     # line number in current file
    :num_lines,      # consecutive lines in chunk
    :prev_rev,       # previous revision (for time travel)
    :prev_file,      # previous filename (may differ from current)
    :author,
    :author_time,
    :summary
  ]
end
```

Parse from `git blame --porcelain` output.

#### 7.2 Display styles

Three cycleable styles (press `c` in blame mode):

| Style | Display |
|-------|---------|
| **Headings** | `%-20s %s %s` format string above each chunk: author, date, summary |
| **Highlight** | Background color on first line of each chunk, no header |
| **Lines** | Thin colored left border per chunk, commit hash in margin |

Color chunks by commit age: recent = bright, old = dim.

#### 7.3 Time travel

The key insight from Magit: each blame chunk has `prev_rev` and `prev_file`. To "blame the blame":

1. User presses `b` on a blame chunk
2. Read `prev_rev` and `prev_file` from current chunk
3. Run `git blame --porcelain <prev_rev> -- <prev_file>`
4. Push current state onto a blame history stack
5. Display new blame data

Press `q` to pop the stack and return to previous blame state. This enables traversing backward through the entire history of any line.

Three blame directions:
- **Addition** (`b`): Normal blame -- who added each line
- **Removal** (`r`): `git blame --reverse` -- when was each line removed
- **Reverse** (`f`): Show when lines were introduced going forward from a given revision

#### 7.4 Blame navigation keys

```
n/p       Next/previous chunk
N/P       Next/previous chunk from same commit
b         Blame addition (go deeper in history)
r         Blame removal
f         Blame reverse
c         Cycle display style
q         Quit blame / pop history stack
Enter     Show commit details for current chunk
M-w       Copy commit hash
```

---

### Phase 8: Interactive Rebase

**Why last:** Most complex feature, depends on transient menus and process integration.

**Magit reference:** `magit-sequence.el` (line 523-570 for transient, 670-704 for editor hijack, 1059-1122 for conflict states), `git-rebase.el` (line 147 for keymap, 760 for mode)

#### 8.1 GIT_SEQUENCE_EDITOR interception

Magit's key trick: set `GIT_SEQUENCE_EDITOR` to a script that captures the rebase todo file instead of opening `$EDITOR`.

```elixir
def rebase_interactive(repo_path, commit, args \\ []) do
  # Create temp file to receive the todo list
  todo_path = Path.join(System.tmp_dir!(), "term_diff_rebase_todo")

  # Editor script that copies todo to our temp file
  editor = "cp \"$1\" #{todo_path}"

  env = [{"GIT_SEQUENCE_EDITOR", editor}]
  System.cmd("git", ["rebase", "-i" | args] ++ [commit],
    cd: repo_path, env: env)

  # Read and parse the todo
  File.read!(todo_path) |> RebaseTodo.parse()
end
```

#### 8.2 RebaseTodo struct

```elixir
defmodule TermDiff.Rebase.Todo do
  defstruct [:entries]

  defmodule Entry do
    defstruct [:action, :hash, :subject]
    # action: :pick | :reword | :edit | :squash | :fixup | :drop
  end
end
```

#### 8.3 Rebase editor view

Display the todo list with single-key action changes:

```
pick   abc1234  Add login page
reword def5678  Fix typo (was: Fxi tpyo)
squash ghi9012  Polish CSS
drop   jkl3456  Debug logging
```

Keys:
- `p` = pick, `r` = reword, `e` = edit, `s` = squash, `f` = fixup, `d` = drop
- `M-p` / `M-n` = reorder entries (move up/down)
- `Enter` = execute the rebase with modified todo
- `q` = abort

#### 8.4 Rebase status in status buffer

During an active rebase, show a section in the status view:

```
Rebasing  main onto upstream/main
  done   pick abc1234 Add login page
  stop   reword def5678 Fix typo          [join: unresolved conflicts]
  todo   squash ghi9012 Polish CSS
  todo   pick jkl3456 Final cleanup
```

Conflict state indicators (from `magit-sequence-insert-sequence`):
- **join** -- unresolved conflicts, needs manual resolution
- **goal** -- staged changes match target
- **void** -- commit's changes no longer apply
- **same** -- patch content preserved exactly
- **work** -- ongoing modifications exist

Actions: `c` = continue, `s` = skip, `a` = abort (via transient menu).

---

## Dependency Graph

```
Section System ──────────────────────────────────────┐
     |                                                |
     v                                                v
Mode/Keymap Hierarchy                         Diff Rendering Pipeline
     |                                          |          |
     v                                          v          v
Transient Menus ──────────> Interactive Rebase   |    Process Integration
                                   ^             |          |
                                   |             v          v
                                   └── Process Integration ─┘

Log/Graph ─────── (independent, needs sections)
Blame/Time-Machine ─── (independent, needs sections + keymaps)
```

## Summary

| Phase | System | New Files | Modified Files | Est. Nodes |
|-------|--------|-----------|---------------|-----------|
| 1 | Section System | `section.ex`, `section_tree.ex` | `navigation.ex`, `diff_live.ex` | 14 |
| 2 | Keymaps | -- | `navigation.ex`, `app.js` | 10 |
| 3 | Diff Pipeline | `patch_builder.ex` | `diff.ex`, `runner.ex`, `diff_live.ex` | 14 |
| 4 | Process | -- | `runner.ex`, `watcher.ex` | 7 |
| 5 | Transient Menus | `transient/menu.ex`, `transient/definitions.ex` | `navigation.ex`, `diff_live.ex` | 10 |
| 6 | Log/Graph | `git/graph.ex` | `log.ex`, `runner.ex`, `diff_live.ex` | 8 |
| 7 | Blame | `blame/chunk.ex`, `blame/parser.ex` | `runner.ex`, `navigation.ex`, `diff_live.ex` | 9 |
| 8 | Rebase | `rebase/todo.ex`, `rebase/editor.ex` | `runner.ex`, `navigation.ex`, `diff_live.ex` | 8 |

**Total: 81 deciduous nodes, 92 edges, 8 systems, ~10 new files, ~7 modified files.**

---

*Generated from deciduous decision graph. View with `deciduous serve`. Query specific systems with `deciduous nodes`.*

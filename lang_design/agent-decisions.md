# Agent Decision Trees: Coordination, Recovery, and Merge

> "each agent would have a deciduous tree, and the deciduous trees could merge and diverge and do whatever else needed as the work overlapped -- and the user has one too"

## The Problem

Right now agents are fire-and-forget. You send a prompt, it runs, it finishes. If an agent dies halfway through figuring something out, that reasoning is lost. If two agents are working on related things, they don't know about each other. The human is the only one who sees the full picture.

We want:
1. Every agent's reasoning is captured as a decision subtree
2. Dead agent reasoning is recoverable
3. Active agents know when their work overlaps with another agent's work
4. The user can merge agent decisions into the main decision graph

## Design

### Every Agent Gets a Root Node

When an agent run is created (via the multiplexer, the diff-to-agent flow, or API), a deciduous goal node is created and its ID is stored on the run record.

```
Run #42
  prompt: "refactor the parser to handle spawn expressions"
  deciduous_root: 1285    <-- root goal node in the decision graph
  status: running
```

The agent's system prompt includes an instruction to log decisions under this root:

```
You are working on a task. Your decision tree root is node #1285.
Log all goals, options, decisions, actions, and outcomes as children
of this root using deciduous. Example:

  deciduous add action "Modify parser.zig" -c 85
  deciduous link 1285 <new_node_id> -r "Implementation step"
```

This means the agent uses the same deciduous CLI that the human uses. Its decisions show up in the same graph, on the same branch, linked to the same web viewer.

### The System Prompt Injection

When the multiplexer dispatches a run, it prepends a preamble to the user's prompt:

```
[BLIMP AGENT CONTEXT]

You are Agent #42 working in the Blimp project.
Your decision tree root is deciduous node #1285.

Before starting work:
  1. Check for active agents on related files:
     deciduous nodes --branch <current-branch> | grep "active"
  2. Read recent decisions for context:
     deciduous show 1285

While working:
  - Log every action BEFORE doing it: deciduous add action "..." -c N
  - Link it to your root: deciduous link 1285 <node_id>
  - Log outcomes AFTER: deciduous add outcome "..." -c N

When done:
  - Mark your root node as complete
  - Summarize what you decided and why

Active agents on related work:
  Agent #38 (node #1270): "update type checker for spawn expressions"
    -- Working on: checker.zig, types.zig
    -- Status: running
  Agent #40 (node #1278): "add tree-sitter tests for spawn"
    -- Working on: tree-sitter-blimp/
    -- Status: completed

[END BLIMP AGENT CONTEXT]
```

### Overlap Detection

Before injecting context, the multiplexer queries deciduous for active goals on the current branch:

```elixir
# In the Orchestrator, before dispatching:
active_nodes = deciduous_nodes(branch: current_branch, status: "pending")
related = find_related_nodes(active_nodes, run.prompt, run.repo_path)
```

"Related" means:
- Goals that mention the same files (via `-f` flag on deciduous nodes)
- Goals whose title shares significant keywords with the new prompt
- Goals on the same branch

The related nodes are included in the system prompt so the new agent knows what's already being worked on.

### Dead Agent Recovery

When an agent dies (crashes, gets cancelled, times out):

1. Its deciduous subtree stays in the graph. Nodes are never deleted.
2. The run record keeps the `deciduous_root` ID.
3. The multiplexer UI shows a "Recover decisions" button on dead runs.
4. Clicking it shows the subtree: what the agent figured out, what it tried, what worked.
5. The user (or a new agent) can:
   - Read the dead agent's decisions for context
   - Link useful decisions into the main graph
   - Resume with a new agent that starts from the dead agent's last outcome

```
# In the REPL / multiplexer:
Agent #42 died after 3 minutes.
Decision tree (root #1285):
  #1285 goal: "refactor parser for spawn" (pending)
    #1286 action: "read current parser.zig" (complete)
      #1287 outcome: "parser uses recursive descent, 1641 lines"
    #1288 action: "add kw_spawn to token.zig" (complete)
      #1289 outcome: "token added, compiles clean"
    #1290 action: "add parseSpawnExpr to parser" (pending)  <-- died here

# The user can tell a new agent:
"Continue from where Agent #42 left off. See deciduous node #1285."
```

### Decision Tree Merge

When two agents complete related work, their subtrees can be merged:

```
Agent #42 tree:                Agent #43 tree:
  goal: refactor parser          goal: add spawn tests
    action: modify parser.zig      action: add spawn.txt corpus
    outcome: spawn parses           outcome: 63/63 tests pass
    action: modify ast.zig          action: update highlights
    outcome: SpawnExpr added        outcome: spawn highlighted
```

The user reviews both and links outcomes that validate each other:

```
deciduous link 1289 1295 -r "Parser change validated by tests"
```

Now the graph shows that the parser refactor is validated by the test suite. The reasoning chains are connected.

### Conflict Detection

If two agents make conflicting decisions:

```
Agent #42: "Use comma syntax for spawn overrides: spawn Counter, count: 10"
Agent #43: "Use paren syntax for spawn overrides: spawn Counter(count: 10)"
```

Deciduous can detect this if both agents create decision nodes about the same construct. The multiplexer surfaces the conflict:

```
CONFLICT DETECTED:
  Agent #42 (node #1292): chose comma syntax
  Agent #43 (node #1298): chose paren syntax

Both are valid. Which do you want?
  [1] Comma syntax (spawn Counter, count: 10)
  [2] Paren syntax (spawn Counter(count: 10))
```

The user resolves it. The resolution is captured as a decision node linking to both options.

## Implementation

### Phase 1: Root Node on Runs

**Database**: Add `deciduous_root` integer column to runs table.

**Orchestrator**: When dispatching a run, create a deciduous goal node:
```elixir
{:ok, node_id} = Deciduous.add_goal(run.prompt, confidence: 85)
Runs.update_run(run, %{deciduous_root: node_id})
```

**System prompt**: Prepend the agent context preamble with the root node ID.

### Phase 2: Overlap Detection

**Before dispatch**: Query deciduous for active nodes on the branch.
**Match**: Compare file lists and title keywords.
**Inject**: Include related agent info in the system prompt.

### Phase 3: Dead Agent Recovery UI

**Multiplexer**: "View decisions" button on completed/failed/cancelled runs.
**Display**: Fetch the subtree from deciduous and render as a tree view.
**Resume**: "Continue from here" button that creates a new run with context.

### Phase 4: Merge and Conflict

**Merge**: UI to link outcomes across agent subtrees.
**Conflict**: Detect overlapping decisions, surface to user.
**Resolution**: Capture user's choice as a decision node.

## Files

```
# Database
priv/repo/migrations/xxx_add_deciduous_root_to_runs.exs

# Orchestrator changes
lib/term_diff/agent/orchestrator.ex    -- create root node on dispatch
lib/term_diff/agent/runner/claude_code.ex -- prepend system prompt

# LiveView
lib/term_diff_web/live/agent_live.ex   -- "View decisions" button
lib/term_diff_web/components/agent_components.ex -- decision tree render

# Deciduous integration
lib/term_diff/agent/deciduous.ex       -- wrapper around deciduous CLI
```

## Open Questions

- Should agents be able to READ each other's decision trees in real time, or only see a snapshot at dispatch time?
- Should the overlap detection be keyword-based, file-based, or use embedding similarity?
- Should agents be able to WRITE to each other's subtrees (collaborative), or only to their own (isolated)?
- How much deciduous context is too much? The system prompt injection shouldn't be 500 lines of prior decisions.
- Should the deciduous root node be created by the multiplexer (Elixir) or by the agent itself on first message?

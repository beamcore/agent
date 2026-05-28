# Beamcore.Alignment

Deterministic agent coordination server for multi-agent systems. Prevents wasted tokens and duplicate work when multiple agents unknowingly attempt the same task or similar work on the same files within the same repository.

## Key Insight

**Alignment is not a tool that agents call directly** — agents will forget about it or misuse it. Instead, it is a **guard layer** that the harness (or orchestrator) queries to determine if similar work is already happening in the organization. This design ensures that coordination happens at the system level, not at the agent level.

## Purpose

In multi-agent environments, multiple agents may be assigned similar tasks or may independently decide to work on the same files. Without coordination, this leads to:

- **Wasted tokens**: Multiple agents processing the same file content
- **Race conditions**: Conflicting edits to the same files
- **Redundant work**: Duplicate analysis or transformations
- **Inconsistent state**: Agents working on stale file versions

The Alignment server solves these problems by providing a centralized coordination point that tracks which agents are working on which files, and computes a **conflict score** to help the harness decide whether to proceed, wait, or abort.

## Architecture

`Beamcore.Alignment` is implemented as a **GenServer** — a concurrent, stateful process in Elixir's OTP framework. This provides:

- **Isolated state**: File claims are maintained in a single, consistent state
- **Concurrent access**: Multiple harnesses/agents can query and update claims safely
- **Fault tolerance**: The server can be supervised and restarted if needed
- **Simple API**: Clean separation between client calls and server logic

### Process Lifecycle

```
┌─────────────────────────────────────────────────────────┐
│                    GenServer Process                       │
│  ┌─────────────────────────────────────────────────────┐│
│  │                    State                                ││
│  │  %{path => %{agent: name, hash: hash, timestamp: t}}   ││
│  └─────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────┘
         ▲                          ▲                          ▲
         │ claim_file/3             │ release_file/2            │ list_claims/0
         │ (synchronous call)       │ (asynchronous cast)       │ (synchronous call)
         └──────────────────────────┴──────────────────────────┘
```

## State Structure

The server maintains a simple but effective state:

```elixir
%{
  "lib/myapp/file1.ex" => %{
    agent: "agent_42",
    hash: "abc123...",
    timestamp: ~U[2024-01-15 10:30:00Z]
  },
  "lib/myapp/file2.ex" => %{
    agent: "agent_7",
    hash: "def456...",
    timestamp: ~U[2024-01-15 10:25:00Z]
  }
}
```

Each entry tracks:
- **path**: The workspace-relative file path being worked on
- **agent**: The unique identifier of the agent that claimed the file
- **hash**: A content hash of the file at the time of claiming (used for detecting same-content conflicts)
- **timestamp**: When the claim was made (used for recency calculations)

## API Reference

### `claim_file(path, agent_name, file_hash)`

Attempts to claim a file for an agent. Returns one of:

- ` {:ok, :claimed} ` — File was not claimed by anyone; now claimed by this agent
- ` {:ok, :already_claimed} ` — File was already claimed by this same agent; claim refreshed
- ` {:conflict, score, other_agent} ` — File is claimed by another agent; includes conflict score

**Parameters:**
- `path` (String): Workspace-relative file path (e.g., `"lib/myapp/module.ex"`)
- `agent_name` (String): Unique identifier for the agent making the claim
- `file_hash` (String): Content hash of the file being claimed

**Usage:**
```elixir
case Beamcore.Alignment.claim_file("lib/app.ex", "agent_1", "abc123") do
  {:ok, :claimed} -> {:continue, :proceed}
  {:ok, :already_claimed} -> {:continue, :proceed}
  {:conflict, score, other} -> 
    if score >= 80 do
      {:block, :duplicate_work_detected}
    else
      {:continue, :proceed_with_caution}
    end
end
```

### `release_file(path, agent_name)`

Releases a file claim for an agent. Only the claiming agent can release its own claims.

**Parameters:**
- `path` (String): The file path to release
- `agent_name` (String): The agent releasing the claim

**Behavior:**
- If the file is claimed by the specified agent, the claim is removed
- If the file is claimed by a different agent, or not claimed at all, no action is taken
- This is an asynchronous operation (cast), so it doesn't block the caller

### `list_claims()`

Returns the complete map of all active file claims.

**Returns:**
```elixir
%{
  "path/to/file1.ex" => %{agent: "agent_a", hash: "...", timestamp: ~U[...]},
  "path/to/file2.ex" => %{agent: "agent_b", hash: "...", timestamp: ~U[...]}
}
```

### `clear_claims()`

Clears all active file claims. Useful for resetting state between sessions or in testing scenarios.

**Note:** This is an asynchronous operation (cast).

## Conflict Scoring Algorithm

When a file is already claimed by another agent, the server computes a **conflict score** (0-100) to indicate how likely the work is to be redundant. Higher scores mean higher confidence that the agents are doing duplicate work.

### Score Components

| Component | Points | Condition |
|-----------|--------|-----------|
| Base | 50 | Always applied |
| Hash Match | +30 | Same file content hash |
| Recent (≤5 min) | +20 | Claim was made within 5 minutes |
| Recent (≤15 min) | +10 | Claim was made within 15 minutes |

### Score Calculation

```elixir
base_score = 50

hash_score = if file_hash == other_hash, do: 30, else: 0

time_diff_secs = DateTime.diff(now, other_timestamp, :second)

recency_score =
  cond do
    time_diff_secs <= 300 -> 20    # Within 5 minutes
    time_diff_secs <= 900 -> 10    # Within 15 minutes
    true -> 0
  end

score = base_score + hash_score + recency_score
```

### Score Interpretation

| Score Range | Meaning | Recommended Action |
|-------------|---------|-------------------|
| 100 | Same file, same content, very recent | **Block** — definite duplicate work |
| 80-99 | Same file, same content, recent | **Block or wait** — likely duplicate |
| 70-79 | Same file, different content, very recent | **Warn user** — possible duplicate |
| 60-69 | Same file, different content, recent | **Proceed with caution** |
| 50-59 | Same file, different content, older | **Proceed** — low conflict risk |
| <50 | Should not occur (base is 50) | **Proceed** |

### Example Scenarios

```
Scenario 1: Same agent, same file
  Agent A claims file X
  Agent A claims file X again
  → {:ok, :already_claimed} (no conflict)

Scenario 2: Different agents, same file, same hash, 2 minutes ago
  Agent A claims file X (hash: abc, time: now-2min)
  Agent B claims file X (hash: abc)
  Score = 50 + 30 + 20 = 100
  → {:conflict, 100, "Agent A"}

Scenario 3: Different agents, same file, different hash, 10 minutes ago
  Agent A claims file X (hash: abc, time: now-10min)
  Agent B claims file X (hash: def)
  Score = 50 + 0 + 10 = 60
  → {:conflict, 60, "Agent A"}

Scenario 4: Different agents, same file, different hash, 30 minutes ago
  Agent A claims file X (hash: abc, time: now-30min)
  Agent B claims file X (hash: def)
  Score = 50 + 0 + 0 = 50
  → {:conflict, 50, "Agent A"}
```

## Usage Pattern

The Alignment server is designed to be used by a **harness** or **orchestrator**, not by agents directly. Here's the typical flow:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────────┐
│   Agent     │     │  Harness    │     │  Alignment      │
│             │     │             │     │  (GenServer)    │
└──────┬──────┘     └──────┬──────┘     └────────┬────────┘
       │                   │                      │
       │  edit("lib/a.ex")  │                      │
       │──────────────────>│                      │
       │                   │ query: claim_file?    │
       │                   │────────────────────>│
       │                   │                      │
       │                   │  {:conflict, 85, A1} │
       │                   │<────────────────────│
       │                   │                      │
       │                   │  Decision: BLOCK      │
       │                   │                      │
       │  "Cannot edit:    │                      │
       │   Agent A1 is     │                      │
       │   working on      │                      │
       │   lib/a.ex"       │                      │
       │<──────────────────│                      │
       │                   │                      │
```

### Harness Integration Example

```elixir
defmodule MyHarness do
  def handle_agent_tool_call(agent_name, {:edit, path, _content}) do
    # Get file hash
    file_hash = File.read!(path) |> :erlang.crc32() |> to_string()
    
    # Check with alignment
    case Beamcore.Alignment.claim_file(path, agent_name, file_hash) do
      {:ok, :claimed} ->
        # Proceed with the edit
        perform_edit(agent_name, path)
        
      {:ok, :already_claimed} ->
        # Already claimed by this agent, proceed
        perform_edit(agent_name, path)
        
      {:conflict, score, other_agent} ->
        if score >= 80 do
          # High conflict: block and notify
          notify_agent(agent_name, "Cannot edit #{path}: #{other_agent} is already working on it (score: #{score})")
          {:blocked, :duplicate_work}
        else
          # Low conflict: warn but proceed
          notify_agent(agent_name, "Warning: #{other_agent} is working on #{path} (score: #{score})")
          perform_edit(agent_name, path)
        end
    end
  end
  
  def handle_agent_complete(agent_name, path) do
    # Release the claim when done
    Beamcore.Alignment.release_file(path, agent_name)
  end
end
```

## Starting the Server

The Alignment server is started automatically when the application boots, via the supervision tree:

```elixir
# In your application.ex
children = [
  Beamcore.Alignment,
  # ... other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Or manually:

```elixir
Beamcore.Alignment.start_link()
```

## Testing

The module includes comprehensive tests in `test/agent/alignment_test.exs` covering:
- Basic claim/release cycles
- Conflict detection with various scores
- Same-agent re-claims
- State isolation
- Concurrent access patterns

## Design Decisions

### Why GenServer?

We chose GenServer because:
1. **State isolation**: File claims need to be consistent across all agents
2. **Concurrency**: Multiple agents can safely query and update claims
3. **OTP integration**: Fits naturally with Elixir's supervision and fault tolerance
4. **Simplicity**: The problem domain (stateful coordination) maps perfectly to GenServer

### Why Not Agent-Called?

Agents calling alignment directly would lead to:
- **Forgetfulness**: Agents might forget to check or release claims
- **Misuse**: Agents might ignore conflict scores or game the system
- **Complexity**: Each agent would need coordination logic
- **Inconsistency**: Different agents might implement different policies

By making it a **harness-level concern**, we ensure consistent, reliable coordination.

### Why the Scoring System?

A simple boolean ("conflict or not") would be too coarse. The scoring system allows the harness to:
- Make nuanced decisions based on confidence level
- Apply different thresholds for different scenarios
- Provide useful feedback to users about why work was blocked
- Handle edge cases (same file, different content) appropriately

### Why Time-Based Decay?

File claims that are old are less relevant. An agent that claimed a file 2 hours ago is probably done with it. The time-based scoring ensures that:
- Recent claims get higher priority
- Stale claims naturally decay in importance
- The system self-cleans without explicit cleanup

## Future Enhancements

Potential improvements to consider:

1. **TTL-based auto-release**: Automatically release claims after a configurable timeout
2. **Path pattern matching**: Support glob patterns for claiming multiple files at once
3. **Agent priority**: Allow higher-priority agents to preempt lower-priority ones
4. **Distributed coordination**: Extend to work across multiple nodes in a cluster
5. **Persistent state**: Store claims in a database for survival across restarts
6. **Metrics**: Track conflict rates, claim durations, and other operational data

## Summary

`Beamcore.Alignment` provides a simple, robust solution for coordinating multiple agents working on the same codebase. By tracking file claims and computing conflict scores, it enables the harness to prevent duplicate work, reduce token waste, and maintain consistency across the system.

**Key takeaways:**
- Agents don't call alignment; the harness does
- Conflict scores (0-100) indicate likelihood of duplicate work
- Higher scores = higher confidence = more reason to block
- Simple GenServer-based architecture with clean API
- Designed for integration, not direct agent use

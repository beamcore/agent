# Session Strategy for 150K Context Coding Agent

## Overview
This document outlines a **context-aware session management strategy** for a coding agent constrained to a **150K token context window**. The goal is to maximize efficiency, minimize redundancy, and ensure the agent can handle complex, multi-file projects without losing critical state.

---

## Core Principles

### 1. **Context Budgeting**
- **Total Budget**: 150K tokens.
- **Reserved for System Prompt**: ~10K tokens (e.g., instructions, conventions, and constraints).
- **Remaining for Session**: ~140K tokens.
- **Dynamic Allocation**: Context is dynamically allocated based on priority and recency.

### 2. **Context Segmentation**
Divide the context into **tiered segments** with strict priorities:

| Tier | Purpose | Max Tokens | Priority | Eviction Policy |
|------|---------|------------|----------|-----------------|
| T0 | **Active Task** | 50K | Highest | Never evicted unless explicitly cleared |
| T1 | **Working Files** | 40K | High | LRU (Least Recently Used) |
| T2 | **Project Structure** | 20K | Medium | LRU |
| T3 | **Dependencies & Configs** | 20K | Low | LRU |
| T4 | **Historical Context** | 10K | Lowest | FIFO (First-In-First-Out) |

---

## Tiered Context Management

### **T0: Active Task (50K Tokens)**
- **Purpose**: The current task, its requirements, and intermediate state (e.g., partial code, errors, or debug output).
- **Contents**:
  - User prompt (compressed if necessary).
  - Task-specific instructions.
  - Intermediate results (e.g., code snippets, test outputs).
  - Active sub-tasks (if delegated).
- **Management**:
  - **Never evicted** unless the task is explicitly marked as complete or abandoned.
  - If T0 exceeds 50K, compress or summarize older parts.

### **T1: Working Files (40K Tokens)**
- **Purpose**: Files actively being edited or referenced in the current task.
- **Contents**:
  - Full content of **up to 3-5 files** (prioritized by recency and relevance).
  - Diffs or patches for modified files.
- **Management**:
  - **LRU Eviction**: If a file hasn't been accessed in the last N turns, it is evicted to T3 or discarded.
  - **Compression**: For large files, only load **relevant sections** (e.g., functions, classes, or modules) instead of the entire file.
  - **Lazy Loading**: Load file content on-demand when referenced.

### **T2: Project Structure (20K Tokens)**
- **Purpose**: High-level overview of the project's architecture.
- **Contents**:
  - Directory tree (compact representation).
  - Key module dependencies (e.g., `mix.exs` for Elixir).
  - Critical configuration files (e.g., `config.exs`).
  - Summary of core modules/interfaces.
- **Management**:
  - **Static Summary**: Pre-generate a **compressed project summary** (e.g., "Module A depends on B and C, implements X").
  - **LRU Eviction**: Less critical files are evicted first.

### **T3: Dependencies & Configs (20K Tokens)**
- **Purpose**: External dependencies, library documentation, and non-critical configs.
- **Contents**:
  - Snippets of dependency code (e.g., Hex package docs).
  - Relevant parts of `mix.lock` or `package.json`.
  - Environment-specific configs.
- **Management**:
  - **Lazy Loading**: Only load dependency docs when explicitly needed.
  - **LRU Eviction**: Aggressively evict if unused for >5 turns.

### **T4: Historical Context (10K Tokens)**
- **Purpose**: Past interactions, decisions, and lessons learned.
- **Contents**:
  - Summaries of completed tasks.
  - Key decisions (e.g., "Chose GenServer over Agent for X").
  - Error logs or debug traces (compressed).
- **Management**:
  - **FIFO Eviction**: Oldest entries are evicted first.
  - **Compression**: Use **1-2 sentence summaries** instead of raw logs.

---

## Context Compression Techniques

### 1. **File Chunking**
- Instead of loading entire files, load **semantic chunks** (e.g., functions, classes, or modules).
- Example: For a 10K-line file, only load the **relevant function** (e.g., 50-200 tokens).

### 2. **Summarization**
- **Automatic Summaries**: For evicted files, store a **1-2 line summary** in T4.
  - Example: `"user.ex: Defines User struct with fields :id, :name. Validates :name presence."`
- **Decision Logs**: Store **why** a change was made, not the full diff.

### 3. **Diff-Based Updates**
- For modified files, store **only the diff** instead of the full content.
- Example: Instead of reloading a 10K file, store a 200-token patch.

### 4. **Token-Efficient Formatting**
- Use **compact representations** for repetitive data:
  - Directory trees: `lib/ -> [user.ex, post.ex, utils/]`
  - Dependencies: `{:phoenix, "1.7.0"} -> "Phoenix@1.7.0"`

---

## Session Lifecycle

### 1. **Initialization**
- Load **T2 (Project Structure)** first (e.g., directory tree, `mix.exs`).
- Pre-generate **summaries** for critical files (e.g., `lib/agent.ex`).
- Reserve **T0** for the user's initial prompt.

### 2. **Task Execution**
- **Step 1**: Parse the task and allocate to **T0**.
- **Step 2**: Identify relevant files (e.g., via `grep` or user hints) and load into **T1**.
- **Step 3**: If T1 is full, evict least recently used files to **T3** or **T4** (summarized).
- **Step 4**: Execute the task, updating **T0** with intermediate state.

### 3. **Context Switching**
- If the user switches tasks:
  1. **Save T0** to **T4** as a summary.
  2. **Clear T0** and **T1** for the new task.
  3. **Reload T2** if the project structure changed.

### 4. **Cleanup**
- After task completion:
  - Move **T0** to **T4** (compressed).
  - Evict stale entries from **T1-T3** using LRU/FIFO.
  - Reclaim tokens for the next task.

---

## Eviction Policies

| Tier | Eviction Trigger | Action |
|------|------------------|--------|
| T0 | Explicit clear or task completion | Move to T4 (summarized) |
| T1 | Exceeds 40K or LRU timeout | Evict oldest file to T3 or discard |
| T2 | Exceeds 20K or LRU timeout | Evict least critical file to T4 |
| T3 | Exceeds 20K or LRU timeout | Discard or summarize to T4 |
| T4 | Exceeds 10K | Discard oldest entry (FIFO) |

---

## Sub-Agent Delegation Strategy

### **Why Delegate?**
- Sub-agents have **isolated context**, preventing pollution of the main agent's state.
- Enables **parallelism** (e.g., one sub-agent handles tests while another writes code).

### **Sub-Agent Context Allocation**
- **Main Agent**: Manages **T0-T2** (90K tokens).
- **Sub-Agents**: Allocated **10-30K tokens** each (from T3/T4 budget).
  - Example: A sub-agent for "run tests" gets 20K tokens for test files and output.

### **Delegation Rules**
1. **Task Scope**: Delegate **self-contained tasks** (e.g., "Write tests for `user.ex`").
2. **Context Hand-off**: Pass only **necessary context** to the sub-agent:
   - Relevant file chunks.
   - Task-specific instructions.
   - Dependencies (if needed).
3. **Result Integration**: Sub-agent returns:
   - **Compressed results** (e.g., test output summary).
   - **Diffs or patches** (not full files).
4. **Cleanup**: Sub-agent context is **discarded** after task completion.

### **Example Workflow**
```
User: "Add a new feature to user.ex and write tests."

1. Main Agent:
   - Allocates T0 for the task.
   - Loads `user.ex` into T1.
   - Delegates "write tests" to Sub-Agent A with:
     - `user.ex` (relevant parts).
     - Test conventions (from T2).
     - 20K token budget.

2. Sub-Agent A:
   - Writes tests in isolated context.
   - Returns test file diff (+ summary).

3. Main Agent:
   - Integrates test diff into T1.
   - Delegates "implement feature" to Sub-Agent B with:
     - `user.ex` (current state).
     - Test requirements (from Sub-Agent A).
     - 20K token budget.

4. Sub-Agent B:
   - Implements feature.
   - Returns code diff.

5. Main Agent:
   - Applies diff to `user.ex`.
   - Validates with tests (delegates to Sub-Agent C if needed).
   - Cleans up T0/T1.
```

---

## Error Handling & Recovery

### **Context Overflow**
- If total context approaches 150K:
  1. **Compress T0**: Summarize intermediate steps.
  2. **Evict T1-T3**: Using LRU/FIFO.
  3. **Warn User**: "Context is full. Saving progress and focusing on critical files."

### **Lost Context**
- If a file is evicted but needed later:
  - **Lazy Reload**: Re-read the file from disk (if unchanged).
  - **Fallback to Summaries**: Use T4 summaries to infer content.
  - **Ask User**: "Should I reload `user.ex`? It was evicted for space."

### **Sub-Agent Failures**
- If a sub-agent fails:
  - **Retry with More Context**: Allocate additional tokens from T3/T4.
  - **Fallback to Main Agent**: Handle the task directly (if context allows).

---

## Implementation Checklist

### **Phase 1: Core Session Management**
- [ ] Implement **tiered context segments** (T0-T4).
- [ ] Add **LRU/FIFO eviction** for T1-T3.
- [ ] Compress files into **semantic chunks** (e.g., per-function).
- [ ] Generate **project summaries** for T2.

### **Phase 2: Sub-Agent Orchestration**
- [ ] Define **sub-agent context budgets** (10-30K tokens).
- [ ] Implement **context hand-off** (pass only necessary data).
- [ ] Add **result compression** (diffs, summaries).
- [ ] Handle **sub-agent failures** gracefully.

### **Phase 3: Optimization**
- [ ] **Dynamic chunking**: Load only relevant parts of files.
- [ ] **Automatic summarization**: For evicted files/context.
- [ ] **Token counting**: Real-time tracking of context usage.
- [ ] **User feedback**: Warn when context is tight.

---

## Example: Context Allocation for a Task

**Task**: "Add a new `validate_email/1` function to `user.ex` and write tests."

| Tier | Contents | Tokens Used |
|------|----------|-------------|
| T0 | Task prompt + intermediate state | 5K |
| T1 | `user.ex` (full), `user_test.exs` (partial) | 30K |
| T2 | Project tree, `mix.exs` | 10K |
| T3 | `phoenix` docs (relevant parts) | 5K |
| T4 | Past task summaries | 2K |
| **Total** | | **52K** |

**Sub-Agent for Tests**:
- Input: `user.ex` (relevant parts), test conventions.
- Budget: 20K tokens.
- Output: Test file diff (5K tokens).

---

## Tools & Libraries
- **Token Counting**: Use a library like `tokenizers` (Python) or `bpe` (Elixir) to estimate token usage.
- **Compression**: Implement custom logic for:
  - File chunking (e.g., by function/class).
  - Diff generation (e.g., `git diff`).
  - Summarization (e.g., LLM-based or heuristic).

---

## Metrics to Track
1. **Context Usage**: Tokens used per tier (real-time).
2. **Eviction Rate**: How often files are evicted from T1-T3.
3. **Sub-Agent Success Rate**: % of delegated tasks completed without main agent intervention.
4. **User Satisfaction**: Feedback on context relevance and task completion.

---

## Anti-Patterns to Avoid
1. **Overloading T0**: Keep the active task focused. Offload to sub-agents.
2. **Full File Loads**: Never load a 10K-line file into T1. Use chunking.
3. **Redundant Context**: Avoid duplicating file content across tiers.
4. **Ignoring Evictions**: Always handle evictions gracefully (e.g., lazy reload).
5. **Static Context**: Dynamically adjust based on task needs.

---

## Revision History
| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-XX-XX | Initial design |

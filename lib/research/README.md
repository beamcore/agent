# Incremental Autonomous Research (IAR)

Incremental Autonomous Research (IAR) is a framework designed to enable AI agents, in partnership with deterministic code, to execute systematic, deep investigations of complex problems. Rather than attempting a linear search or broad-crawling, the IAR approach structures knowledge as an **evolving tree** that dynamically expands (explores) and contracts (generalizes) to arrive at a single synthesized solution or fact-set.

This design is optimized for **on-device / local intelligence** with limited compute capacity, balancing sequential model inference with parallel data retrieval.

---

## 1. Core Architecture

The core of IAR is based on the dialectic between **Divergence (Expansion)** and **Convergence (Contraction)**. 

```mermaid
graph TD
    Input[User Input / Query] --> Classify[Primary Classification: 2 to 5 Areas]
    
    subgraph Divergence (Exploration Phase)
        Classify --> Area1[Area 1]
        Classify --> Area2[Area 2]
        Classify --> AreaN[Area N]
        
        Area1 --> SubArea1_1[Sub-area 1.1]
        Area1 --> SubArea1_2[Sub-area 1.2]
        Area2 --> SubArea2_1[Sub-area 2.1]
        
        SubArea1_1 -.-> WebReq1[External Web Fetch / wget]
        SubArea1_2 -.-> WebReq2[External Web Fetch / wget]
    end

    subgraph Convergence (Generalization Phase)
        SubArea1_1 & SubArea1_2 --> GenArea1[Generalized Area 1 Artifact]
        SubArea2_1 --> GenArea2[Generalized Area 2 Artifact]
        GenArea1 & GenArea2 --> FinalOutcode[Single Final Outcode / md]
    end
```

### The Knowledge Tree Life Cycle
1. **Seed / Input**: The research starts with a user-supplied seed query.
2. **Divergence (Exploration)**: The seed is classified into 2 to 5 distinct research areas. Each area is dynamically expanded into sub-areas. Each sub-area undergoes evaluation:
   - **Internal Mode**: The LLM determines it has sufficient internal training knowledge to resolve the query directly.
   - **External Mode**: The LLM suggests specific URLs to fetch or queries to execute. Deterministic code executes these requests, converts the raw data to readable text, and feeds it back to the LLM.
   - The LLM creates an **Artifact** (saved as a local `.md` file) representing the knowledge for that node.
3. **Convergence (Generalization)**: Branches that are resolved ("completed") or determined to be dead-ends ("dead") are pruned or closed. When all children of a node are resolved, the coordinator triggers the LLM to generalize their contents into a single summary, closing the branch bottom-up.
4. **Outcode Synthesis**: Once all paths converge back to the root, a final synthesis produces a single comprehensive markdown document containing the final answer, facts, or solution (the "outcode").

---

## 2. Tree and Node Data Structures

To support pause/resume capability, persistence, and deterministic coordination, the research state is mapped directly to a tree structure in Elixir and serialized to the filesystem.

### Directory Structure of a Research Run
Each run creates a workspace folder structure representing the tree branches. This makes the state inspectable and persistent.

```
tmp/research/run_<run_uuid>/
├── run_state.json                # Bounded state metadata (current step, node map)
├── root.md                       # Seed query + primary classification mapping
├── area_1/
│   ├── area_1_generalization.md  # Contraction phase output for Area 1
│   ├── sub_area_1_1/
│   │   └── raw_fetch.md          # Output of wget/web request
│   │   └── artifact.md           # LLM analysis of web request
│   └── sub_area_1_2/
│       └── artifact.md           # Internal LLM research outcome
└── area_2/
    ├── area_2_generalization.md
    └── sub_area_2_1/
        └── artifact.md
```

### Elixir State Representation
The state is managed using Elixir structs, representing nodes and the coordinating state machine.

```elixir
defmodule Beamcore.Research.Node do
  @type status :: :unexplored | :gathering | :completed | :dead | :generalized

  @type t :: %__MODULE__{
    id: String.t(),
    parent_id: String.t() | nil,
    path: list(String.t()),
    topic: String.t(),
    status: status(),
    mode: :internal | {:external, list(String.t())}, # URLs or search queries
    artifact_path: String.t() | nil,
    children_ids: list(String.t())
  }

  defstruct [:id, :parent_id, :path, :topic, :status, :mode, :artifact_path, :children_ids]
end

defmodule Beamcore.Research.Tree do
  alias Beamcore.Research.Node

  @type t :: %__MODULE__{
    run_id: String.t(),
    root_node_id: String.t(),
    nodes: %{String.t() => Node.t()},
    step_count: integer(),
    status: :idle | :expanding | :contracting | :done | :failed
  }

  defstruct [:run_id, :root_node_id, :nodes, :step_count, :status]
end
```

---

## 3. Concurrency Model: Sequential LLM vs. Parallel Fetching

On-device LLMs are typically resource-constrained (e.g., running locally via Llama.cpp, Ollama, or Apple Silicon hardware). Concurrently invoking multiple LLM inferences causes execution bottlenecks, high latency, or out-of-memory crashes.

```
                   [Coordinator]
                  /             \
       [Task: Parallel Web]     [Task: Parallel Web]
       (Fetch URL A via wget)   (Fetch URL B via wget)
                  \             /
                   [Join/Merge]
                        |
            [Sequential Local LLM Call]
```

### Execution Strategy
1. **Strictly Sequential LLM Calls**: All classification, assessment, and generalization steps requiring LLM inference are processed one by one. The coordinator maintains a queue of evaluation jobs and dispatches them sequentially.
2. **Parallel Non-LLM Calls**: Gathering information (such as HTTP GET requests, curl/wget, codebase searches, and local document parsers) is executed in parallel using Elixir's lightweight processes (`Task.async_stream/3` or dynamic task supervision).
3. **Synchronization Barrier**: Once all parallel web fetches for a set of nodes are complete, the outputs are queued for sequential processing by the on-device LLM.

---

## 4. Unbounded Exploration & Context Constraints

To support the goal of *deep research*, the tree must be allowed to grow to any required depth or width. **No artificial tree limits (such as depth caps or path boundaries) are enforced.**

However, to ensure that local on-device models do not experience context overflow or degraded reasoning, we implement the following constraints at the iteration level:

* **Micro-Iterations (Max 20 Inputs)**: During any single prompt invocation (generalization or branching), the LLM must be fed no more than 20 discrete inputs (e.g., node summaries, facts, or raw snippet blocks).
* **Summarization Bottlenecks**: If a node contains more than 20 children or inputs, the coordinator recursively synthesizes them in batches of 10-20 before compiling the parent-level artifact.
* **Pruning Dead Paths**: Irrelevant or low-information nodes are marked `:dead` and omitted from sibling summaries, saving critical context budget.

---

## 5. Visualizing Depth & Tree Progress to the User

Deep research is a complex, long-running process. To keep the user informed, the system provides real-time visualization of the tree state.

### TUI Visualization
The terminal interface (`Beamcore.TUI`) displays an interactive, real-time tree diagram mapping out node status:

```
[+] Deep EVM Scaling Research
 ├── [✔] Area 1: Optimistic Rollups (Internal LLM)
 └── [⚡] Area 2: ZK-Rollups (2 Web Fetches Pending)
      ├── [⚙] Sub: Proof Generation Cost (fetching url...)
      └── [⌛] Sub: EVM Compatibility (queued)
```

#### Status Indicators
* `[⌛]`: Unexplored / Queued for sequential LLM processing
* `[⚙]`: Fetching data in parallel (wget/curl)
* `[⚡]`: Gathering completed / Processing LLM analysis
* `[✔]`: Completed node (artifact generated)
* `[✖]`: Dead branch (pruned)
* `[▼]`: Generalized parent node

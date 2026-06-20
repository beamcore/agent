# Beamcore
![CI](https://github.com/beamcore/agent/actions/workflows/ci.yml/badge.svg)
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)


Beamcore is a terminal coding agent built on the Erlang/OTP distribution
protocol. Every instance is a distributed node. Eeva, the model-facing runtime,
runs arbitrary Elixir inside the same VM -- giving the agent direct access to
the Beam module system, process tree, and inter-node RPC. The agent can
configure itself, call its own functions recursively, spawn sub-agents, talk to
other agents on the same machine or across the network, and (if it chooses)
recompile its own modules at runtime.

## Architecture

```
+---------------------------------------------------------------------+
|                        BEAM VM                                      |
|                                                                     |
|  +--------------+    +--------------+    +--------------+            |
|  | Agent A      |    | Agent B      |    | Agent C      |            |
|  | (project-1)  |    | (project-2)  |    | (project-3)  |            |
|  +------+-------+    +------+-------+    +------+-------+            |
|         |                   |                   |                    |
|         +--------- Erlang Distribution ---------+                    |
|                    (BEAMCORE_MESH:1:...)                             |
|                                                                     |
|  +----------+  +----------+  +----------+  +----------+             |
|  | Config   |  | Memory   |  | Eeva     |  | Provider |             |
|  | (DETS)   |  | (ETS+DETS)| | Workers  |  | Router   |             |
|  +----------+  +----------+  +----------+  +----------+             |
+---------------------------------------------------------------------+
```

## Eeva: The Execution Layer

Eeva is the only tool the model uses. It is not a wrapper around shell
commands -- it compiles and executes Elixir AST inside a supervised worker with
tuned limits.

### What Eeva can do

- **File I/O**: `File.read!/1`, `File.write!/2`, `File.ls!/1` -- direct access
  to the filesystem under the workspace root.
- **System commands**: `System.cmd/2` is intercepted and routed through
  `Eeva.system_cmd/3` for tracking, but the agent can run git, mix, make, or
  any installed binary.
- **Memory**: `Beamcore.Memory.remember/3`, `recall/3`, `list/3`, `search/2`,
  `forget/2` -- scoped persistent storage backed by ETS and DETS.
- **Config**: `Beamcore.Config.put/2`, `get/1`, `put_provider/2`,
  `set_active_provider/1` -- the agent can reconfigure itself mid-session.
- **Sub-agents**: `Beamcore.Agent.SubAgent.run/2` -- spawn a bounded sub-agent
  on the same or a different model. The sub-agent gets its own Eeva tool and
  can iterate up to 150 tool calls deep.
- **Cross-agent RPC**: `Node.list/0` returns connected peers. The agent can
  call any function on any connected node:

```elixir
Node.list() |> Enum.map(fn node ->
  :rpc.call(node, Beamcore.Memory, :list, [])
end)
```

- **Hot code reload**: `Code.compile_string/1` compiles new module definitions
  into the running VM. The agent can modify its own code at runtime. This is
  powerful and dangerous -- a bad compile can break the running session.

### What Eeva enforces

- AST node count limit (default: 24,000)
- Code byte limit (default: 128 KB)
- Execution timeout (default: 3 minutes)
- Memory cap per worker (default: 256 MB)
- Reduction limit (default: 40M reductions)
- Atom budget tracking -- prevents atom table exhaustion
- Output truncation (default: 256 KB stdout, 128 KB result)

The agent writes normal Elixir. The sandbox validates structure before
execution. There is no special DSL or restricted API surface -- the model has
full access to the language and runtime.

## Mesh Networking

Every Beamcore instance starts as a distributed Erlang node. Discovery uses two
parallel mechanisms:

- **UDP broadcast** -- beacons on port 45876 for LAN-wide discovery.
- **EPMD poll** -- queries the local Erlang Port Mapper Daemon for
  beamcore-* nodes. Covers the common case of multiple agents on one host.

Zero configuration. Start two terminals:

```sh
# Terminal 1 (project-1)
cd ~/project-1 && make chat

# Terminal 2 (project-2)
cd ~/project-2 && make chat
```

Both agents discover each other automatically. Once connected, they share the
Erlang distribution protocol -- full bidirectional RPC with no serialization
overhead.

### Cross-agent operations

The agent can reach any connected peer from Eeva:

```elixir
# List connected peers
Node.list()

# Fetch memory entries from another agents project
remote_memory = :rpc.call(:"beamcore-e5f6g7h8@hostname", Beamcore.Memory, :list, [:facts])

# Ask another agent to run a function
result = :rpc.call(:"beamcore-e5f6g7h8@hostname", MyProject.Config, :get, [:version])

# Connect to a remote node manually
Node.connect(:"beamcore-remote@other-host")
```

### Example: cross-project context sharing

You have two agents running -- one on backend-api, one on frontend-app. You
ask the backend agent: what version is the frontend using?

The agent writes Eeva code:

```elixir
peers = Node.list()
case peers do
  [] -> IO.puts("No peers connected")
  [peer | _] ->
    version = :rpc.call(peer, MyProject.MixProject, :project, []) |> Keyword.get(:version)
    IO.puts("Frontend version: " <> to_string(version))
end
```

Eeva compiles and executes it. The result comes back as tool output. The agent
reports: The frontend is on version 2.4.1.

## Self-Configuration

The agent can configure itself through Beamcore.Config:

```elixir
# Add a provider
Beamcore.Config.put_provider("openai", %{  
  "api_key" => "encrypted:" <> encrypted_key,
  "base_url" => "https://api.openai.com/v1",
  "default_model" => "gpt-4o"
})

# Switch active provider
Beamcore.Config.set_active_provider("openai")

# Tune runtime limits
Beamcore.Config.put(:max_tool_calls, 50)

# Read current config
Beamcore.Config.active_provider()
Beamcore.Config.get_setting(:max_tool_calls)
```

The first time you run `/api add openai sk-...` in the TUI, the key is
encrypted with AES-256-GCM using a machine-bound key and persisted to
`~/.beamcore/config.dets`. Every subsequent session loads it automatically.

## Hot Reload

Because Eeva runs inside the same BEAM VM as the agent, the agent can
recompile modules at runtime:

```elixir
Code.compile_string("defmodule MyProject.NewFunction do\\n  def hello, do: :world\\nend")
```

This is real hot code loading -- the new module definition replaces the old one
in the running VM. The agent can evolve its own behavior mid-session.

This is powerful and dangerous. A failed compile or a module that breaks
contracts will crash the running session. Use it when you know what you are
doing.

## Provider System

Beamcore routes through any OpenAI-compatible API. The registry ships with
OpenAI and DeepSeek defaults. Any provider can be added at runtime:

```sh
/api add openai sk-...                              # OpenAI
/api add deepseek sk-...                            # DeepSeek
/api add groq gsk_... https://api.groq.com/openai   # Groq
/api add custom sk-... https://my-api.com/v1        # Custom
```

Provider health is probed asynchronously. Model availability is cached with a
10-second TTL. The agent can switch providers or models mid-session without
restarting.

## Memory

Beamcore.Memory is a supervised key-value store scoped by
`{org, repo, type, key}`. Types include: facts, decisions, patterns,
errors, context, notes, preferences, tasks, projects.

Backed by ETS for reads and DETS for persistence. The agent uses it to remember
decisions, file relationships, test patterns, and project conventions across
sessions.

## Application Logs

Diagnostics at `~/.beamcore/logs/YYYY-MM-DD.txt`. Includes startup/shutdown
events, exceptions, render failures, tool dispatcher failures, and stacktraces.
Secrets are redacted automatically.

## Development

```sh
make chat          # Start TUI (dev mode)
make test          # Run test suite
make check         # Format check + compile warnings + tests
make check-full    # Full validation including Dialyzer
make format        # Auto-format source code
make release       # Build production release
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT -- see [LICENSE](LICENSE).

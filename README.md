# Beamcore Agent

![AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)

Beamcore is a terminal coding agent built on Elixir/OTP. It can inspect, modify,
test, and reason about projects in many languages while keeping all filesystem
operations inside the selected workspace.

The runtime is provider-neutral: Mistral, OpenAI-compatible services, Ollama,
and custom OpenAI-compatible endpoints are configuration entries behind the
same provider contract. Models are data, not separate implementations.

## Highlights

- full-screen TUI with chat, activity timeline, provider selector, autocomplete,
  multiline input, and `@` file search;
- unified guarded `modify_file` tool with exact operations, checksums, atomic
  writes, reread verification, and structured diffs;
- workspace-bound PathSafety and optional project policy;
- parallel sub-agents with provider-specific scheduling;
- provider-neutral routing and per-provider cooldowns;
- optional local context helper, disabled by default;
- persistent memory, ledger, provider configuration, and login data;
- OTP supervision for stateful runtime components.

## OTP architecture

Beamcore uses OTP only where ownership and recovery are useful. Pure parsing,
formatting, validation, and routing functions remain ordinary modules.

The application supervision tree owns:

- `Beamcore.Config` — the single owner of `~/.beamcore/config.dets`, including
  the in-memory secret cache and serialized DETS writes;
- `Beamcore.Ledger` — action journal and metrics;
- `Beamcore.Memory` — persistent repository memory;
- `Beamcore.RateLimiter` — legacy request pacing for compatibility paths;
- `Beamcore.Provider.Scheduler` — independent provider/account/model queues and
  cooldowns;
- `Beamcore.Agent.TaskSupervisor` — chat workers, discovery probes, and
  supervised asynchronous work;
- `Beamcore.Provider.Health` — cached provider model discovery and health probes;
- TUI supervision, file mutation queue, status bar, and alignment services.

A failing optional local helper or provider discovery probe does not terminate
the primary chat session. Provider probes run below the task supervisor and are
cached by `Provider.Health`.

## Provider architecture

The main request path is:

```text
Chat / sub-agent / helper
          ↓
Beamcore.Provider.Router
          ↓
Registry definition + capabilities
          ↓
Beamcore.Provider.Scheduler
          ↓
Protocol adapter
```

Current chat providers use the OpenAI-compatible protocol adapter. Provider
brands such as Mistral, OpenAI, DeepSeek, Ollama `/v1`, OpenRouter, Groq, LM
Studio, vLLM, or LocalAI should normally be registry/configuration entries, not
new adapter modules. A new adapter is needed only for a genuinely different
protocol, such as Anthropic Messages or Gemini GenerateContent.

Provider and model choices are stored in session role selections:

- **primary** — planning, reasoning, final answers, and normal tool orchestration;
- **helper** — optional bounded context scout;
- **fallback** — reserved for provider failover.

Concurrent sessions and sub-agents carry their own immutable role selections.

### Per-mode provider and model selection

Each TUI mode resolves its own primary provider/model before a session starts:

| Mode | Code name | Provider env | Model env | Default |
|---|---|---|---|---|
| F1 Dev | `agent` | `BEAMCORE_AGENT_PROVIDER` | `BEAMCORE_AGENT_MODEL` | active provider / provider default |
| F2 Chat | `chat` | `BEAMCORE_CHAT_PROVIDER` | `BEAMCORE_CHAT_MODEL` | active provider / provider default |
| F3 Research | `research` | `BEAMCORE_RESEARCH_PROVIDER` | `BEAMCORE_RESEARCH_MODEL` | `ollama` / `gemma4:latest` |
| Deep Research workflow | `deep_research` | `BEAMCORE_DEEP_RESEARCH_PROVIDER` | `BEAMCORE_DEEP_RESEARCH_MODEL` | `ollama` / `gemma4:latest` |

Stored selections from the provider selector or `/api use` are used when env
vars are empty. Environment variables take precedence for that process. F3 is
local-first by default, but it remains provider-neutral; configure any
OpenAI-compatible local or remote provider through the normal provider config.

Per-mode context budgets can also be set:

```env
BEAMCORE_AGENT_INPUT_BUDGET=32000
BEAMCORE_CHAT_INPUT_BUDGET=16000
BEAMCORE_RESEARCH_INPUT_BUDGET=12000
BEAMCORE_DEEP_RESEARCH_INPUT_BUDGET=12000
BEAMCORE_RESEARCH_AUTO_CONTINUE_LIMIT=4
BEAMCORE_LOCAL_PROVIDER_RECEIVE_TIMEOUT_MS=120000
```

Budgets are approximate token budgets based on deterministic message size. If a
turn is over budget, Beamcore keeps system context and the latest user request,
then trims or compresses older context before the model call.

Local OpenAI-compatible providers such as Ollama use non-streaming chat
completion calls by default. `BEAMCORE_LOCAL_PROVIDER_RECEIVE_TIMEOUT_MS`
controls the receive timeout for those local calls; the default is 120 seconds
because cold model loading and full non-streaming responses can legitimately
exceed the 30 second remote-provider default.

### F3 and Deep Research

F3 research uses a bounded Deep Research workflow that is designed to work with
weaker local models:

1. understand the request;
2. create or update a compact plan in `research_index.md`;
3. gather only needed context/tools;
4. compress intermediate findings;
5. return a checkpoint answer or `RESEARCH_COMPLETE`.

The workflow injects only a compact artifact list and a compressed
`research_index.md` into the model context. It does not read every research file
or dump unlimited history. Research auto-continue is capped by
`BEAMCORE_RESEARCH_AUTO_CONTINUE_LIMIT` so local models cannot spin forever.

### Reversible sessions and timeline

Sessions are persisted under `~/.agent/sessions` as an append-only JSONL log and
a resumable `*.state.json` snapshot. The state snapshot stores the durable
session id, mode, provider/model role selection, active messages, usage counters,
timeline events, checkpoints, branch metadata, and intermediate state.

The TUI Activity panel renders the durable timeline when a session has more than
the initial start event. F1 Dev creates a startup checkpoint, records accepted
goals, creates pre-mutation checkpoints before filesystem writes/deletes, and
records post-mutation checkpoints after successful mutation batches. The status
bar shows the active checkpoint id. Slash commands are available as
keyboard-friendly timeline controls:

```text
/stop                         # interrupt current execution and checkpoint
/resume                       # continue current interrupted branch
/checkpoint rewind <id>        # move active state back to a checkpoint
/checkpoint fork <id>          # create a new branch from a checkpoint
/checkpoint abandon <branch>   # mark a bad branch abandoned
```

Rewind does not delete history. Later events on the old branch are marked
abandoned/inactive and remain inspectable. Forking creates a new branch from the
selected checkpoint, preserving the previous branch. Continuing from the fork
adds new events to the new branch only.

Activity is scrollable and navigable. `F6` focuses Activity, `Up`/`k` and
`Down`/`j` move selection, `PageUp`/`PageDown` page, `Home`/`g` jumps to the
oldest event, and `End`/`G` jumps to newest and resumes live-follow. When the
user scrolls away from newest, Activity preserves the selection and counts new
events instead of force-scrolling.

Current timeline event types include `started`, `decision`, `research_stage`,
`model_call`, `tool_call`, `file_change`, `compression`, `checkpoint_saved`,
`interrupted`, `resumed`, `rewound`, `forked`, `completed`, `failed`, and
`error`.

Checkpoints store messages, mode, branch, workflow state, research/tool state,
usage, and a filesystem journal boundary. Beamcore records filesystem
provenance for mutations performed through guarded BeamCore tools, including
BeamCore-started formatter, validation, generator, and Git commands. If a
BeamCore-started command or Git hook changes workspace files, those changes are
recorded as agent-owned command mutations. Rewind and fork undo successful
agent-owned mutations after the selected checkpoint boundary in reverse order;
they do not replace the whole workspace with an old snapshot.

Filesystem rollback is selective:

- modified text files use a deterministic inverse line merge when the user made
  non-overlapping edits after the agent change;
- overlapping edits become conflicts and the current user-visible file is left
  in place;
- binary files, symlinks, and permissions use hash-exact whole-path semantics;
- agent-created files/directories are removed only when they are still
  agent-owned;
- agent-deleted files/directories are restored only when the path has not been
  recreated externally.

Conflict recovery versions are written under `.beamcore/recovery/<restore-id>/`.
Snapshot blobs and the mutation journal live under `.beamcore/snapshots/`. These
internal paths are blocked from normal agent tools and should stay ignored by
Git. Human/agent merge conflicts are reported separately from operational
restore failures such as missing or corrupted snapshot blobs.

Restore operations are OTP-owned. `Beamcore.Agent.RestoreCoordinator` runs under
`Beamcore.Agent.RestoreSupervisor`, and
`Beamcore.Agent.FilesystemJournal.Server` serializes journal appends and restore
application per workspace. A restore persists internal states such as
`planned`, `preflighted`, `safety_revision_saved`, `applying`, `verifying`,
`completed`, `completed_with_conflicts`, `failed_recovered`, and
`failed_recovery_required` under `.beamcore/snapshots/restores/`. If an
operational failure occurs after application starts, Beamcore attempts to recover
the changed paths to the pre-restore safety revision automatically.

Snapshot safety limits can be configured:

```text
BEAMCORE_SNAPSHOT_MAX_FILE_BYTES=5242880
BEAMCORE_SNAPSHOT_MAX_OPERATION_BYTES=20971520
BEAMCORE_SNAPSHOT_MAX_DIRECTORY_FILES=1000
BEAMCORE_SNAPSHOT_MAX_COMMAND_SCAN_FILES=20000
BEAMCORE_SNAPSHOT_MAX_TOTAL_BYTES=104857600
```

When a destructive mutation cannot be snapshotted within policy limits, the tool
returns an error and leaves the filesystem unchanged.
Command attribution scans exclude BeamCore internals, `.git`, and common
disposable build/dependency directories such as `_build`, `deps`, and
`node_modules`; source files, untracked files, and ignored files inside the
workspace remain attributable when changed by BeamCore-started commands.

## Optional local helper

The local helper is **off by default**. Beamcore does not contact Ollama or any
other local model unless the user explicitly chooses a provider and model.
There is no automatic Gemma selection.

```text
/helper status
/helper list
/helper models ollama
/helper use ollama qwen2.5-coder:latest
/helper off
```

Any discovered local model may be selected. The helper receives only a reduced
read-only tool set for workspace search and context preparation. It cannot call
`modify_file`, destructive filesystem operations, command execution, git
mutation, or recursive sub-agents.

If the helper is unavailable, times out, or produces an invalid result, the
primary request continues without it. Helper progress appears as transient TUI
status and does not flood the chat transcript with inspected error terms.

For development, an explicit local primary model can be launched with:

```bash
make chat-local LOCAL_MODEL=qwen2.5-coder:latest
```

Use `LOCAL_PROVIDER=<name>` when the provider is not `ollama`.

## Requirements

For development from source:

- Elixir 1.12 or newer;
- Erlang/OTP 24 or newer;
- Git;
- credentials for a remote provider or a reachable local provider.

Prebuilt releases do not require Elixir on the target machine.

## Development setup

```bash
git clone https://github.com/beamcore/agent.git
cd agent
make dev-setup
make chat
```

`make chat` may load the repository `.env` for development only. Installed
Beamcore does not load arbitrary project `.env` files.

Example development `.env`:

```env
MISTRAL_API_KEY=
MISTRAL_BASE_URL=https://api.mistral.ai/v1
API_CHAT_MODEL=mistral-medium-3-5
```

Never commit a real `.env`.

## Installation

### Published release

```bash
make install
```

This uses `install.sh` to download a published release. If no GitHub release has
been published yet, install from source instead.

### Local source build

```bash
make install-dev
```

The launcher is installed at `~/.local/bin/beamcore` and the release at
`~/.beamcore/app` by default.

```bash
beamcore          # foreground interactive TUI
beamcore start    # start OTP release service
beamcore stop     # stop service
beamcore remote   # attach to service
```

The installer preserves `~/.beamcore`, including provider config, memory, and
ledger data.

## Provider configuration

Open the provider selector with `Ctrl+O`, `/providers`, or `/api select`.

```text
/api list
/api use mistral
/api add openrouter <token> https://openrouter.ai/api/v1 <model>
/api delete openrouter
```

For the legacy default Mistral flow:

```text
/login
/logout
```

Provider secrets are stored in `~/.beamcore/config.dets`. `Beamcore.Config` is
the supervised owner of this file and serializes access. Secrets are encrypted
at rest with a machine-bound AES-256-GCM key and the file is restricted to
`0600` where supported. This protects casual disk exposure but is not equivalent
to macOS Keychain, Linux Secret Service, or a hardware-backed credential store.

Operating-system environment variables take precedence over stored secrets.

## TUI controls

| Key | Action |
|---|---|
| `Ctrl+S` | Send the current input. |
| `Enter` | Insert a newline in multiline input. |
| `Shift+Enter` / `Alt+Enter` / `Ctrl+J` | Newline fallback, depending on terminal. |
| `Ctrl+O` | Open provider selector. |
| `@` | Search workspace files from the input. |
| `Tab` | Complete suggestions or open activity details. |
| `Up` / `Down` | Navigate suggestions, timeline, or chat scroll. |
| `Esc` | Close suggestions, help, details, or selectors. |
| `Ctrl+C` | Exit cleanly. |

The TUI formats provider and tool failures into bounded readable messages.
Optional-helper progress is kept in the status bar instead of chat history.

## Main commands

| Command | Description |
|---|---|
| `/new` | Start a fresh session. |
| `/context` | Show compact session context. |
| `/context clear` | Clear compact context. |
| `/providers`, `/api select` | Open provider selector. |
| `/api list` | List configured providers. |
| `/api use <provider>` | Change the primary provider. |
| `/api add ...` | Add/update an OpenAI-compatible provider. |
| `/helper status` | Show helper selection. |
| `/helper models <provider>` | Discover models through supervised provider health. |
| `/helper use <provider> <model>` | Enable exactly the selected helper model. |
| `/helper off` | Disable helper; this is the default. |
| `/login`, `/logout` | Manage the legacy default Mistral login. |
| `/policy ...` | Inspect or edit deterministic project policy. |
| `/yolo on`, `/yolo off` | Bypass/restore project policy for this session. |
| `/timeline` | Inspect the durable session timeline. |
| `/checkpoint rewind <id>` | Rewind active state to a checkpoint without deleting history. |
| `/checkpoint fork <id>` | Create a new branch from a checkpoint. |
| `/checkpoint abandon <branch>` | Mark a branch abandoned without deleting it. |
| `/stop`, `/continue` | Pause/resume a session between turns. |
| `/help` | Show help. |
| `/quit`, `/exit`, `/q` | Exit. |

## File search with `@`

Typing `@` opens workspace file suggestions. Results are deduplicated and
filtered through PathSafety, including symlink-escape protection. Build output,
dependencies, and ignored paths should not be used as model context unless
explicitly requested.

## Tools

| Tool | Purpose |
|---|---|
| `read` | Read workspace files and directories. |
| `grep` | Search file contents. |
| `glob` | Find files by pattern. |
| `tree` | Show a compact workspace tree. |
| `modify_file` | Create or modify files through guarded transactional operations. |
| `fs` | Limited filesystem operations with explicit destructive guards. |
| `git` | Bounded repository operations. Allowed Git commands run inside a command mutation scope so hook-written workspace files are journaled. `git clone` and `git restore` remain disabled until they have journal-aware implementations. |
| `test_tool` | Detect and run the project test/build system. |
| `task` | Delegate bounded work to sub-agents. |
| `memory` | Store and recall repository-scoped knowledge. |
| `plan` | Record a non-mutating plan. |
| `reflect` | Review current work with bounded context. |
| `web_get` | Optional explicit HTTP GET. |
| `image_generation` | Optional image generation provider boundary. |
| `eeva` | Executes Elixir code under an isolated, temporary supervisor, capturing stdout/stderr and returning exit status. |

`modify_file` rejects missing or ambiguous anchors, invalid ranges, binary
files, path escapes, no-op changes, and checksum mismatches. It applies edits in
memory, writes atomically, rereads the file, verifies the result, and returns a
structured diff and checksums.

## Workspace and policy safety

All file tools are workspace-relative. Absolute paths, `..` traversal, and
symlink escapes are rejected by PathSafety.

Projects may add `.beamcore/policy.json` to restrict tools and paths. `/yolo`
bypasses project policy only for the current session; it never disables
PathSafety or hard tool guards.

Example:

```json
{
  "version": 1,
  "deny_paths": [".env", ".env.*", "secrets/**", "_build/**", "deps/**", ".git/**"],
  "read_only_paths": ["mix.lock"],
  "allow_write_paths": ["lib/**", "test/**", "README.md", "scratch/**"],
  "tool_permissions": {
    "read": "allow",
    "grep": "allow",
    "glob": "allow",
    "tree": "allow",
    "modify_file": "confirm",
    "fs": "confirm",
    "git": "allow",
    "test_tool": "allow",
    "task": "deny"
  }
}
```

## Rate limiting and concurrency

Parallel sub-agents remain supported. Provider calls pass through
`Beamcore.Provider.Scheduler`, keyed by provider, account fingerprint, and
model. A remote provider cooldown does not block unrelated local-model work.
The legacy global limiter remains only for compatibility paths that have not
migrated to provider routing.

## Persistent data

Default user files:

```text
~/.beamcore/config.dets   provider credentials and preferences
~/.beamcore/memory.dets   repository memory
~/.beamcore/ledger.jsonl  action journal
~/.beamcore/app           installed release
```

## Validation

```bash
make format-check
mix compile --warnings-as-errors
mix test
MIX_ENV=prod mix release --overwrite
```

## Troubleshooting

- **No published release**: use `make install-dev` from a source checkout.
- **Provider not configured**: open `Ctrl+O`, use `/api add`, or use `/login`
  for the legacy Mistral flow.
- **Local helper starts unexpectedly**: run `/helper off`; helper is designed to
  be disabled by default.
- **Local helper unavailable**: confirm the exact selected model exists with
  `/helper models <provider>`. The primary request should still continue.
- **TUI output is unreadable after an error**: current errors are bounded and
  normalized; report the original provider/tool event rather than pasting a
  raw nested term.
- **macOS/iTerm viewport differs from Linux**: Beamcore uses ExRatatui frame
  dimensions and resize events. Remaining alternate-screen behavior belongs to
  the terminal abstraction dependency and may require an ExRatatui update.

## License

Beamcore Agent is licensed under the GNU Affero General Public License v3.0.
See [LICENSE](LICENSE).

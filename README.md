# Beamcore.Agent

Beamcore.Agent is a general-purpose CLI coding agent running inside an Elixir/Mix workspace. It can answer and write code in any language, while its self-development workflow is optimized for this Elixir project: bounded workspace tools, autonomous edits, compact session context, token-aware history, image generation, and repeatable Mix validation.

## Core ideas

- **General coding help**: answer standalone Java, Python, C++, JavaScript, Go, Rust, Erlang, Elixir, and other coding questions directly in chat.
- **Elixir-first workspace workflow**: when improving this repository, understand the Mix project, edit small, test focused, validate with Mix.
- **Safe tool execution**: file and git paths are workspace-relative; absolute paths, traversal, and symlink escapes are rejected.
- **Autonomous by default**: fresh sessions can read, search, edit, write, patch, and validate immediately while runtime guards stay active.
- **Compact context**: the agent remembers inspected files, modified files, validation state, and activity without storing full file contents.
- **Token discipline**: tool outputs, mutation arguments, and history are compacted before they are sent back to Mistral.
- **Image generation**: optional real image generation through Mistral Agents with the built-in `image_generation` tool.

## Requirements

- Elixir 1.12+
- Erlang/OTP 24+
- A Mistral API key for real chat/API calls

## Setup

```bash
git clone https://github.com/beamcore/agent.git
cd agent
make deps
make init
```

Edit `.env` locally:

```env
MISTRAL_API_KEY=your_api_key_here
MISTRAL_BASE_URL=https://api.mistral.ai/v1
BEAMCORE_IMAGE_PROVIDER=mistral
MISTRAL_IMAGE_MODEL=mistral-medium-latest
MISTRAL_IMAGE_AGENT_ID=
```

`.env` is ignored by git. Keep `.env.example` committed with empty placeholders only.

## Make targets

| Target | Description |
|---|---|
| `make deps` | Install dependencies. |
| `make compile` | Compile the project. |
| `make test` | Run ExUnit tests. |
| `make format` | Format the project. |
| `make chat` | Start the primary polished terminal UI agent chat. |
| `make chat-plain` | Start the plain emergency fallback. |
| `make run-ledger` | Run the ledger service standalone as a globally registered cluster member. |
| `make init` | Create `.env` from `.env.example` if missing. |
| `make install` | Build a production release and install a local executable. |
| `make uninstall` | Remove the installed release/executable. |
| `make clean` | Remove `_build` and `deps`. |
| `make help` | Show available targets. |

## Primary chat

Run the product with:

```bash
make chat
```

`make chat` starts the main terminal UI. The UI is the product experience: chat,
tool activity, autonomous edits, project policy status, image generation status,
and token state all live in one screen. If the TUI cannot start because the terminal is
not interactive or unsupported, the app prints a short reason and starts the
plain emergency fallback.

The fallback can be forced when needed:

```bash
make chat-plain
mix run -e "Beamcore.Agent.chat(:plain)"
```

The TUI and fallback use the same runtime: one session flow, one tool policy
system, one dispatcher, one context model, and one image generation flow.

## TUI keybindings

| Key | Action |
|---|---|
| `Enter` | Send the current message. |
| `Shift+Enter` | Insert a newline when supported by the terminal. |
| `Ctrl+S` | Send the current message. |
| `Tab` | Open the tool details popup. |
| `Up` / `Down` | Scroll chat or move through command suggestions. |
| `Esc` | Close popups and command suggestions. |
| `Ctrl+C` | Exit cleanly. |

## Chat commands

| Command | Description |
|---|---|
| `/new` | Start a fresh chat session and reset context. |
| `/paste` | Enter multi-line input mode; finish with `/end`. |
| `<<<` | Alternative multi-line input mode; finish with `>>>`. |
| `/context` | Print compact session context. |
| `/context clear` | Clear compact session context. |
| `/policy` | Show project policy summary. |
| `/policy show` | Show normalized project policy config. |
| `/policy init` | Create `.beamcore/policy.json` from the example. |
| `/policy deny path <pattern>` | Add a denied path pattern. |
| `/policy allow-write <pattern>` | Add an allowed write path pattern. |
| `/policy read-only <pattern>` | Add a read-only path pattern. |
| `/policy tool <tool> allow\|deny` | Set a tool permission. |
| `/policy remove ...` | Remove a policy entry; weakening changes require `--confirm`. |
| `/policy reset --confirm` | Delete the local policy config. |
| `/policy reload` | Reload and summarize policy from disk. |
| `/yolo` | Toggle session freedom mode. |
| `/yolo on` | Bypass project policy for this session. |
| `/yolo off` | Restore project policy for this session. |
| `/help` | Show command help. |
| `/quit`, `/exit`, `/q` | Exit the TUI. |

The plain fallback also keeps `/paste` and `<<<` multi-line input for emergency
line-based operation.

## TUI layout

- **Wide**: chat transcript, right activity/tool sidebar, bottom input, clean
  centered header, and compact status bar with a tiny state indicator.
- **Medium**: chat transcript, compact activity strip, command bar, and status bar.
- **Narrow**: single-column chat, command bar, compact status, and activity
  details via `Tab`.
- **Tiny**: a minimal terminal-too-small screen with a fallback hint.

The empty state is intentional: it shows the product title, a short
description, example prompts, `/help`, autonomous-tool hints, and
session/model/provider details. The header stays clean and professional; the
compact status indicator shows agent state while tool calls live in the activity
rail instead of decorative UI.

## Activity timeline

Tools are first-class UI events. The timeline shows compact labels for `plan`,
`read`, `write`, `edit`, `patch`, `fs`, `grep`, `glob`, `tree`, `git`, `mix`,
`image_generation`, blocked attempts, validation events, and errors.

Examples:

```text
read README.md
write lib/foo.ex
mix test
image_generation -> generated/architecture.png
blocked write scratch/a.ex
```

Tool states are `queued`, `running`, `done`, `blocked`, and `error`. The normal
UI never dumps raw tool maps or full file payloads.

## Image generation UI

When `image_generation` runs, the activity timeline shows the prompt summary,
output path, running/done/error status, saved file path, and an
`open generated/file.png` hint after success. The TUI does not require external
image viewers.

## TUI troubleshooting

- **Terminal too small**: enlarge the terminal; tiny mode shows a clear warning.
- **TUI does not start**: `make chat` prints the reason and falls back to plain mode.
- **tmux**: use a recent tmux and a capable `$TERM`, such as `screen-256color`.
- **SSH**: make sure the remote session has an interactive TTY and useful `$TERM`.
- **Truecolor**: truecolor is not required; the theme uses terminal-safe colors.
- **Plain fallback**: use `make chat-plain` only when the TUI cannot run.

## General coding questions

The current workspace is Elixir/Mix, but the assistant is not Elixir-only. It should answer standalone programming questions in the requested language without refusing or forcing the answer back to this repository. For example, a question like `can you write something in Java?` should receive a Java example directly in chat.

Workspace mutation rules still apply to every language: creating or editing Java, Python, C++, or any other files stays inside workspace path safety and optional project policy. Mix validation only validates this Elixir project; the agent should not claim it compiled or ran non-Elixir code unless an appropriate project tool exists.

## Autonomous mutation flow

Fresh sessions are autonomous. For normal user text, the agent may inspect,
write, edit, patch, and validate directly. If a runtime guard blocks a tool
call, the agent receives the error and should self-correct by choosing an
allowed path or tool when possible.

Use project policy when you want stricter control over what the autonomous agent
can read, write, or execute.

## Explicit Policy blocks

Advanced users and tests can narrow a turn with an explicit machine-readable policy:

```text
/paste
Policy:
mode: restricted_write
allowed_write_paths:
- scratch/example.ex
allowed_tools:
- write
- mix
blocked_tools:
- task
- web_get
- git

Task:
Create scratch/example.ex and run focused validation.
/end
```

Supported modes:

- `read_only`
- `development`
- `restricted_write`

If a `Policy:` block has an invalid mode, the runtime fails closed and disables mutation tools.

## Optional project policy

Projects can add `.beamcore/policy.json` to make runtime permissions stricter. Missing config preserves the default autonomous behavior. Project policy is enforced in code, not only in the prompt, and cannot bypass workspace path safety.

The local config is ignored by git. Use `.beamcore/policy.example.json` as the checked-in template.

`/yolo` toggles a session-local freedom mode. In normal autonomous mode,
ProjectPolicy remains active. In freedom mode, `.beamcore/policy.json`
restrictions are bypassed for the current session only; hard workspace,
path-safety, and tool-specific guards still apply. Use `/yolo off` to restore
ProjectPolicy enforcement.

Example:

```json
{
  "version": 1,
  "deny_paths": [".env", ".env.*", "secrets/**", "private/**", "_build/**", "deps/**", ".git/**"],
  "read_only_paths": ["config/prod.exs", "mix.lock"],
  "allow_write_paths": ["lib/**", "test/**", "README.md", "generated/**"],
  "tool_permissions": {
    "read": "allow",
    "grep": "allow",
    "glob": "allow",
    "tree": "allow",
    "write": "allow",
    "edit": "allow",
    "patch": "allow",
    "fs": "allow",
        "git": "allow",
        "mix": "allow",
        "memory": "allow",
        "python": "allow",
        "node": "allow",
        "make": "allow",
        "go": "allow",
        "rust": "allow",
        "terraform": "deny",
        "ruby": "allow",
        "bazel": "allow",
        "image_generation": "allow",
        "task": "deny",
        "web_get": "deny"
  }
}
```

- `deny_paths` always wins, for reads and writes.
- `read_only_paths` can be read/searched/listed but cannot be mutated.
- `allow_write_paths` is optional; when present, writes must match one of these patterns.
- `tool_permissions` is optional and supports `allow` and `deny`.
- Invalid JSON fails closed and blocks tools until the file is fixed.
- Normal agent mutation tools cannot edit `.beamcore/policy.json`; policy changes must come from deterministic `/policy` commands or manual user edits.
- Stricter `/policy` changes apply immediately. Weaker changes, such as removing a deny path or setting a denied tool to `allow`, require `--confirm`.

## Tools

| Tool | Description |
|---|---|
| `plan` | Records an optional non-mutating planning note. |
| `read` | Reads workspace-relative files/directories with offset/limit support. |
| `grep` | Searches file content with workspace boundary checks and fallback if `rg` is unavailable. |
| `glob` | Finds files by glob pattern with workspace boundary checks and fallback if `rg` is unavailable. |
| `tree` | Prints a compact workspace tree. |
| `write` | Writes full file content to an allowed workspace-relative path. |
| `edit` | Replaces exact text in an allowed file. |
| `patch` | Applies a patch only when every touched path is allowed. |
| `fs` | Performs limited filesystem operations; destructive actions require explicit confirmation. |
| `git` | Performs bounded git operations inside the workspace. |
| `mix` | Runs safe Mix commands such as `format --check-formatted`, `compile`, `test`, and `validate`. |
| `memory` | Recalls, remembers, lists, and forgets scoped persistent repository knowledge. |
| `python` | Runs allowlisted Python workflow commands such as test, lint, format, type-check, build, validate, and venv. |
| `node` | Runs allowlisted npm/npx workflow commands including test, lint, build, format, install, and Playwright test/report commands. |
| `make` | Lists Makefile targets or runs one explicit target. |
| `go` | Runs allowlisted Go commands: test, fmt, vet, build, and mod-tidy. |
| `rust` | Runs allowlisted Cargo commands: test, check, fmt, clippy, and build. |
| `terraform` | Runs allowlisted Terraform commands: fmt, validate, and plan. Apply/destroy are not exposed. |
| `ruby` | Runs allowlisted Ruby/Rails commands such as test, rspec, rubocop, routes, and migration status. |
| `bazel` | Runs allowlisted Bazel commands: test, build, and query. |
| `image_generation` | Uses Mistral Agents with the built-in `image_generation` tool, downloads generated files, and saves them to allowed workspace paths. |
| `web_get` | Fetches external URLs using HTTP GET only when explicitly enabled, using a token-efficient HTML cleaning pipeline. |
| `task` | Delegates to sub-agents only when explicitly enabled. |

## Image generation

The `image_generation` tool performs real API calls through a provider layer. The default provider is `mistral`. Mistral image generation follows the documented Agents flow: create or reuse an agent with `tools: [%{type: "image_generation"}]`, start a conversation with that agent, extract `tool_file` chunks from the response, and download generated files through `/v1/files/{file_id}/content`. Downloaded files are validated as PNG, JPEG, or WebP before they are written to disk, so JSON/error payloads are not saved as broken images.

Example explicit policy:

```text
/paste
Policy:
mode: restricted_write
allowed_write_paths:
- generated/architecture.png
allowed_tools:
- image_generation
blocked_tools:
- task
- web_get
- git
- write
- edit
- patch
- fs

Task:
Generate a clean architecture diagram for this Elixir CLI agent. Use a dark terminal-inspired style, show Chat Loop, Tool Policy, Dispatcher, Tools, Mistral API, and Session Context. Save it to generated/architecture.png.
/end
```

Optional environment variables:

| Variable | Description |
|---|---|
| `BEAMCORE_IMAGE_PROVIDER` | Image generation provider. Currently supported: `mistral`. Defaults to `mistral`. |
| `MISTRAL_IMAGE_MODEL` | Model used when creating a temporary Mistral image agent. Defaults to `mistral-medium-latest`. |
| `MISTRAL_IMAGE_AGENT_ID` | Existing Mistral image-generation agent ID. If set, the tool reuses it instead of creating a temporary agent. |

## Validation loop

The `mix` tool supports `validate`, which runs:

1. `mix format --check-formatted`
2. `mix compile`
3. `mix test`

Manual equivalent:

```bash
mix format --check-formatted
mix compile
mix test
mix run -e 'IO.puts Beamcore.Agent.Tools.Mix.execute(%{"command" => "validate"})'
```

## Runtime safety

- No shell/bash/sh/zsh tool exists.
- Runtime code does not depend on `Mix.env/0` or test-only branches.
- Tool calls are authorized before execution.
- Optional `.beamcore/policy.json` can further restrict tools and paths at runtime.
- Blocked tool calls are printed as blocked, not as successful execution.
- Mutation tool arguments and outputs are compacted in active API history.
- `task` and `web_get` are hidden unless explicitly enabled.
- `image_generation` is hidden unless explicitly enabled and must write to an allowed output path.

## Recent Changes

### Module Namespace Flattening (2026-05-28)
To simplify imports and reduce nesting, the following core modules were moved from `Beamcore.Agent.*` to the top-level `Beamcore.*` namespace:
- `Beamcore.Agent.OpenAI` → `Beamcore.OpenAI`
- `Beamcore.Agent.Chat.RateLimiter` → `Beamcore.RateLimiter`
- `Beamcore.Agent.Retry` → `Beamcore.Retry`
- `Beamcore.Agent.Tools.FileMutationQueue` → `Beamcore.FileMutationQueue`

All internal references and tests have been updated. External code using these modules should update imports accordingly.

### Edit Tool Improvements
The `edit` tool now:
- Uses **byte-level precision** for UTF-8 safety (emoji, multi-byte characters).
- Adapts line endings (LF/CRLF) automatically.
- Normalizes Unicode smart quotes/dashes in `old_string` (but never modifies file content silently).
- Supports atomic writes (temp file + rename).
- De-obfuscates Cloudflare email placeholders (`[email\@protected]` → `$@`).
- Preserves trailing newlines to prevent line merging.

### Alignment Guard Removal
The Alignment conflict check was removed from the `edit` tool. File coordination now belongs in a middleware/interceptor layer, not baked into individual tools. The `Beamcore.Alignment` GenServer itself remains available for custom coordination logic.

## Architecture

- `Beamcore.Agent.Chat.Loop` handles input, tool execution, policy messages, and status updates.
- `Beamcore.Agent.Chat.ToolPolicy` parses explicit `Policy:` blocks and enforces runtime permissions.
- `Beamcore.Agent.Chat.Context` stores compact session metadata.
- `Beamcore.Agent.Tools.Dispatcher` routes authorized tool calls.
- `Beamcore.Agent.Tools.Plan` stores pending mutation plans.
- `Beamcore.Agent.Tools.ImageGeneration` is the safe local tool that validates output paths and saves generated image bytes.
- `Beamcore.Agent.Providers.ImageGeneration` dispatches image requests to the configured provider.
- `Beamcore.Agent.Providers.Mistral` implements Mistral Agents image generation through `Beamcore.OpenAI` REST helpers.
- `Beamcore.OpenAI` is the single Mistral API boundary: OpenaiEx chat client plus binary-safe REST helpers for Agents, Conversations, and Files.
- `Beamcore.Agent.Core.SysPrompt` defines the coding-agent behavior and response style.

## Development checklist

Before committing:

```bash
git diff --check
mix format --check-formatted
mix compile
mix test
mix run -e 'IO.puts Beamcore.Agent.Tools.Mix.execute(%{"command" => "validate"})'
```

Also verify that `.env`, `scratch/`, `eval/`, temporary files, and generated artifacts are not staged unless intentionally requested.

## Developer console (IEx)

You can start an interactive Elixir console to test functions and tools directly:

```bash
iex -S mix
```

Once in the console, you can call any public function from the Beamcore.Agent modules.
For example, to test the Mix tool validation:

```elixir
Beamcore.Agent.Tools.Mix.execute(%{"command" => "validate"})
```

Or to inspect available tools:

```elixir
Beamcore.Agent.Tools.Dispatcher.list_tools()
```

To search for files using glob patterns:

```elixir
Beamcore.Agent.Tools.Glob.execute(%{"pattern" => "**/*.ex", "limit" => 10})
```

To search file contents with grep:

```elixir
Beamcore.Agent.Tools.Grep.execute(%{"pattern" => "defmodule", "include" => "*.ex"})
```

To read a file directly:

```elixir
Beamcore.Agent.Tools.Read.execute(%{"filePath" => "README.md", "limit" => 50})
```

To fetch a web resource (note: requires explicit policy permission):

```elixir
Beamcore.Agent.Tools.WebGet.execute(%{"url" => "https://example.com"})
```

The full workspace context is available, so you can also read files, compile modules,
and run tests directly from the console. This is useful for rapid iteration and
debugging during development.

## License

Beamcore.Agent is licensed under the MIT License. See `LICENSE` for details.

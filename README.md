# Beamcore.Agent

Beamcore.Agent is an Elixir/Mix CLI coding agent for Mistral API. It focuses on safe self-development: bounded workspace tools, explicit mutation confirmation, compact session context, token-aware history, and repeatable Mix validation.

## Core ideas

- **Elixir-first workflow**: understand the Mix project, edit small, test focused, validate with Mix.
- **Safe tool execution**: file and git paths are workspace-relative; absolute paths, traversal, and symlink escapes are rejected.
- **Confirmed mutations**: normal write/edit/patch/fs requests create a pending plan first; mutations run only after `/confirm` or an explicit `Policy:` block.
- **Compact context**: the agent remembers inspected files, modified files, validation state, and pending plans without storing full file contents.
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
| `make chat` | Start the interactive agent. |
| `make init` | Create `.env` from `.env.example` if missing. |
| `make install` | Build a production release and install a local executable. |
| `make uninstall` | Remove the installed release/executable. |
| `make clean` | Remove `_build` and `deps`. |
| `make help` | Show available targets. |

## Chat commands

| Command | Description |
|---|---|
| `/new` | Start a fresh chat session and reset context. |
| `/paste` | Enter multi-line input mode; finish with `/end`. |
| `<<<` | Alternative multi-line input mode; finish with `>>>`. |
| `/confirm` | Confirm the pending mutation plan for one execution turn. |
| `/cancel` | Cancel the pending mutation plan. |
| `/context` | Print compact session context. |
| `/context clear` | Clear compact session context. |
| `/help` | Show command help. |

## Normal mutation flow

For normal user text, the agent should not write immediately. It first creates a non-mutating plan:

```text
> Create scratch/policy_test.ex with a tiny module. Do not touch anything else.

Pending plan stored. Confirm with `/confirm` ...

> /confirm

File created: scratch/policy_test.ex
```

Before confirmation, mutation tools are hidden from the API schema and runtime-blocked as a second safety layer. After confirmation, the generated policy is active for exactly one turn and is then cleared.

## Explicit Policy blocks

Advanced users and tests can bypass the planning step with an explicit machine-readable policy:

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
- curl
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

## Tools

| Tool | Description |
|---|---|
| `plan` | Stores a non-mutating pending plan for `/confirm`. |
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
| `image_generation` | Uses Mistral Agents with the built-in `image_generation` tool, downloads generated files, and saves them to allowed workspace paths. |
| `curl` | Fetches external URLs only when explicitly enabled. |
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
- curl
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
- Blocked tool calls are printed as blocked, not as successful execution.
- Mutation tool arguments and outputs are compacted in active API history.
- `task` and `curl` are hidden unless explicitly enabled.
- `image_generation` is hidden unless explicitly enabled and must write to an allowed output path.

## Architecture

- `Beamcore.Agent.Chat.Loop` handles input, tool execution, policy messages, and status updates.
- `Beamcore.Agent.Chat.ToolPolicy` parses explicit `Policy:` blocks and enforces runtime permissions.
- `Beamcore.Agent.Chat.Context` stores compact session metadata.
- `Beamcore.Agent.Tools.Dispatcher` routes authorized tool calls.
- `Beamcore.Agent.Tools.Plan` stores pending mutation plans.
- `Beamcore.Agent.Tools.ImageGeneration` is the safe local tool that validates output paths and saves generated image bytes.
- `Beamcore.Agent.Providers.ImageGeneration` dispatches image requests to the configured provider.
- `Beamcore.Agent.Providers.Mistral` implements Mistral Agents image generation through `Beamcore.Agent.OpenAI` REST helpers.
- `Beamcore.Agent.OpenAI` is the single Mistral API boundary: OpenaiEx chat client plus binary-safe REST helpers for Agents, Conversations, and Files.
- `Beamcore.Agent.Core.SysPrompt` defines the coding-agent behavior and safety rules.

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

## License

Beamcore.Agent is licensed under the MIT License. See `LICENSE` for details.

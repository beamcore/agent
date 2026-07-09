# Beamcore Agent — Workspace Guide

## What This Is
An autonomous AI coding agent built on Elixir/OTP. One tool (`eeva`) executes arbitrary Elixir code — no separate read/write/git tools needed.

## Quick Reference
| Action | Command |
|--------|---------|
| Compile | `mix compile` |
| Test | `EX_RATATUI_BUILD=1 mix test` |
| Format check | `mix format --check-formatted` |
| Single test | `mix test test/path/to_test.exs:LINE` |
| Release build | `MIX_ENV=prod EX_RATATUI_BUILD=1 mix release --overwrite` |
| Dev install | `make install-dev` |

**Always set `EX_RATATUI_BUILD=1`** when compiling — ex_ratatui is a NIF that requires it.

## Architecture

### Core Loop
`Agent` → `Chat.Loop` → `Chat.API` (LLM call) → `Tools.Dispatcher` → `Tools.Eeva` (code execution)

### Key Modules
- **`Beamcore.Agent.Tools.Eeva`** — Executes Elixir code in an OTP-supervised sandbox. Returns stdout + return value.
- **`Beamcore.Memory`** — Persistent key-value store (DETS). `remember/2`, `recall/1`, `search/1`, `overview/0`.
- **`Beamcore.Agent.SubAgent`** — Spawn async sub-tasks: `SubAgent.run_async("task") |> Task.await()`
- **`Beamcore.Helpers`** — Introspection: `Helpers.info(Module, :functions)`, `Helpers.docs(Module)`, `Helpers.modules("Beamcore")`
- **`Beamcore.Agent.Core.Prompts`** — All system prompts and templates.
- **`Beamcore.Provider`** — Multi-provider LLM routing (OpenAI, Anthropic, etc.)
- **`Tui.*`** — Ratatui-based terminal UI (chat, themes, input handling).

### Eeva Execution Rules
- Write complete programs in a single `eeva` call — no tool chaining.
- **File writes (preferred)**: Use `WriteHelper.write!(path, lines)` with a list of strings — avoids ALL escaping issues:
  ```elixir
  alias Beamcore.Agent.Tools.Eeva.WriteHelper
  lines = ["#!/bin/bash", "echo \"Hello\"", "echo \"World\""]
  WriteHelper.write!("script.sh", lines)
  ```
- **File writes (literal content)**: Use `~S` sigil: `File.write!("path", ~S"content")`
- **File writes (dynamic content)**: Use regular strings with `#{}` interpolation.
- `System.cmd/2` for shell commands. `File` module for I/O.
- Returned zero-arity functions are invoked automatically.

## Conventions
- Language: Elixir `~> 1.12`. Format with `mix format`.
- Tests: ExUnit in `test/`, support in `test/support/`.
- Config: `config/config.exs`, runtime overrides via `~/.beamcore/config.dets`.
- Session logs: `~/.agent/sessions/*.json` (JSONL, one object per line).
- Memory persists at `~/.beamcore/memory.dets`.

## Mesh / Remote
Nodes discover each other via EPMD. `Node.self()`, `Node.list()`, `:erl_epmd.names()`.
Remote execution through `Beamcore.Remote` — sessions run code on peer nodes.

# AGENTS.md

## Project
Beamcore Agent — an autonomous terminal coding agent in Elixir/OTP. It runs a chat loop, routes requests through LLM providers, and executes code via the Eeva sandboxed runtime.

## Quick Reference
- `make check` — format-check + compile --warnings-as-errors + test
- `make check-full` — above + dialyzer
- `mix test` — run ExUnit tests
- `mix format` — auto-format code
- `mix compile` — compile
- `mix dialyzer` — static analysis

## Directory Layout
```
lib/
  beamcore/               # Core: provider, config, memory, agent logic
    agent/chat/           # Chat loop, session, commands, context, budget
    agent/tools/          # Eeva sandboxed execution (sandbox, worker, dispatcher)
    config/               # GenServer config with encrypted secrets (DETS)
    memory/               # Persistent memory store (ETS+DETS)
    provider/             # Provider behaviour, adapters, registry, router, scheduler
  tui/                    # Terminal UI (ex_ratatui). F1=dev, F2=chat screens
test/                     # Mirrors lib/ structure. Support in test/support/
config/                   # Elixir config (config.exs)
```

## Architecture
- **OTP Supervision**: `Beamcore.Agent` supervises Config, Memory, RateLimiter, Scheduler, TaskSupervisor, Eeva workers, TUI
- **Providers**: `Beamcore.Provider` behaviour with `OpenAICompatible` adapter for all APIs. Registry holds defaults (openai, deepseek). Router handles dispatch with rate limiting
- **Eeva**: Model writes plain Elixir code. Parsed/validated by `Sandbox` (size, AST, atom limits), executed by `Worker` under supervision with timeout/memory/reduction caps. Output captured and truncated
- **Memory**: `Beamcore.Memory` — scoped `{type, org, repo, key}` store. Types: facts, decisions, patterns, errors, context, notes, preferences, tasks, projects
- **Config**: `Beamcore.Config` — DETS-backed, AES-256-GCM encrypted secrets, machine-bound key

## Conventions
- All modules under `Beamcore.*` namespace; TUI under `Beamcore.TUI.*`
- File paths mirror module hierarchy: `lib/beamcore/agent/chat/session.ex` → `Beamcore.Agent.Chat.Session`
- Tests mirror source under `test/`; mocks via `Application.get_env(:agent, :completions_module)` injection
- Format with `mix format` (config in `.formatter.exs`)
- Errors surfaced compactly to users; crash details go to `~/.beamcore/logs/`
- Secrets redacted in logs and env display; destructive ops require `confirm: true`

## Key Env Vars
- `OPENAI_API_KEY`, `DEEPSEEK_API_KEY` — provider keys
- `BEAMCORE_AGENT_PROVIDER`, `BEAMCORE_AGENT_MODEL` — override defaults
- `BEAMCORE_EEVA_TIMEOUT_MS`, `BEAMCORE_EEVA_MAX_CODE_BYTES` — Eeva limits
- `BEAMCORE_MAX_TOOL_CALLS` — cap model tool iterations


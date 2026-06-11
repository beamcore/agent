# Refactoring Plan: File Structure & Namespaces

## Problem Statement

The project has a confusing mismatch between **module namespaces** and **file locations**. There are two orthogonal axes of confusion:

1. **`Beamcore.Agent.*` modules live in `lib/agent/`** — not in `lib/beamcore/agent/`. This means the namespace prefix `Beamcore.Agent` does not map to the directory `lib/beamcore/agent/`, violating the standard Elixir convention where `Foo.Bar.Baz` lives at `lib/foo/bar/baz.ex`.

2. **`lib/beamcore/` contains platform-level code** (`Beamcore.Provider.*`, `Beamcore.Helpers.*`, `Beamcore.Compat.*`) that has nothing to do with the agent app. This creates a false expectation that all `Beamcore.*` modules should live under `lib/beamcore/`.

3. **Cross-boundary dependency**: `lib/beamcore/helpers/modify.ex` (`Beamcore.Helpers.Modify`) depends on `Beamcore.Agent.Tools.Eeva.Policy` — a platform-level helper reaching into the agent layer. This is an upward dependency that shouldn't exist.

4. **Top-level `lib/*.ex` files mix concerns**: `lib/config.ex` (`Beamcore.Config`), `lib/retry.ex` (`Beamcore.Retry`), `lib/proxy.ex` (`Beamcore.Proxy`), `lib/rate_limiter.ex` (`Beamcore.RateLimiter`), and `lib/file_mutation_queue.ex` (`Beamcore.FileMutationQueue`) are standalone modules dumped at the top of `lib/` with no clear grouping.

5. **Test structure mirrors the problem**: tests are split between `test/agent/`, `test/beamcore/`, `test/tui/`, and top-level `test/*_test.exs` files, with no clear rationale for what goes where.

---

## Current State Map

### Module → File Mapping

| Module | Current File | Namespace Root |
|---|---|---|
| `Beamcore.Agent` | `lib/agent.ex` | Agent app entry |
| `Beamcore.Agent.Chat.*` (13 files) | `lib/agent/chat/**` | Agent app |
| `Beamcore.Agent.Core.*` (6 files) | `lib/agent/core/**` | Agent app |
| `Beamcore.Agent.Tools.*` (9 files) | `lib/agent/tools/**` | Agent app |
| `Beamcore.Agent.FilesystemJournal` | `lib/agent/filesystem_journal.ex` | Agent app |
| `Beamcore.Agent.PathSafety` | `lib/agent/path_safety.ex` | Agent app |
| `Beamcore.Agent.Policy.*` | `lib/agent/policy/**` | Agent app |
| `Beamcore.Agent.Timeline` | `lib/agent/timeline.ex` | Agent app |
| `Beamcore.Agent.Runtime` | `lib/agent/runtime.ex` | Agent app |
| `Beamcore.Agent.SafeCmd` | `lib/agent/safe_cmd.ex` | Agent app |
| `Beamcore.Agent.RestoreCoordinator` | `lib/agent/restore_coordinator.ex` | Agent app |
| `Beamcore.Agent.Discovery.*` | `lib/agent/discovery/**` | Agent app |
| `Beamcore.Agent.Research.*` | `lib/agent/research/**` | Agent app |
| `Beamcore.Config` | `lib/config.ex` | Platform |
| `Beamcore.Retry` | `lib/retry.ex` | Platform |
| `Beamcore.Proxy` | `lib/proxy.ex` | Platform |
| `Beamcore.RateLimiter` | `lib/rate_limiter.ex` | Platform |
| `Beamcore.FileMutationQueue` | `lib/file_mutation_queue.ex` | Platform |
| `Beamcore.OpenAI` | `lib/beamcore/compat/openai.ex` | Platform |
| `Beamcore.Helpers` | `lib/beamcore/helpers.ex` | Platform |
| `Beamcore.Helpers.Modify` | `lib/beamcore/helpers/modify.ex` | Platform ⚠️ depends on Agent |
| `Beamcore.Provider.*` (12 files) | `lib/beamcore/provider/**` | Platform |
| `Beamcore.Memory` | `lib/memory/memory.ex` | Platform |
| `Beamcore.Ledger` | `lib/ledger/ledger.ex` | Platform |
| `Beamcore.Alignment` | `lib/alignment/alignment.ex` | Platform |
| `Beamcore.TUI` | `lib/tui.ex` | TUI |
| `Beamcore.TUI.*` (17 files) | `lib/tui/**` | TUI |

---

## Proposed Structure

The core idea: **namespace must match file location**. `Beamcore.Agent.*` → `lib/beamcore/agent/`, `Beamcore.Provider.*` → `lib/beamcore/provider/`, etc.

```
lib/
├── beamcore/
│   ├── agent/                          # ← NEW: Beamcore.Agent.* lives here
│   │   ├── agent.ex                    # ← moved from lib/agent.ex
│   │   ├── chat/
│   │   │   ├── chat.ex                 # ← moved from lib/agent/chat.ex
│   │   │   ├── api.ex
│   │   │   ├── budget.ex
│   │   │   ├── commands.ex
│   │   │   ├── context.ex
│   │   │   ├── correction_catch.ex
│   │   │   ├── loop.ex
│   │   │   ├── mode_settings.ex
│   │   │   ├── multiline_input.ex
│   │   │   ├── rate_limit.ex
│   │   │   ├── search_conductor.ex
│   │   │   ├── session.ex
│   │   │   └── tool_policy.ex
│   │   ├── core/
│   │   │   ├── ansi.ex
│   │   │   ├── pretty.ex
│   │   │   ├── prompts.ex
│   │   │   ├── status_bar.ex
│   │   │   ├── sysprompt.ex
│   │   │   └── tool_display.ex
│   │   ├── tools/
│   │   │   ├── dispatcher.ex
│   │   │   ├── eeva.ex
│   │   │   └── eeva/
│   │   │       ├── atom_budget.ex
│   │   │       ├── io_device.ex
│   │   │       ├── policy.ex
│   │   │       ├── sandbox.ex
│   │   │       ├── supervisor.ex
│   │   │       └── worker.ex
│   │   ├── filesystem_journal.ex
│   │   ├── filesystem_journal/
│   │   │   └── server.ex
│   │   ├── path_safety.ex
│   │   ├── policy/
│   │   │   └── project_policy.ex
│   │   ├── timeline.ex
│   │   ├── runtime.ex
│   │   ├── safe_cmd.ex
│   │   ├── restore_coordinator.ex
│   │   ├── discovery/
│   │   │   └── detector.ex
│   │   └── research/
│   │       └── deep_research.ex
│   │
│   ├── config/                         # ← NEW: platform config
│   │   └── config.ex                   # ← moved from lib/config.ex
│   │
│   ├── retry/                          # ← NEW: platform retry
│   │   └── retry.ex                    # ← moved from lib/retry.ex
│   │
│   ├── proxy/                          # ← NEW: platform proxy
│   │   └── proxy.ex                    # ← moved from lib/proxy.ex
│   │
│   ├── rate_limiter/                   # ← NEW: platform rate limiter
│   │   └── rate_limiter.ex             # ← moved from lib/rate_limiter.ex
│   │
│   ├── file_mutation_queue/            # ← NEW: platform file mutation queue
│   │   └── file_mutation_queue.ex      # ← moved from lib/file_mutation_queue.ex
│   │
│   ├── memory/                         # ← RENAMED from lib/memory/
│   │   └── memory.ex                   # Beamcore.Memory
│   │
│   ├── ledger/                         # ← RENAMED from lib/ledger/
│   │   └── ledger.ex                   # Beamcore.Ledger
│   │
│   ├── alignment/                      # ← RENAMED from lib/alignment/
│   │   └── alignment.ex                # Beamcore.Alignment
│   │
│   ├── helpers/
│   │   ├── helpers.ex                  # ← moved from lib/beamcore/helpers.ex
│   │   └── modify.ex                   # ← moved from lib/beamcore/helpers/modify.ex
│   │
│   ├── compat/
│   │   └── openai.ex                   # ← moved from lib/beamcore/compat/openai.ex
│   │
│   └── provider/                       # ← RENAMED from lib/beamcore/provider/
│       ├── provider.ex                 # ← moved from lib/beamcore/provider.ex
│       ├── adapters/
│       │   └── openai_compatible.ex
│       ├── capabilities.ex
│       ├── error.ex
│       ├── health.ex
│       ├── model.ex
│       ├── model_context.ex
│       ├── ollama_discovery.ex
│       ├── registry.ex
│       ├── router.ex
│       ├── scheduler.ex
│       └── selection.ex
│
└── tui/                                # ← RENAMED from lib/tui/
    ├── tui.ex                          # ← moved from lib/tui.ex (Beamcore.TUI)
    ├── capability.ex
    ├── components/
    │   ├── activity.ex
    │   ├── chat.ex
    │   ├── empty_state.ex
    │   ├── help.ex
    │   ├── input.ex
    │   ├── mascot.ex
    │   └── status_bar.ex
    ├── dynamic_supervisor.ex
    ├── error_formatter.ex
    ├── events.ex
    ├── file_finder.ex
    ├── history.ex
    ├── layout.ex
    ├── multi_screen_state.ex
    ├── render.ex
    ├── sanitize.ex
    ├── state.ex
    ├── theme.ex
    └── wrap.ex
```

### Test Structure (mirrors lib/)

```
test/
├── beamcore/
│   ├── agent/
│   │   ├── chat/
│   │   ├── core/
│   │   ├── tools/
│   │   ├── filesystem_journal_test.exs
│   │   ├── path_safety_test.exs
│   │   ├── policy/
│   │   ├── timeline_test.exs
│   │   ├── workspace_root_test.exs
│   │   └── ...
│   ├── config_test.exs
│   ├── retry_test.exs
│   ├── proxy_test.exs
│   ├── rate_limiter_test.exs
│   ├── file_mutation_queue_test.exs
│   ├── memory_test.exs
│   ├── ledger_test.exs
│   ├── alignment_test.exs
│   ├── helpers_test.exs
│   ├── modify_helper_test.exs
│   └── provider/
│       ├── health_test.exs
│       ├── registry_test.exs
│       ├── router_test.exs
│       └── scheduler_test.exs
└── tui/
    ├── capability_layout_test.exs
    ├── chat_scroll_test.exs
    ├── ...
```

---

## Migration Steps

### Phase 1: Move agent code into `lib/beamcore/agent/`

1. Create `lib/beamcore/agent/` directory tree
2. Move all `lib/agent/**/*` → `lib/beamcore/agent/`
3. Move `lib/agent.ex` → `lib/beamcore/agent/agent.ex`
4. Update `mix.exs` app name from `:agent` to `:beamcore_agent` (or keep `:agent` — see note below)
5. Update all `use`/`alias`/`import`/`require` references across the codebase
6. Move `test/agent/` → `test/beamcore/agent/`
7. Move `test/agent_test.exs` → `test/beamcore/agent_test.exs`

### Phase 2: Consolidate platform modules into `lib/beamcore/`

1. Move `lib/config.ex` → `lib/beamcore/config/config.ex`
2. Move `lib/retry.ex` → `lib/beamcore/retry/retry.ex`
3. Move `lib/proxy.ex` → `lib/beamcore/proxy/proxy.ex`
4. Move `lib/rate_limiter.ex` → `lib/beamcore/rate_limiter/rate_limiter.ex`
5. Move `lib/file_mutation_queue.ex` → `lib/beamcore/file_mutation_queue/file_mutation_queue.ex`
6. Move `lib/memory/` → `lib/beamcore/memory/`
7. Move `lib/ledger/` → `lib/beamcore/ledger/`
8. Move `lib/alignment/` → `lib/beamcore/alignment/`
9. Move `lib/beamcore/helpers.ex` → `lib/beamcore/helpers/helpers.ex`
10. Move `lib/beamcore/provider.ex` → `lib/beamcore/provider/provider.ex`
11. Update all references
12. Move corresponding tests

### Phase 3: Consolidate TUI into `lib/tui/`

1. Move `lib/tui.ex` → `lib/tui/tui.ex`
2. Move `lib/tui/**/*` → `lib/tui/` (already mostly there, just flatten the extra nesting)
3. Update all references
4. Move `test/tui/` → `test/tui/` (already correct, just verify)

### Phase 4: Fix the upward dependency

`Beamcore.Helpers.Modify` currently depends on `Beamcore.Agent.Tools.Eeva.Policy`. After the moves:

1. Determine if `Modify` truly needs `Eeva.Policy` or if the used functions can be extracted into a shared module
2. If the dependency is legitimate, it's now a same-tree dependency (`lib/beamcore/helpers/` → `lib/beamcore/agent/tools/eeva/policy.ex`) which is architecturally acceptable since both are under the `Beamcore` umbrella
3. If not, extract the shared logic into `lib/beamcore/helpers/` or a new `lib/beamcore/shared/` module

### Phase 5: Clean up

1. Remove old empty directories (`lib/agent/`, `lib/beamcore/provider/`, `lib/beamcore/compat/`, etc.)
2. Update `mix.exs` if app name changed
3. Update any scripts, CI configs, or documentation referencing old paths
4. Run full test suite: `mix test`
5. Run dialyzer: `mix dialyzer`

---

## Key Decisions Needed

### App name: `:agent` vs `:beamcore_agent`

The `mix.exs` currently declares `app: :agent`. Options:

- **Keep `:agent`** — simpler, no changes to `Application` calls, env vars, or release config. The internal directory structure is independent of the OTP app name.
- **Rename to `:beamcore_agent`** — more consistent with the org namespace, but requires updating `Application.get_env(:agent, ...)` calls throughout the codebase and the release config.

**Recommendation**: Keep `:agent` for now. The directory refactor is already a large change; renaming the app can be a follow-up.

### Module names: keep `Beamcore.Agent.*` or rename to `Agent.*`?

Two schools of thought:

- **Keep `Beamcore.Agent.*`** — consistent with the org namespace (`beamcore/agent` repo), and all other modules already use `Beamcore.*`. After the refactor, the namespace will correctly map to `lib/beamcore/agent/`.
- **Rename to `Agent.*`** — shorter, and the app is the agent. But this would mean mixing `Agent.*` and `Beamcore.*` namespaces in the same codebase, which is its own kind of inconsistency.

**Recommendation**: Keep `Beamcore.Agent.*`. The namespace is correct; only the file location was wrong.

### `lib/beamcore/` as a single app vs multiple apps

Currently everything compiles as one OTP app (`:agent`). An alternative would be to split `lib/beamcore/provider/`, `lib/beamcore/memory/`, etc. into separate OTP apps in an umbrella project. This is a much larger architectural decision and **out of scope** for this refactor.

**Recommendation**: Keep as a single app. This refactor is about file organization and namespace consistency, not architectural restructuring.

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Broken references after moves | Use `grep`/`ripgrep` to find all `Beamcore.Agent.` references and update systematically. Compile frequently. |
| Test paths break | Move tests in lockstep with source files. Run `mix test` after each phase. |
| Merge conflicts if working on a branch | Do this refactor on a clean branch with no other active work. |
| `Beamcore.Helpers.Modify` → `Beamcore.Agent.Tools.Eeva.Policy` dependency | Address in Phase 4. This is the only cross-boundary dependency and needs careful handling. |
| `mix release` config references old module names | Update `main_module: Beamcore.Agent` in `mix.exs` release config if needed (it should still work since the module name doesn't change). |

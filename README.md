
Beamcore is a small terminal coding agent built on Elixir/OTP. It runs one
straight chat loop, uses one provider routing path, and executes work through
Eeva, the model-facing Elixir runtime.

The default mode is autonomous yolo: Beamcore acts directly in a trusted-local
developer environment and reports failures clearly instead of asking for
approval before normal work.

## What Remains

- chat-first TUI with input, scrollback, compact status, paste handling, and
  `@` file search;
- provider-neutral chat requests through `Beamcore.Provider.Router`;
- provider/model switching through `/api`;
- Eeva as the only model-facing execution layer;
- trusted-local path handling for relative, absolute, and symlinked paths;
- internal `.beamcore` storage protection;
- captured Eeva stdout/stderr so raw IO cannot corrupt the TUI;
- supervised memory, ledger, provider scheduler, and task runtime;
- alignment pause/resume support.

## Commands

| Command | Purpose |
|---|---|
| `/help` | Show available commands. |
| `/api` | List configured providers. |
| `/api use PROVIDER [MODEL]` | Switch the active provider/model. |
| `/api model MODEL` | Switch the model for the active provider. |
| `/yolo` | Reaffirm the default autonomous mode. |
| `/env` | Show redacted process environment values. |
| `/context` | Show compact session context. |
| `/context clear` | Clear compact session context. |
| `/clear` | Clear the visible chat when supported by the current TUI path. |
| `/stop` | Stop or pause active work when supported by the current runtime path. |

Unknown or removed commands are rejected automatically with a compact message.

## Provider Setup

Beamcore stores user config under `~/.beamcore`. Environment variables can still
override provider settings for the current process.

Typical development flow:

```sh
mix deps.get
mix test
mix run -e 'Tui.run()'
```

Useful Make targets:

```sh
make chat
make chat-plain
make test
make validate
make install
make install-dev
```

## Eeva Runtime

Eeva accepts ordinary Elixir code from the model and runs it under OTP
supervision. It captures stdout/stderr and bounds large code/output/results so
tool execution cannot corrupt the TUI or overwhelm the provider context.

Permitted operations run autonomously. If compilation, command execution,
runtime guards, provider calls, or rate limits fail, Beamcore surfaces a compact
status/chat notice so the agent can self-correct without silently repeating the
same failed step.

Recoverable tool/runtime errors keep the session active. The TUI shows the short
error plus a subtle continuation hint, while serious crash details are written
to the application log.

## Memory And Alignment

`Beamcore.Memory` is supervised and available through Eeva. It is intended for
small durable project facts, not secrets or large transcripts.

Alignment pause/resume remains part of the runtime so the user can interrupt an
active turn and provide a correction before work continues.

## Token Metadata

Model context metadata records the source and accuracy of context-window and
usage numbers. Provider-reported usage is preferred when available; otherwise
Beamcore labels estimates explicitly.

## Freedom And Operator Controls

Beamcore is autonomous by default. Useful local coding actions are not hidden
behind approval loops or legacy allowlists. Operator controls are explicit:

- `BEAMCORE_MAX_TOOL_CALLS` caps model tool iterations when set. Empty or
  unset means Beamcore uses its high default for iterative coding.
- `BEAMCORE_EEVA_TIMEOUT_MS`, `BEAMCORE_EEVA_MAX_CODE_BYTES`,
  `BEAMCORE_EEVA_MAX_OUTPUT_BYTES`, and related `BEAMCORE_EEVA_*` values tune
  runtime stability bounds.
- `Beamcore.Agent.Tools.Eeva.remove(path, confirm: true)` is the explicit helper
  for destructive removal. Without `confirm: true`, it refuses to remove files.
- Relative paths resolve from the active project root; absolute and symlinked
  paths are accepted for trusted local workflows.

Beamcore still avoids accidental runtime pollution: internal `.beamcore` state
is hidden from casual project listings, large outputs are compacted, and secrets
are redacted from status/config displays.

## Application Logs

Application diagnostics are written outside the TUI under:

```sh
~/.beamcore/logs/YYYY-MM-DD.txt
```

These logs are for the operator. They include startup/shutdown events,
unexpected exceptions, TUI/render failures, tool dispatcher failures, and
stacktraces that would be too noisy for the chat UI. API keys, tokens,
authorization headers, passwords, cookies, and similar secrets are redacted.

Beamcore does not automatically feed application logs into the model prompt or
memory. The agent may inspect them only when the user explicitly asks for local
log debugging.

## Install

Development install:

```sh
make install-dev
```

Release build:

```sh
MIX_ENV=prod mix release --overwrite
```

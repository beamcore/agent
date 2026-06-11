# Beamcore Agent

![AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)

Beamcore is a small terminal coding agent built on Elixir/OTP. It runs one
straight chat loop, uses one provider routing path, and executes work through
Eeva, the model-facing Elixir runtime.

The default mode is autonomous yolo: Beamcore acts directly inside hard runtime
boundaries and reports failures clearly instead of asking for approval before
normal work.

## What Remains

- chat-first TUI with input, scrollback, compact status, paste handling, and
  `@` file search;
- provider-neutral chat requests through `Beamcore.Provider.Router`;
- provider/model switching through `/api`;
- Eeva as the only model-facing execution layer;
- workspace-bound `PathSafety`;
- internal `.beamcore` storage protection;
- journaled filesystem mutations;
- captured Eeva stdout/stderr so raw IO cannot corrupt the TUI;
- supervised memory, ledger, provider scheduler, and task runtime;
- alignment pause/resume support.

## Commands

| Command | Purpose |
|---|---|
| `/help` | Show available commands. |
| `/login` | Store a Mistral API key in the local Beamcore config. |
| `/logout` | Remove the stored Mistral API key. |
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
supervision. It captures stdout/stderr, bounds large outputs, journals workspace
file changes, and blocks hard runtime boundary violations such as workspace
escape, internal storage access, unsafe runtime modules, and shell interpreter
entry points.

Permitted operations run autonomously. If compilation, command execution,
runtime guards, provider calls, or rate limits fail, Beamcore surfaces a compact
status/chat notice so the agent can self-correct without silently repeating the
same failed step.

## Memory And Alignment

`Beamcore.Memory` is supervised and available through Eeva. It is intended for
small durable project facts, not secrets or large transcripts.

Alignment pause/resume remains part of the runtime so the user can interrupt an
active turn and provide a correction before work continues.

## Token Metadata

Model context metadata records the source and accuracy of context-window and
usage numbers. Provider-reported usage is preferred when available; otherwise
Beamcore labels estimates explicitly.

## Safety Boundaries

Beamcore is autonomous by default, but not unbounded. These checks stay on:

- paths must remain inside the active workspace;
- internal Beamcore state directories are not exposed as normal workspace files;
- filesystem mutations are recorded by the journal;
- Eeva cannot call blocked runtime internals directly;
- shell interpreters are not accepted as command entry points;
- huge Eeva code, output, and results are bounded.

## Install

Development install:

```sh
make install-dev
```

Release build:

```sh
MIX_ENV=prod mix release --overwrite
```

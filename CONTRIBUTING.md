# Contributing to Beamcore

Thanks for your interest in contributing to Beamcore.

## Development Setup

### Prerequisites

- Elixir 1.12+
- Erlang/OTP 25+

### Getting Started

```sh
git clone https://github.com/beamcore/agent.git
cd agent
make deps
make chat
```

### Common Tasks

| Task | Command |
|---|---|
| Run tests | `make test` |
| Format code | `make format` |
| Check formatting | `make format-check` |
| Full validation | `make check-full` |
| Build release | `make release` |
| Static analysis | `make dialyzer` |

## Guidelines

- Write `@moduledoc` for every public module.
- Add tests for new functionality.
- Run `make check-full` before submitting a pull request.
- Keep commits focused. One logical change per commit.
- Write clear commit messages.

## Pull Requests

1. Fork the repo and create a branch from `main`.
2. Make your changes.
3. Add or update tests as needed.
4. Run `make check-full` and ensure it passes.
5. Open a pull request against `main`.

## Reporting Issues

Open an issue on [GitHub](https://github.com/beamcore/agent/issues).
Include steps to reproduce, expected behavior, and actual behavior.

For security issues, see [SECURITY.md](SECURITY.md).

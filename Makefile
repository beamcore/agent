# Beamcore Agent — Makefile
# Run `make` or `make help` to see available commands.

.DEFAULT_GOAL := help

# ==============================================================================
# Configuration
# ==============================================================================

INSTALL_DIR  ?= $(HOME)/.beamcore/app
BIN_DIR      ?= $(HOME)/.local/bin
LAUNCHER     ?= $(BIN_DIR)/beamcore
CONFIG_DIR   ?= $(HOME)/.beamcore
RELEASE_NAME ?= beamcore
RELEASE_DIR   = _build/prod/rel/$(RELEASE_NAME)

VERBOSE ?= 0
DRY_RUN ?= 0

.PHONY: all help
.PHONY: install install-dev uninstall
.PHONY: deps compile release test format format-check dialyzer check check-full
.PHONY: chat shell run-memory cluster
.PHONY: dev-setup init config-status version clean update

all: compile

# ==============================================================================
# Installation
# ==============================================================================

## install: Download and install pre-built release (no Elixir required)
install:
ifeq ($(DRY_RUN),1)
	@echo "==> DRY RUN: would run install.sh"; \
	 echo "    BEAMCORE_INSTALL_DIR=$(INSTALL_DIR)"; \
	 echo "    BEAMCORE_BIN_DIR=$(BIN_DIR)"; \
	 echo "    BEAMCORE_CONFIG_DIR=$(CONFIG_DIR)"; \
	 echo "    BEAMCORE_VERSION=$${BEAMCORE_VERSION:-latest}"
else
	@BEAMCORE_INSTALL_DIR="$(INSTALL_DIR)" \
	 BEAMCORE_BIN_DIR="$(BIN_DIR)" \
	 BEAMCORE_CONFIG_DIR="$(CONFIG_DIR)" \
	 sh "$(CURDIR)/install.sh"
endif

## install-dev: Build from source and install locally (requires Elixir)
install-dev:
ifeq ($(DRY_RUN),1)
	@echo "==> DRY RUN: make install-dev"
	@echo "Would build Beamcore release from source"
	@echo "Would install app to:      $(INSTALL_DIR)"
	@echo "Would install launcher to: $(LAUNCHER)"
	@echo "Would ensure config dir:   $(CONFIG_DIR)"
else
	@command -v elixir >/dev/null 2>&1 || { echo "error: elixir is not installed"; echo "Install Elixir: https://elixir-lang.org/install.html"; exit 1; }
	@command -v mix >/dev/null 2>&1 || { echo "error: mix is not installed"; exit 1; }
	@echo "==> Building Beamcore release from source"; \
	if [ "$(VERBOSE)" = "1" ]; then \
		set -eu; \
		mix deps.get && mix compile && MIX_ENV=prod mix release --overwrite; \
	else \
		log_file=$$(mktemp "$${TMPDIR:-/tmp}/beamcore-release.XXXXXX"); \
		if mix deps.get > "$$log_file" 2>&1 && mix compile >> "$$log_file" 2>&1 && MIX_ENV=prod mix release --overwrite >> "$$log_file" 2>&1; then \
			rm -f "$$log_file"; \
		else \
			echo "Release build failed. Build log:"; \
			cat "$$log_file"; \
			rm -f "$$log_file"; \
			exit 1; \
		fi; \
	fi; \
	echo "✓ Release built"
	@echo ""
	@echo "==> Installing Beamcore"
	@echo "app:      $(INSTALL_DIR)"
	@echo "launcher: $(LAUNCHER)"
	@set -eu; \
	if [ -z "$(INSTALL_DIR)" ] || [ "$(INSTALL_DIR)" = "/" ]; then \
		echo "error: INSTALL_DIR is empty or root — refusing to proceed"; exit 1; \
	fi; \
	if [ -d "$(INSTALL_DIR)" ]; then \
		backup="$(INSTALL_DIR).backup.$$$$"; \
		mv "$(INSTALL_DIR)" "$$backup"; \
	fi; \
	mkdir -p "$(INSTALL_DIR)" && \
	cp -a $(RELEASE_DIR)/. "$(INSTALL_DIR)/" && \
	rm -rf "$${backup:-}" || { \
		[ -n "$${backup:-}" ] && [ -d "$${backup:-}" ] && mv "$$backup" "$(INSTALL_DIR)"; \
		echo "error: installation failed — previous install restored"; exit 1; \
	}; \
	mkdir -p "$(BIN_DIR)"; \
	printf '%s\n' \
		'#!/bin/sh' \
		'set -eu' \
		'BEAMCORE_APP="$${BEAMCORE_INSTALL_DIR:-$(INSTALL_DIR)}"' \
		'COOKIE_FILE="$$HOME/.erlang.cookie"' \
		'if [ -f "$$COOKIE_FILE" ]; then' \
		'  RELEASE_COOKIE="$$(cat "$$COOKIE_FILE")"' \
		'  export RELEASE_COOKIE' \
		'fi' \
		'AGENT_BIN="$$BEAMCORE_APP/bin/beamcore"' \
		'' \
		'if [ ! -x "$$AGENT_BIN" ]; then' \
		'  printf "error: Beamcore not installed at %s\n" "$$BEAMCORE_APP" >&2' \
		'  exit 1' \
		'fi' \
		'' \
		'if [ "$$#" -eq 0 ]; then' \
		'  exec "$$AGENT_BIN" eval "Application.ensure_all_started(:beamcore); Beamcore.Agent.chat()"' \
		'fi' \
		'exec "$$AGENT_BIN" "$$@"' > "$(LAUNCHER)"; \
	chmod +x "$(LAUNCHER)";
	echo "✓ Installed"
endif

## uninstall: Remove installed app and launcher (preserves config)
uninstall:
	@echo "==> Uninstalling Beamcore"
	@rm -rf "$(INSTALL_DIR)"
	@rm -f "$(LAUNCHER)"
	@echo "removed app:      $(INSTALL_DIR)"
	@echo "removed launcher: $(LAUNCHER)"
	@echo "kept config dir:  $(CONFIG_DIR)"
	@echo "✓ Uninstalled"

# ==============================================================================
# Development
# ==============================================================================

## deps: Install Mix dependencies
deps:
	mix deps.get

## compile: Compile the project
compile:
	EX_RATATUI_BUILD=1 mix compile

## release: Build a prod release
release: deps compile
	MIX_ENV=prod mix release --overwrite

## test: Run ExUnit tests
test:
	EX_RATATUI_BUILD=1 mix test

## format: Format source code
format:
	mix format

## format-check: Verify formatting (no changes)
format-check:
	mix format --check-formatted

## dialyzer: Run Dialyzer static analysis
dialyzer:
	mix dialyzer

## check: Quick validation (format + compile warnings + test)
check: format-check
	mix compile --warnings-as-errors
	mix test

## check-full: Full validation including Dialyzer
check-full: check dialyzer

## shell: Start interactive IEx shell
shell: compile
	iex -S mix

## update: Update all dependencies
update:
	mix deps.update --all
	mix deps.compile

## clean: Remove build artifacts
clean:
	rm -rf _build
	mix clean

# ==============================================================================
# Running
# ==============================================================================

## chat: Start the TUI chat (dev mode, auto-joins mesh)
chat: compile
	elixir --sname "beamcore-$$$$" -S mix run -e "Application.ensure_all_started(:beamcore); Beamcore.Agent.chat()"

## run-memory: Run memory service standalone (mesh member)
run-memory: compile
	elixir --sname "beamcore-memory" -S mix run --no-halt

# ==============================================================================
# Setup & Config
# ==============================================================================

## dev-setup: One-shot development environment setup
dev-setup: deps compile init
	@echo ""
	@echo "✓ Development environment ready"
	@echo "  Run: make chat"

## init: Create Beamcore config directory
init:
	@if [ -d "$(CONFIG_DIR)" ]; then \
		echo "✓ Config directory: $(CONFIG_DIR)"; \
	else \
		mkdir -p "$(CONFIG_DIR)"; \
		echo "✓ Created config directory: $(CONFIG_DIR)"; \
	fi

## config-status: Show configuration status
config-status:
	@echo ""
	@echo "==> Config"
	@if [ ! -d "$(CONFIG_DIR)" ]; then \
		echo "⚠ Config directory missing: $(CONFIG_DIR)"; \
		echo "  Run: make init"; \
	else \
		echo "✓ Config directory: $(CONFIG_DIR)"; \
	fi

## version: Print current version
version:
	@mix run --no-start -e 'IO.puts(Mix.Project.config()[:version])'

# ==============================================================================
# Help
# ==============================================================================

## help: Show this help
help:
	@echo ""
	@echo "  \033[1mBeamcore Agent\033[0m"
	@echo ""
	@echo "  \033[1mInstallation:\033[0m"
	@printf "    \033[36m%-16s\033[0m %s\n" "install" "Download and install pre-built release (no Elixir needed)"
	@printf "    \033[36m%-16s\033[0m %s\n" "install-dev" "Build from source and install (requires Elixir)"
	@printf "    \033[36m%-16s\033[0m %s\n" "uninstall" "Remove installed app and launcher"
	@echo ""
	@echo "  \033[1mDevelopment:\033[0m"
	@printf "    \033[36m%-16s\033[0m %s\n" "deps" "Install dependencies"
	@printf "    \033[36m%-16s\033[0m %s\n" "compile" "Compile the project"
	@printf "    \033[36m%-16s\033[0m %s\n" "test" "Run tests"
	@printf "    \033[36m%-16s\033[0m %s\n" "format" "Format source code"
	@printf "    \033[36m%-16s\033[0m %s\n" "check" "Quick validation (format + warnings + test)"
	@printf "    \033[36m%-16s\033[0m %s\n" "check-full" "Full validation including Dialyzer"
	@printf "    \033[36m%-16s\033[0m %s\n" "shell" "Start interactive IEx shell"
	@printf "    \033[36m%-16s\033[0m %s\n" "release" "Build a prod release"
	@echo ""
	@echo "  \033[1mRunning:\033[0m"
	@printf "    \033[36m%-16s\033[0m %s\n" "chat" "Start TUI chat (dev mode, auto-joins mesh)"
	@printf "    \033[36m%-16s\033[0m %s\n" "run-memory" "Run standalone mesh member"
	@echo ""
	@echo "  \033[1mSetup:\033[0m"
	@printf "    \033[36m%-16s\033[0m %s\n" "dev-setup" "One-shot dev environment setup"
	@printf "    \033[36m%-16s\033[0m %s\n" "init" "Create config directory"
	@printf "    \033[36m%-16s\033[0m %s\n" "version" "Print current version"
	@printf "    \033[36m%-16s\033[0m %s\n" "clean" "Remove build artifacts"
	@printf "    \033[36m%-16s\033[0m %s\n" "update" "Update all dependencies"
	@echo ""
	@echo "  \033[1mOptions:\033[0m"
	@echo "    VERBOSE=1   Show full build output"
	@echo "    DRY_RUN=1   Show what would be done without doing it"
	@echo ""

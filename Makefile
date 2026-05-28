# Makefile for Beamcore.Agent - Mistral API client

.PHONY: all deps compile test format dialyzer shell clean help chat chat-plain tui run-ledger run-memory

ifneq (,$(wildcard .env))
include .env
export MISTRAL_API_KEY
export MISTRAL_BASE_URL
export BEAMCORE_IMAGE_PROVIDER
export MISTRAL_IMAGE_MODEL
export MISTRAL_IMAGE_AGENT_ID
endif

# Default target
all: compile

# Install dependencies
deps:
	mix deps.get

# Compile the project
compile: deps
	mix compile

# Run tests
test: compile
	mix test

# Format code
format:
	mix format

# Run dialyzer (static analysis)
dialyzer:
	mix dialyzer

# Start interactive shell
shell: compile
	iex -S mix

# Clean build artifacts
clean:
	rm -rf _build deps

# Installation
INSTALL_PATH ?= $(HOME)/.agent/app
BIN_PATH ?= $(HOME)/.local/bin/agent

install: deps
	@echo "Installing agent..."
	@mkdir -p $(dir $(INSTALL_PATH))
	@MIX_ENV=prod mix release agent --overwrite --path $(INSTALL_PATH)
	@mkdir -p $(dir $(BIN_PATH))
	@echo "#!/bin/sh" > $(BIN_PATH)
	@echo 'exec $(INSTALL_PATH)/bin/agent eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"' >> $(BIN_PATH)
	@chmod +x $(BIN_PATH)
	@echo "Successfully installed agent to $(INSTALL_PATH)"
	@echo "Executable created at $(BIN_PATH)"

uninstall:
	@echo "Uninstalling agent..."
	@rm -rf $(INSTALL_PATH)
	@rm -f $(BIN_PATH)
	@echo "Successfully uninstalled agent"

# Show help
help:
	@echo "Available targets:"
	@echo "  all          - Compile the project (default)"
	@echo "  deps         - Install dependencies"
	@echo "  compile      - Compile the project"
	@echo "  test         - Run tests"
	@echo "  format       - Format code"
	@echo "  dialyzer     - Run static analysis"
	@echo "  shell        - Start interactive shell"
	@echo "  clean        - Clean build artifacts"
	@echo "  install      - Install agent to $(INSTALL_PATH) and $(BIN_PATH)"
	@echo "  uninstall    - Remove agent from $(INSTALL_PATH) and $(BIN_PATH)"
	@echo "  help         - Show this help message"
	@echo "  chat         - Start the primary agent TUI"
	@echo "  chat-plain   - Start the plain emergency fallback"

# Run the application
run: compile
	mix run --no-halt

# API client test
api-test: compile
	mix run -e "Beamcore.Agent.test_api_call()"

# Direct API client inspection
api-inspect: compile
	mix run -e "IO.inspect Beamcore.OpenAI.client()"

# Test a simple completion
completion-test: compile
	mix run -e "client = Beamcore.OpenAI.client(); IO.puts(\"Client ready for API calls\"); IO.inspect(client)"

# Start primary agent chat
chat: compile
	mix run -e "Beamcore.Agent.chat()"

# Start plain emergency fallback
chat-plain: compile
	mix run -e "Beamcore.Agent.chat(:plain)"

# Alias for the primary TUI entrypoint
tui: chat

# Environment setup
init:
	@if [ ! -f .env ]; then cp .env.example .env; fi
	@echo "Set MISTRAL_API_KEY in .env for real chat/API usage"

# Create .env.example if it doesn't exist
.env.example:
	printf "MISTRAL_API_KEY=\nMISTRAL_BASE_URL=https://api.mistral.ai/v1\nBEAMCORE_IMAGE_PROVIDER=mistral\nMISTRAL_IMAGE_MODEL=mistral-medium-latest\nMISTRAL_IMAGE_AGENT_ID=\n" > .env.example

# Add a target to update dependencies
update:
	mix deps.update --all
	mix deps.compile

# Run the ledger service standalone as a globally registered cluster member
run-ledger: compile
	LEDGER_GLOBAL=true elixir --sname ledger -S mix run --no-halt

# Run the memory service standalone as a globally registered cluster member
run-memory: compile
	MEMORY_GLOBAL=true elixir --sname memory -S mix run --no-halt



# Makefile for Beamcore.Agent - Mistral API client

.PHONY: all deps compile test format dialyzer shell clean help

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
	@echo "  chat         - Start interactive chat with Mistral"

# Run the application
run: compile
	mix run --no-halt

# API client test
api-test: compile
	MISTRAL_API_KEY=$(MISTRAL_API_KEY) mix run -e "Beamcore.Agent.test_api_call()"

# Direct API client inspection
api-inspect: compile
	MISTRAL_API_KEY=$(MISTRAL_API_KEY) mix run -e "IO.inspect Beamcore.Agent.OpenAI.client()"

# Test a simple completion
completion-test: compile
	MISTRAL_API_KEY=$(MISTRAL_API_KEY) mix run -e "client = Beamcore.Agent.OpenAI.client(); IO.puts(\"Client ready for API calls\"); IO.inspect(client)"

# Start interactive chat
chat: compile
	MISTRAL_API_KEY=$(MISTRAL_API_KEY) mix run -e "Beamcore.Agent.chat()"

# Environment setup
init:
	cp .env.example .env 2>/dev/null || true
	@echo "Make sure to set your MISTRAL_API_KEY in .env"

# Create .env.example if it doesn't exist
.env.example:
	echo "export MISTRAL_API_KEY=your_api_key_here" > .env.example

# Add a target to update dependencies
update:
	mix deps.update --all
	mix deps.compile
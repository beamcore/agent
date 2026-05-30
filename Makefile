.PHONY: all install clean uninstall chat

INSTALL_DIR ?= $(HOME)/.beamcore/app
BIN_DIR ?= $(HOME)/.local/bin
LAUNCHER ?= $(BIN_DIR)/core
DRY_RUN ?= 0

# Install the agent globally via release
install: release
	@echo "Installing agent to $(INSTALL_DIR)..."
	@if [ "$(DRY_RUN)" = "1" ]; then \
		echo "DRY_RUN rm -rf $(INSTALL_DIR)"; \
		echo "DRY_RUN mkdir -p $(INSTALL_DIR)"; \
		echo "DRY_RUN cp -a _build/prod/rel/agent/. $(INSTALL_DIR)/"; \
		echo "DRY_RUN mkdir -p $(BIN_DIR)"; \
		echo "DRY_RUN write launcher $(LAUNCHER)"; \
		printf '%s\n%s\n' '#!/bin/sh' 'exec "$(INSTALL_DIR)/bin/agent" eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"'; \
	else \
		rm -rf "$(INSTALL_DIR)"; \
		mkdir -p "$(INSTALL_DIR)"; \
		cp -a _build/prod/rel/agent/. "$(INSTALL_DIR)/"; \
		echo "Creating $(LAUNCHER)..."; \
		mkdir -p "$(BIN_DIR)"; \
		printf '%s\n%s\n' '#!/bin/sh' 'exec "$(INSTALL_DIR)/bin/agent" eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"' > "$(LAUNCHER)"; \
		chmod +x "$(LAUNCHER)"; \
		echo "✅ Installed to $(INSTALL_DIR) and $(LAUNCHER)"; \
	fi

# Uninstall
uninstall:
	@echo "Removing agent deployment..."
	rm -rf "$(INSTALL_DIR)"
	rm -f "$(LAUNCHER)"
	@echo "✅ Uninstalled"


# Build the release
release: deps compile
	MIX_ENV=prod mix release --overwrite

deps:
	mix deps.get

compile:
	mix compile

# Start the agent application and chat
chat: compile
	mix run -e "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"


# Format code
format:
	mix format

# Run dialyzer (static analysis)
dialyzer:
	mix dialyzer

# Start interactive shell
shell: compile
	iex -S mix

# Clean up
clean:
	rm -rf _build
	mix clean

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

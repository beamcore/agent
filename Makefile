.PHONY: all install clean uninstall chat init

INSTALL_DIR ?= $(HOME)/.beamcore/app
BIN_DIR ?= $(HOME)/.local/bin
LAUNCHER ?= $(BIN_DIR)/core
CONFIG_DIR ?= $(HOME)/.beamcore
CONFIG_ENV ?= $(CONFIG_DIR)/.env
DRY_RUN ?= 0
LOAD_ENV = set -a; [ ! -f .env ] || . ./.env; set +a;

# Install the agent globally via release
install: release
	@echo "Installing agent to $(INSTALL_DIR)..."
	@if [ "$(DRY_RUN)" = "1" ]; then \
		echo "DRY_RUN rm -rf $(INSTALL_DIR)"; \
		echo "DRY_RUN mkdir -p $(INSTALL_DIR)"; \
		echo "DRY_RUN cp -a _build/prod/rel/agent/. $(INSTALL_DIR)/"; \
		echo "DRY_RUN mkdir -p $(BIN_DIR)"; \
		echo "DRY_RUN write launcher $(LAUNCHER)"; \
		printf '%s\n%s\n%s\n%s\n%s\n%s\n' '#!/bin/sh' 'set -a' '[ ! -f "$$HOME/.beamcore/.env" ] || . "$$HOME/.beamcore/.env"' '[ ! -f ".env" ] || . ".env"' 'set +a' 'exec "$(INSTALL_DIR)/bin/agent" eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"'; \
	else \
		rm -rf "$(INSTALL_DIR)"; \
		mkdir -p "$(INSTALL_DIR)"; \
		cp -a _build/prod/rel/agent/. "$(INSTALL_DIR)/"; \
		echo "Creating $(LAUNCHER)..."; \
		mkdir -p "$(BIN_DIR)"; \
		printf '%s\n%s\n%s\n%s\n%s\n%s\n' '#!/bin/sh' 'set -a' '[ ! -f "$$HOME/.beamcore/.env" ] || . "$$HOME/.beamcore/.env"' '[ ! -f ".env" ] || . ".env"' 'set +a' 'exec "$(INSTALL_DIR)/bin/agent" eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"' > "$(LAUNCHER)"; \
		chmod +x "$(LAUNCHER)"; \
		echo "✅ Installed to $(INSTALL_DIR) and $(LAUNCHER)"; \
	fi

# Uninstall
uninstall:
	@echo "Removing agent deployment..."
	rm -rf "$(INSTALL_DIR)"
	rm -f "$(LAUNCHER)"
	@echo "✅ Uninstalled"
	@echo "Kept $(CONFIG_ENV)"


# Build the release
release: deps compile
	MIX_ENV=prod mix release --overwrite

deps:
	mix deps.get

compile:
	mix compile

# Start the agent application and chat
chat: compile
	$(LOAD_ENV) mix run -e "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"

# Environment setup
init:
	@if [ "$(DRY_RUN)" = "1" ]; then \
		echo "DRY_RUN mkdir -p $(CONFIG_DIR)"; \
		if [ -f "$(CONFIG_ENV)" ]; then \
			echo "DRY_RUN keep existing $(CONFIG_ENV)"; \
		else \
			echo "DRY_RUN create $(CONFIG_ENV) from .env.example"; \
		fi; \
	elif [ -f "$(CONFIG_ENV)" ]; then \
		echo "$(CONFIG_ENV) already exists; not overwriting."; \
	else \
		mkdir -p "$(CONFIG_DIR)"; \
		cp .env.example "$(CONFIG_ENV)"; \
		echo "Created $(CONFIG_ENV). Set MISTRAL_API_KEY before real chat/API usage."; \
	fi

.env.example:
	printf "MISTRAL_API_KEY=\nMISTRAL_BASE_URL=https://api.mistral.ai/v1\nBEAMCORE_IMAGE_PROVIDER=mistral\nMISTRAL_IMAGE_MODEL=mistral-medium-latest\nMISTRAL_IMAGE_AGENT_ID=\n" > .env.example


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

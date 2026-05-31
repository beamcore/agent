.PHONY: all install clean uninstall chat init config-status format dialyzer shell update run-ledger run-memory release deps compile

INSTALL_DIR ?= $(HOME)/.beamcore/app
BIN_DIR ?= $(HOME)/.local/bin
LAUNCHER ?= $(BIN_DIR)/beamcore
CONFIG_DIR ?= $(HOME)/.beamcore

DRY_RUN ?= 0
PATH_UPDATE ?= 0
VERBOSE ?= 0

LOAD_ENV = set -a; [ ! -f .env ] || . ./.env; set +a;

all: compile

# Install Beamcore globally via release.
# After install:
#   beamcore        -> interactive TUI chat
#   beamcore start  -> raw OTP release background start
#   beamcore stop   -> stop release
#   beamcore remote -> attach to release
install:
	@echo "==> Building Beamcore release"; \
	if [ "$(DRY_RUN)" = "1" ]; then \
		echo "DRY RUN: no install files will be changed, but the release build still runs."; \
	fi; \
	if [ "$(VERBOSE)" = "1" ]; then \
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
	@if [ "$(DRY_RUN)" = "1" ]; then \
		echo ""; \
		echo "Would remove/create app dir and copy release files."; \
		echo "Would write launcher:"; \
		printf '%s\n%s\n%s\n%s\n%s\n' \
			'#!/bin/sh' \
			'if [ "$$#" -eq 0 ]; then' \
			'  exec "$(INSTALL_DIR)/bin/agent" eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"' \
			'fi' \
			'exec "$(INSTALL_DIR)/bin/agent" "$$@"'; \
		echo "✓ Dry run complete"; \
	else \
		rm -rf "$(INSTALL_DIR)"; \
		mkdir -p "$(INSTALL_DIR)"; \
		cp -a _build/prod/rel/agent/. "$(INSTALL_DIR)/"; \
		mkdir -p "$(BIN_DIR)"; \
		printf '%s\n%s\n%s\n%s\n%s\n' \
			'#!/bin/sh' \
			'if [ "$$#" -eq 0 ]; then' \
			'  exec "$(INSTALL_DIR)/bin/agent" eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"' \
			'fi' \
			'exec "$(INSTALL_DIR)/bin/agent" "$$@"' > "$(LAUNCHER)"; \
		chmod +x "$(LAUNCHER)"; \
		echo "✓ Installed"; \
	fi
	@echo ""
	@$(MAKE) --no-print-directory init DRY_RUN=$(DRY_RUN)
	@echo ""
	@echo "==> Launcher"
	@printf '%-17s %s\n' "beamcore" "open interactive TUI chat"
	@printf '%-17s %s\n' "beamcore start" "start OTP release in background"
	@printf '%-17s %s\n' "beamcore stop" "stop OTP release"
	@printf '%-17s %s\n' "beamcore remote" "attach to running release"
	@echo ""
	@echo "==> PATH"
	@rc_file="$(HOME)/.profile"; \
	user_shell="$${SHELL:-$(SHELL)}"; \
	case "$$user_shell" in \
		*zsh*) rc_file="$(HOME)/.zshrc" ;; \
		*bash*) rc_file="$(HOME)/.bashrc" ;; \
	esac; \
	path_line='export PATH="$(BIN_DIR):$$PATH"'; \
	case ":$$PATH:" in \
		*:"$(BIN_DIR)":*) \
			echo "✓ $(BIN_DIR) is in PATH"; \
			echo "Run: beamcore"; \
			;; \
		*) \
			echo "⚠ beamcore is not available in this terminal yet"; \
			echo "$(BIN_DIR) is not in PATH"; \
			echo ""; \
			if [ "$(PATH_UPDATE)" = "1" ]; then \
				if [ "$(DRY_RUN)" = "1" ]; then \
					echo "DRY RUN: would append to $$rc_file if missing:"; \
					echo "  $$path_line"; \
				elif [ -f "$$rc_file" ] && grep -F "$(BIN_DIR)" "$$rc_file" >/dev/null 2>&1; then \
					echo "$$rc_file already mentions $(BIN_DIR); not appending."; \
				else \
					printf '\n%s\n' "$$path_line" >> "$$rc_file"; \
					echo "Added $(BIN_DIR) to $$rc_file"; \
				fi; \
				echo "For this terminal, run: source $$rc_file"; \
				echo "Or open a new terminal."; \
			else \
				echo "Use it now:"; \
				echo "  export PATH=\"$(BIN_DIR):\$$PATH\""; \
				echo "  beamcore"; \
				echo ""; \
				echo "Make it permanent:"; \
				echo "  echo '$$path_line' >> $$rc_file"; \
				echo "  source $$rc_file"; \
				echo ""; \
				echo "Or run directly:"; \
				echo "  $(LAUNCHER)"; \
				echo ""; \
				echo "Opt in to updating shell config during install:"; \
				echo "  make install PATH_UPDATE=1"; \
			fi; \
			;; \
	esac
	@$(MAKE) --no-print-directory config-status

# Uninstall Beamcore app and launcher.
# User config directory is intentionally preserved.
uninstall:
	@echo "==> Uninstalling Beamcore"
	@rm -rf "$(INSTALL_DIR)"
	@rm -f "$(LAUNCHER)"
	@echo "removed app:      $(INSTALL_DIR)"
	@echo "removed launcher: $(LAUNCHER)"
	@echo "kept config dir:  $(CONFIG_DIR)"
	@echo "✓ Uninstalled"

# Build the release.
release: deps compile
	MIX_ENV=prod mix release --overwrite

deps:
	mix deps.get

compile:
	mix compile

# Start the agent application and chat in development mode.
# Loads local .env from the repository if present.
chat: compile
	$(LOAD_ENV) mix run -e "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"

# Create global Beamcore config directory.
init: .env.example
	@echo "==> Configuring Beamcore"
	@if [ "$(DRY_RUN)" = "1" ]; then \
		echo "DRY_RUN mkdir -p $(CONFIG_DIR)"; \
		if [ -d "$(CONFIG_DIR)" ]; then \
			echo "DRY_RUN config directory already exists"; \
		else \
			echo "DRY_RUN would create config directory"; \
		fi; \
	elif [ -d "$(CONFIG_DIR)" ]; then \
		echo "Config directory $(CONFIG_DIR) already exists."; \
	else \
		mkdir -p "$(CONFIG_DIR)"; \
		echo "Created config directory: $(CONFIG_DIR)"; \
	fi

config-status:
	@echo ""
	@echo "==> Config"
	@if [ ! -d "$(CONFIG_DIR)" ]; then \
		echo "⚠ Beamcore config directory is missing: $(CONFIG_DIR)"; \
		echo ""; \
		echo "Create it with:"; \
		echo "  make init"; \
	else \
		echo "✓ Config directory: $(CONFIG_DIR)"; \
	fi

.env.example:
	printf "MISTRAL_API_KEY=\nMISTRAL_BASE_URL=https://api.mistral.ai/v1\nBEAMCORE_IMAGE_PROVIDER=mistral\nMISTRAL_IMAGE_MODEL=mistral-medium-latest\nMISTRAL_IMAGE_AGENT_ID=\n" > .env.example

# Format code.
format:
	mix format

# Run dialyzer.
dialyzer:
	mix dialyzer

# Start interactive shell.
shell: compile
	iex -S mix

# Clean build artifacts.
clean:
	rm -rf _build
	mix clean

# Update dependencies.
update:
	mix deps.update --all
	mix deps.compile

# Run the ledger service standalone as a globally registered cluster member.
run-ledger: compile
	LEDGER_GLOBAL=true elixir --sname ledger -S mix run --no-halt

# Run the memory service standalone as a globally registered cluster member.
run-memory: compile
	MEMORY_GLOBAL=true elixir --sname memory -S mix run --no-halt
.PHONY: all install clean uninstall chat

# Install the agent globally via release
install: release
	@echo "Installing agent to $$HOME/.beamcore/app/..."
	rm -rf $$HOME/.beamcore/app
	mkdir -p $$HOME/.beamcore/app
	cp -a _build/prod/rel/agent/. $$HOME/.beamcore/app/
	@echo "Creating $$HOME/.local/bin/core..."
	mkdir -p $$HOME/.local/bin
	echo '#!/bin/sh' > $$HOME/.local/bin/core
	echo 'exec /home/brv/.beamcore/app/bin/agent eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"' >> $$HOME/.local/bin/core
	chmod +x $$HOME/.local/bin/core
	@echo "✅ Installed to $$HOME/.beamcore/app and $$HOME/.local/bin/core"

# Uninstall
uninstall:
	@echo "Removing agent deployment..."
	rm -rf $$HOME/.beamcore/app
	rm -f $$HOME/.local/bin/core
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

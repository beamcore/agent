#!/bin/bash

# Get the absolute path of the project directory
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Target path for the core command
TARGET_PATH="$HOME/.local/bin/core"

# Create the target directory if it doesn't exist
mkdir -p "$(dirname "$TARGET_PATH")"

# Build the release to generate the agent binary
cd "$PROJECT_DIR" && MIX_ENV=prod mix release --overwrite

# Write the wrapper script using a here-document with a quoted delimiter
cat > "$TARGET_PATH" << ENDOFSCRIPT
#!/bin/bash
RELEASE_BIN="$PROJECT_DIR/_build/prod/rel/agent/bin/agent"

if [ \$# -eq 0 ]; then
  exec "\$RELEASE_BIN" eval "Application.ensure_all_started(:agent); Beamcore.Agent.chat()"
else
  exec "\$RELEASE_BIN" "\$@"
fi
ENDOFSCRIPT

# Make the wrapper script executable
chmod +x "$TARGET_PATH"

echo "Installed core command to $TARGET_PATH"


import Config

config :beamcore, :rate_limit_ms, 1000
config :beamcore, :provider_receive_timeout_ms, 300_000
config :beamcore, :mesh_enabled, true
config :beamcore, :mcp_enabled, false

# ex_ratatui NIF: source-build in dev/test by default (requires a Rust
# toolchain) so local builds don't depend on precompiled downloads.
# Set EX_RATATUI_BUILD=0 to use the upstream precompiled artifact instead
# (CI does this — its runners have no Rust toolchain). Prod always uses the
# precompiled NIF — the same artifact release.yml ships — and can never
# source-build since :rustler is a dev/test-only dep.
config :rustler_precompiled, :force_build,
  ex_ratatui: config_env() != :prod and System.get_env("EX_RATATUI_BUILD", "1") != "0"

if Config.config_env() == :test do
  config :beamcore, :completions_module, Beamcore.Agent.MockCompletions
  config :beamcore, :rate_limit_ms, 0
  config :beamcore, :memory_dets_path, "tmp/test_memory.dets"
  config :beamcore, :config_dets_path, "tmp/test_config.dets"
  config :beamcore, :mesh_enabled, false
  config :beamcore, :mcp_enabled, false
end

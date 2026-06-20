import Config

config :beamcore, :rate_limit_ms, 1000
config :beamcore, :provider_receive_timeout_ms, 300_000

if Config.config_env() == :test do
  config :beamcore, :completions_module, Beamcore.Agent.MockCompletions
  config :beamcore, :rate_limit_ms, 0
  config :beamcore, :memory_dets_path, "tmp/test_memory.dets"
  config :beamcore, :config_dets_path, "tmp/test_config.dets"
end

import Config

config :agent, :rate_limit_ms, 1000

if Config.config_env() == :test do
  config :agent, :completions_module, Beamcore.Agent.MockCompletions
  config :agent, :http_client, Beamcore.Agent.MockHTTPClient
  config :agent, :rate_limit_ms, 0
  config :agent, :memory_dets_path, "tmp/test_memory.dets"
  config :agent, :config_dets_path, "tmp/test_config.dets"
end

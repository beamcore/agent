import Config

config :agent, :rate_limit_ms, 1000

if Config.config_env() == :test do
  config :agent, :completions_module, Beamcore.Agent.MockCompletions
  config :agent, :http_client, Beamcore.Agent.MockHTTPClient
  config :agent, :rate_limit_ms, 0
end

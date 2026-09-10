import Config
config :phoenix, :json_library, Jason

config :window, Window.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Window.PubSub,
  server: false,
  secret_key_base: String.duplicate("test-only-not-used-by-launcher-", 3)

config :logger, level: :warning

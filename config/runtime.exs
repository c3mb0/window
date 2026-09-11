import Config

if System.get_env("WINDOW_SERVER") == "1" do
  config :window, :storage_enabled, System.get_env("WINDOW_STORAGE") != "0"

  config :window,
         :storage_directory,
         System.get_env("WINDOW_DATA_DIR") || :filename.basedir(:user_data, "window")

  config :window,
         :outbox_limit,
         String.to_integer(System.get_env("WINDOW_OUTBOX_LIMIT_BYTES", "67108864"))

  port = String.to_integer(System.get_env("WINDOW_PORT", "4050"))
  token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  origin = "http://127.0.0.1:#{port}"
  config :window, :token, token
  config :window, :origin, origin

  config :window, Window.Endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: port],
    url: [host: "127.0.0.1", port: port],
    check_origin: [origin],
    secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
end

config :window, :helper, Path.expand("../vendor/play/target/debug/pty_helper", __DIR__)

config :window,
       :archive_helper,
       Path.expand("../native/archive/target/debug/window-archive", __DIR__)

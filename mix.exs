defmodule Window.MixProject do
  use Mix.Project

  def project do
    [app: :window, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
  end

  def application, do: [mod: {Window.Application, []}, extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      # Elixir 1.20 bitstring pin fix; return to Hex after the next release.
      {:phoenix_template,
       github: "phoenixframework/phoenix_template",
       ref: "a5dd67cee1190bca4b7662ec3553373b5d67a0e6",
       override: true},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:exqlite, "== 0.40.0"},
      {:pty_lab, path: "vendor/play/erlang/pty_lab", manager: :rebar3}
    ]
  end
end

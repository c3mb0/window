defmodule Window.MixProject do
  use Mix.Project

  def project do
    [app: :window, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
  end

  def application, do: [mod: {Window.Application, []}, extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:pty_lab, path: "vendor/play/erlang/pty_lab", manager: :rebar3}
    ]
  end
end

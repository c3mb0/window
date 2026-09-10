defmodule Window.Application do
  use Application

  def start(_type, _args) do
    children = [{Phoenix.PubSub, name: Window.PubSub}, Window.Endpoint]
    result = Supervisor.start_link(children, strategy: :one_for_one, name: Window.Supervisor)

    if Application.get_env(:window, :token) do
      IO.puts(
        "\nwindow: #{Application.fetch_env!(:window, :origin)}/#token=#{Application.fetch_env!(:window, :token)}\n"
      )
    end

    result
  end
end

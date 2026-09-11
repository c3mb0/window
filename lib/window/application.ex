defmodule Window.Application do
  use Application

  def start(_type, _args) do
    children = [{Phoenix.PubSub, name: Window.PubSub}, Window.Endpoint]
    result = Supervisor.start_link(children, strategy: :one_for_one, name: Window.Supervisor)

    if match?({:ok, _}, result) and Application.get_env(:window, :token) do
      url =
        "#{Application.fetch_env!(:window, :origin)}/#token=#{Application.fetch_env!(:window, :token)}"

      IO.puts("\nwindow: #{url}\n")

      if System.get_env("WINDOW_OPEN_BROWSER") == "1", do: open_browser(url)
    end

    result
  end

  defp open_browser(url) do
    command =
      case :os.type() do
        {:unix, :darwin} ->
          {"/usr/bin/open", ["-a", "Google Chrome", url]}

        _ ->
          executable =
            Enum.find_value(
              ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"],
              &System.find_executable/1
            )

          if executable, do: {executable, [url]}
      end

    case command do
      nil ->
        IO.puts(:stderr, "Chrome/Chromium not found; open the startup URL manually.")

      {executable, args} ->
        # A browser may stay in the foreground; never block application startup on it.
        Task.start(fn ->
          try do
            case System.cmd(executable, args, stderr_to_stdout: true) do
              {_, 0} -> :ok
              _ -> IO.puts(:stderr, "Could not open Chrome; open the startup URL manually.")
            end
          rescue
            _ -> IO.puts(:stderr, "Could not open Chrome; open the startup URL manually.")
          end
        end)
    end
  end
end

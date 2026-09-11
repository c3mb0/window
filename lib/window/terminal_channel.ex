defmodule Window.TerminalChannel do
  use Phoenix.Channel

  def join("terminal:" <> id, %{"rows" => rows, "cols" => cols} = params, socket)
      when byte_size(id) <= 80 and rows in 1..1000 and cols in 2..1000 do
    # The window session owns the PTY across a short page-refresh handoff.
    shell =
      System.get_env("SHELL", if(:os.type() == {:unix, :darwin}, do: "/bin/zsh", else: "/bin/sh"))

    env =
      System.get_env()
      |> Map.drop(["WINDOW_SERVER", "WINDOW_PORT"])
      |> Map.put("TERM", "xterm-256color")
      |> Map.put("COLORTERM", "truecolor")

    spec = %{
      "executable" => shell,
      "argv" => ["-il"],
      "cwd" => System.user_home!(),
      "environment" => env,
      "attachment" => "ctty",
      "terminal" => %{
        "dimensions" => %{"rows" => rows, "cols" => cols, "xpixel" => 0, "ypixel" => 0}
      }
    }

    options = %{
      helper: Application.fetch_env!(:window, :helper) |> String.to_charlist(),
      identity: %{"experiment" => "window", "cell" => "interactive", "session" => id},
      spec: spec
    }

    with {:ok, session} <- Window.TerminalSession.open(id, options, params["resume"] == true),
         {:ok, worker} <-
           Window.TerminalSession.call(session, {:attach, Map.get(params, "output_seq", 0)}) do
      Process.monitor(session)
      {:ok, assign(socket, worker: worker, session: session, ended: false, input_seq: 0)}
    else
      _ -> {:error, %{reason: "Terminal unavailable or refresh snapshot expired"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "Invalid terminal dimensions"}}

  def handle_in("input", %{"hex" => hex, "seq" => seq}, socket)
      when is_binary(hex) and byte_size(hex) <= 8192 and is_integer(seq) do
    with false <- socket.assigns.ended,
         true <- seq == socket.assigns.input_seq + 1,
         {:ok, _} <- Base.decode16(hex, case: :mixed),
         :ok <- command(socket, %{"command" => "write", "hex" => hex}) do
      {:reply, :ok, assign(socket, :input_seq, seq)}
    else
      _ -> {:reply, {:error, %{reason: "Input rejected"}}, socket}
    end
  end

  def handle_in("credit", %{"seq" => seq}, socket) when is_integer(seq) do
    respond(Window.TerminalSession.call(socket.assigns.session, {:credit, seq}), socket)
  end

  def handle_in("resize", %{"rows" => r, "cols" => c}, socket)
      when r in 1..1000 and c in 2..1000 do
    respond(command(socket, %{"command" => "resize", "rows" => r, "cols" => c}), socket)
  end

  def handle_in("close", _, socket) do
    result = Window.TerminalSession.call(socket.assigns.session, :close)
    respond(result, assign(socket, :ended, true))
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "Invalid request"}}, socket}

  defp command(socket, command),
    do: Window.TerminalSession.call(socket.assigns.session, {:command, command})

  defp respond(:ok, socket), do: {:reply, :ok, socket}

  defp respond(_, socket),
    do: {:reply, {:error, %{reason: "Session closed or request rejected"}}, socket}

  def handle_info({:terminal_event, "replaced", _}, socket) do
    push(socket, "failed", %{reason: "Terminal attached in another page"})
    {:stop, :normal, socket}
  end

  def handle_info({:terminal_event, event, data}, socket) do
    push(socket, event, data)
    {:noreply, if(event in ["exited", "failed"], do: assign(socket, :ended, true), else: socket)}
  end

  def handle_info({:DOWN, _, :process, _, _}, socket) do
    unless socket.assigns.ended, do: push(socket, "failed", %{reason: "Session stopped"})
    {:noreply, assign(socket, :ended, true)}
  end
end

defmodule Window.TerminalChannel do
  use Phoenix.Channel

  def join("terminal:" <> id, %{"rows" => rows, "cols" => cols}, socket)
      when byte_size(id) <= 80 and rows in 1..1000 and cols in 2..1000 do
    # A channel can create exactly once. Browser disables rejoin after any loss.
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

    case :pty_session.start_interactive(options) do
      {:ok, worker} ->
        Process.monitor(worker)
        {:ok, assign(socket, worker: worker, ended: false, input_seq: 0)}

      {:error, _} ->
        {:error, %{reason: "Shell could not start"}}
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

  def handle_in("credit", %{"bytes" => n}, socket) when is_integer(n) and n in 1..65536 do
    respond(command(socket, %{"command" => "credit", "bytes" => n}), socket)
  end

  def handle_in("resize", %{"rows" => r, "cols" => c}, socket)
      when r in 1..1000 and c in 2..1000 do
    respond(command(socket, %{"command" => "resize", "rows" => r, "cols" => c}), socket)
  end

  def handle_in("close", _, socket) do
    result = command(socket, %{"command" => "close"})
    respond(result, assign(socket, :ended, true))
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "Invalid request"}}, socket}

  defp command(socket, command),
    do: :pty_session.interactive_command(socket.assigns.worker, command)

  defp respond(:ok, socket), do: {:reply, :ok, socket}

  defp respond(_, socket),
    do: {:reply, {:error, %{reason: "Session closed or request rejected"}}, socket}

  def handle_info({:interactive_event, _, %{"event" => event, "data" => data}}, socket) do
    case event do
      "pty_output" -> push(socket, "output", data)
      "child_exit" -> push(socket, "exited", data)
      "error" -> push(socket, "failed", %{reason: "PTY helper failed"})
      "resized" -> push(socket, "resized", data)
      "closed" -> push(socket, "closed", data)
      _ -> :ok
    end

    {:noreply,
     if(event in ["child_exit", "error", "closed"],
       do: assign(socket, :ended, true),
       else: socket
     )}
  end

  def handle_info({:interactive_end, _, code}, socket) do
    unless socket.assigns.ended, do: push(socket, "failed", %{reason: "Helper stopped (#{code})"})
    {:noreply, assign(socket, :ended, true)}
  end

  def handle_info({:interactive_failure, _, _}, socket) do
    push(socket, "failed", %{reason: "PTY connection failed"})
    {:noreply, assign(socket, :ended, true)}
  end

  def handle_info({:DOWN, _, :process, _, _}, socket) do
    unless socket.assigns.ended, do: push(socket, "failed", %{reason: "Session stopped"})
    {:noreply, assign(socket, :ended, true)}
  end
end

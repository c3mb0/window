defmodule WindowTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  @endpoint Window.Endpoint
  setup do
    Application.put_env(:window, :token, "test-capability")
    :ok
  end

  test "socket requires startup capability" do
    assert :error = connect(Window.Socket, %{})
    assert :error = connect(Window.Socket, %{"token" => "wrong"})
    assert {:ok, _} = connect(Window.Socket, %{"token" => "test-capability"})
  end

  test "shell uses real PTY, resize, ordered input and owner cleanup" do
    {:ok, socket} = connect(Window.Socket, %{"token" => "test-capability"})
    {:ok, _, socket} = subscribe_and_join(socket, "terminal:test", %{"rows" => 25, "cols" => 90})
    worker = socket.assigns.worker
    assert Process.alive?(worker)
    ref = push(socket, "resize", %{"rows" => 35, "cols" => 99})
    assert_reply(ref, :ok)
    assert_push("resized", %{"rows" => 35, "cols" => 99})

    ref =
      push(socket, "input", %{"hex" => Base.encode16("printf 'WINDOW_CHECK\\n'\n"), "seq" => 1})

    assert_reply(ref, :ok)
    ref = push(socket, "input", %{"hex" => "61", "seq" => 1})
    assert_reply(ref, :error)
    ref = push(socket, "credit", %{"bytes" => 65536})
    assert_reply(ref, :error)
    ref = push(socket, "close", %{})
    assert_reply(ref, :ok)
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 3500
  end

  test "worker failure becomes a visible channel failure" do
    {:ok, socket} = connect(Window.Socket, %{"token" => "test-capability"})

    {:ok, _, socket} =
      subscribe_and_join(socket, "terminal:failure", %{"rows" => 24, "cols" => 80})

    Process.exit(socket.assigns.worker, :kill)
    assert_push("failed", %{reason: "Session stopped"}, 3000)
  end

  test "refresh reattaches the same worker and replay credits are idempotent" do
    id = "terminal:refresh-#{System.unique_integer([:positive])}"
    {:ok, socket} = connect(Window.Socket, %{"token" => "test-capability"})
    {:ok, _, first} = subscribe_and_join(socket, id, %{"rows" => 24, "cols" => 80})
    worker = first.assigns.worker
    session = first.assigns.session
    assert_push("output", %{seq: seq}, 3000)
    ref = push(first, "credit", %{"seq" => seq})
    assert_reply(ref, :ok)
    ref = push(first, "credit", %{"seq" => seq})
    assert_reply(ref, :ok)
    assert {:error, :invalid_request} = Window.TerminalSession.call(session, :close)
    Process.unlink(first.channel_pid)
    close(first)
    assert Process.alive?(worker)

    {:ok, fresh} = connect(Window.Socket, %{"token" => "test-capability"})

    {:ok, _, resumed} =
      subscribe_and_join(fresh, id, %{
        "rows" => 24,
        "cols" => 80,
        "resume" => true,
        "output_seq" => 0
      })

    assert resumed.assigns.worker == worker
    assert resumed.assigns.session == session
    assert_push("output", %{seq: ^seq}, 3000)
    ref = push(resumed, "input", %{"hex" => Base.encode16("echo refresh\n"), "seq" => 1})
    assert_reply(ref, :ok)
    ref = push(resumed, "close", %{})
    assert_reply(ref, :ok)
  end

  test "refresh expiry closes the worker and never silently creates a replacement" do
    Application.put_env(:window, :refresh_grace_ms, 150)
    on_exit(fn -> Application.delete_env(:window, :refresh_grace_ms) end)
    id = "expiry-#{System.unique_integer([:positive])}"
    {:ok, socket} = connect(Window.Socket, %{"token" => "test-capability"})

    {:ok, _, socket} =
      subscribe_and_join(socket, "terminal:" <> id, %{"rows" => 24, "cols" => 80})

    worker = socket.assigns.worker
    session = socket.assigns.session
    session_ref = Process.monitor(session)
    worker_ref = Process.monitor(worker)
    Process.unlink(socket.channel_pid)
    close(socket)
    assert_receive {:DOWN, ^session_ref, :process, ^session, _}, 2000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 3500
    assert {:error, :expired} = Window.TerminalSession.open(id, %{}, true)
    assert [] = Registry.lookup(Window.Terminals, id)
  end

  test "invalid refresh sequence is rejected without replacing the live owner" do
    id = "terminal:invalid-refresh-#{System.unique_integer([:positive])}"
    {:ok, socket} = connect(Window.Socket, %{"token" => "test-capability"})
    {:ok, _, first} = subscribe_and_join(socket, id, %{"rows" => 24, "cols" => 80})
    {:ok, second} = connect(Window.Socket, %{"token" => "test-capability"})

    assert {:error, _} =
             subscribe_and_join(second, id, %{
               "rows" => 24,
               "cols" => 80,
               "resume" => true,
               "output_seq" => 1_000_000
             })

    ref = push(first, "input", %{"hex" => "0d", "seq" => 1})
    assert_reply(ref, :ok)
    ref = push(first, "close", %{})
    assert_reply(ref, :ok)
  end

  @tag timeout: 75_000
  test "interactive shell survives 60 seconds and owner loss closes after grace" do
    parent = self()

    owner =
      spawn(fn ->
        spec = %{
          "executable" => "/bin/sh",
          "argv" => ["-i"],
          "cwd" => "/tmp",
          "environment" => %{"PATH" => "/usr/bin:/bin", "TERM" => "xterm-256color"},
          "attachment" => "ctty",
          "terminal" => %{
            "dimensions" => %{"rows" => 24, "cols" => 80, "xpixel" => 0, "ypixel" => 0}
          }
        }

        {:ok, worker} =
          :pty_session.start_interactive(%{
            helper: Application.fetch_env!(:window, :helper) |> String.to_charlist(),
            identity: %{"experiment" => "window", "cell" => "test", "session" => "lifetime"},
            spec: spec
          })

        send(parent, {:worker, worker})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:worker, worker}, 3000
    Process.sleep(61_000)
    assert Process.alive?(worker)
    monitor = Process.monitor(worker)
    send(owner, :stop)
    Process.sleep(500)
    assert Process.alive?(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 4000
  end
end

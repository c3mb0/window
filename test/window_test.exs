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

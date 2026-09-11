defmodule Window.TerminalSession do
  use GenServer, restart: :temporary

  @history_limit 262_144
  @grace_ms 30_000

  def start_link({id, options}),
    do: GenServer.start_link(__MODULE__, options, name: {:via, Registry, {Window.Terminals, id}})

  def open(id, options, resume) do
    case {Registry.lookup(Window.Terminals, id), resume} do
      {[{pid, _}], true} ->
        {:ok, pid}

      {[], false} ->
        DynamicSupervisor.start_child(Window.TerminalSupervisor, {__MODULE__, {id, options}})

      {[], true} ->
        {:error, :expired}

      _ ->
        {:error, :exists}
    end
  end

  def call(pid, request) do
    GenServer.call(pid, request)
  catch
    :exit, _ -> {:error, :closed}
  end

  def init(options) do
    case :pty_session.start_interactive(options) do
      {:ok, worker} ->
        monitor = Process.monitor(worker)
        timer = expiry_timer()
        id = options.identity["session"]

        Window.SessionStore.observe(id, "created", %{
          "state" => "starting",
          "name" => Map.get(options, :name, "Terminal"),
          "launch_cwd" => options.spec["cwd"],
          "reason" => "PTY worker created"
        })

        {:ok,
         %{
           worker: worker,
           id: id,
           attached_once: false,
           worker_monitor: monitor,
           owner: nil,
           owner_monitor: nil,
           timer: timer,
           seq: 0,
           ack: 0,
           history: [],
           bytes: 0,
           ended: nil
         }}

      error ->
        {:stop, error}
    end
  end

  def handle_call({:attach, seq}, {owner, _}, state)
      when is_integer(seq) and seq >= 0 do
    oldest =
      case state.history do
        [{first, _} | _] -> first
        [] -> state.seq + 1
      end

    if seq > state.seq or seq < oldest - 1 do
      {:reply, {:error, :snapshot_expired}, state}
    else
      state = acknowledge(state, seq)
      if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
      if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])

      if state.owner && state.owner != owner,
        do: send(state.owner, {:terminal_event, "replaced", %{}})

      for {number, hex} <- state.history,
          number > seq,
          do: send(owner, {:terminal_event, "output", %{hex: hex, seq: number}})

      if state.ended,
        do: send(owner, {:terminal_event, elem(state.ended, 0), elem(state.ended, 1)})

      unless state.ended,
        do:
          Window.SessionStore.observe(
            state.id,
            if(state.attached_once, do: "reattached", else: "attached"),
            %{"state" => "live", "reason" => "browser attached"}
          )

      {:reply, {:ok, state.worker},
       %{
         state
         | owner: owner,
           owner_monitor: Process.monitor(owner),
           timer: nil,
           attached_once: true
       }}
    end
  end

  def handle_call({:credit, seq}, {owner, _}, %{owner: owner} = state)
      when is_integer(seq) and seq >= 0 and seq <= state.seq do
    {:reply, :ok, acknowledge(state, seq)}
  end

  def handle_call({:command, command}, {owner, _}, %{owner: owner, ended: nil} = state) do
    result = :pty_session.interactive_command(state.worker, command)

    if command["command"] == "close" do
      {:stop, :normal, result, state}
    else
      {:reply, result, state}
    end
  end

  def handle_call(:close, {owner, _}, %{owner: owner} = state) do
    Window.SessionStore.observe(state.id, "close_requested", %{
      "state" => "close_requested",
      "reason" => "terminal close requested"
    })

    {:stop, :normal, :ok, state}
  end

  def handle_call(:runtime_status, _, state),
    do:
      {:reply,
       %{
         live: is_nil(state.ended) && Process.alive?(state.worker),
         attached: !is_nil(state.owner)
       }, state}

  def handle_call(_, _, state), do: {:reply, {:error, :invalid_request}, state}

  def handle_info(
        {:interactive_event, worker, %{"event" => "pty_output", "data" => %{"hex" => hex}}},
        %{worker: worker} = state
      ) do
    seq = state.seq + 1
    {history, bytes} = trim(state.history ++ [{seq, hex}], state.bytes + div(byte_size(hex), 2))
    emit(state, "output", %{hex: hex, seq: seq})
    {:noreply, %{state | seq: seq, history: history, bytes: bytes}}
  end

  def handle_info({:interactive_event, _, %{"event" => event, "data" => data}}, state) do
    case event do
      "child_exit" ->
        finish(state, "exited", data)

      "error" ->
        finish(state, "failed", %{reason: "PTY helper failed"})

      "resized" ->
        emit(state, "resized", data)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_monitor: ref} = state) do
    unless state.ended,
      do:
        Window.SessionStore.observe(state.id, "detached", %{
          "state" => "detached",
          "reason" => "channel disconnected"
        })

    {:noreply, %{state | owner: nil, owner_monitor: nil, timer: expiry_timer()}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker_monitor: ref} = state),
    do: finish(state, "failed", %{reason: "Session stopped"})

  def handle_info({:interactive_end, _, _}, state),
    do: finish(state, "failed", %{reason: "Helper stopped"})

  def handle_info({:interactive_failure, _, _}, state),
    do: finish(state, "failed", %{reason: "PTY connection failed"})

  def handle_info({:expire, generation}, %{owner: nil, timer: {_, generation}} = state) do
    Window.SessionStore.observe(state.id, "refresh_expired", %{
      "state" => "expired",
      "reason" => "refresh grace elapsed; cleanup requested"
    })

    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if Process.alive?(state.worker),
      do: :pty_session.interactive_command(state.worker, %{"command" => "close"})

    Window.SessionStore.observe(state.id, "owner_stopped", %{
      "reason" => "session owner stopped; child cleanup not independently observed"
    })

    :ok
  end

  defp acknowledge(state, seq) when seq <= state.ack, do: state

  defp acknowledge(state, seq) do
    bytes =
      for {n, hex} <- state.history, n > state.ack and n <= seq, reduce: 0 do
        sum -> sum + div(byte_size(hex), 2)
      end

    if bytes > 0 && Process.alive?(state.worker),
      do:
        :pty_session.interactive_command(state.worker, %{"command" => "credit", "bytes" => bytes})

    %{state | ack: seq}
  end

  defp trim([{_, hex} | rest], bytes) when bytes > @history_limit,
    do: trim(rest, bytes - div(byte_size(hex), 2))

  defp trim(history, bytes), do: {history, bytes}
  defp emit(%{owner: nil}, _, _), do: :ok
  defp emit(state, event, data), do: send(state.owner, {:terminal_event, event, data})

  defp finish(%{ended: nil} = state, event, data) do
    Window.SessionStore.observe(
      state.id,
      if(event == "exited", do: "child_exited", else: "session_failed"),
      %{
        "state" => if(event == "exited", do: "exited", else: "failed"),
        "reason" => Map.get(data, :reason, "child exit observed"),
        "exit_code" => Map.get(data, "code", Map.get(data, :code)),
        "signal" => Map.get(data, "signal", Map.get(data, :signal))
      }
    )

    emit(state, event, data)
    {:noreply, %{state | ended: {event, data}}}
  end

  defp finish(state, _, _), do: {:noreply, state}

  defp expiry_timer do
    generation = make_ref()
    {Process.send_after(self(), {:expire, generation}, grace()), generation}
  end

  defp grace, do: Application.get_env(:window, :refresh_grace_ms, @grace_ms)
end

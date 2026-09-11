defmodule Window.ArchiveDrainer do
  use GenServer
  alias Window.{SessionStore, Archive}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def init(opts) do
    {:ok,
     schedule(
       %{
         store: Keyword.get(opts, :store, SessionStore),
         archive: Keyword.get(opts, :archive, Archive),
         backoff: 250,
         paused: false,
         timer: nil,
         pause_owner: nil
       },
       0
     )}
  end

  def pause(server \\ __MODULE__), do: GenServer.call(server, :pause, 30_000)
  def resume(server \\ __MODULE__), do: GenServer.call(server, :resume)

  def handle_call(:pause, {pid, _}, %{paused: false} = state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    {:reply, :ok, %{state | paused: true, timer: nil, pause_owner: Process.monitor(pid)}}
  end

  def handle_call(:pause, _, state), do: {:reply, {:error, "backup already in progress"}, state}

  def handle_call(:resume, _, state) do
    if state.pause_owner, do: Process.demonitor(state.pause_owner, [:flush])
    {:reply, :ok, schedule(%{state | paused: false, pause_owner: nil}, 0)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{pause_owner: ref} = state) do
    {:noreply, schedule(%{state | paused: false, pause_owner: nil}, 0)}
  end

  def handle_info({:drain, token}, %{paused: false, timer: {_, token}} = state) do
    result = drain(state.store, state.archive)

    backoff =
      case result do
        :ok ->
          250

        {:error, error} ->
          SessionStore.request({:archive_error, error}, state.store)
          min(state.backoff * 2, 10_000)
      end

    {:noreply, schedule(%{state | backoff: backoff}, backoff)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule(state, delay) do
    token = make_ref()
    timer = Process.send_after(self(), {:drain, token}, delay)
    %{state | timer: {timer, token}}
  end

  def drain(store, archive) do
    with {:ok, identity} <- SessionStore.request(:identity, store),
         {:ok, _} <- Archive.request(Map.put(identity, :op, "identity"), archive),
         :ok <- bind_if_needed(identity, store),
         {:ok, batch} <- SessionStore.request(:batch, store) do
      deliver(batch, store, archive)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_if_needed(%{allow_create: false}, _), do: :ok

  defp bind_if_needed(_, store) do
    case SessionStore.request(:bind_archive, store) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp deliver([], store, _) do
    SessionStore.request({:archive_error, nil}, store)
    :ok
  end

  defp deliver(batch, store, archive) do
    with {:ok, %{"ids" => ids}} <- Archive.request(%{op: "append", events: batch}, archive),
         true <- ids == Enum.map(batch, & &1["id"]),
         {:ok, _} <- SessionStore.request({:acknowledge, ids}, store) do
      :ok
    else
      false -> {:error, "archive acknowledgment identity mismatch"}
      {:error, reason} -> {:error, reason}
    end
  end
end

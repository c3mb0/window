defmodule Window.SessionStore do
  use GenServer
  alias Window.Storage.{Admission, Database}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def observe(id, kind, attrs, server \\ __MODULE__) do
    with :ok <- Admission.take(server, 1024) do
      GenServer.cast(server, {:observe, id, kind, attrs})
      :ok
    end
  end

  def request(operation, server \\ __MODULE__) do
    with :ok <- Admission.take(server, 1024) do
      GenServer.call(server, operation, 15_000)
    end
  catch
    :exit, _ -> {:error, "session store unavailable or request timed out"}
  end

  def backup(archive, server \\ __MODULE__) do
    with :ok <- Admission.take(server, 1024),
         do: GenServer.call(server, {:backup, archive}, 120_000)
  catch
    :exit, _ ->
      {:error, "Backup timed out; inspect the backup directory for a completed manifest"}
  end

  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Admission.init(name)

    state = %{
      name: name,
      file: Keyword.fetch!(opts, :file),
      runtime: Keyword.fetch!(opts, :runtime),
      limit: Keyword.get(opts, :outbox_limit, 67_108_864),
      db: nil,
      error: nil,
      archive_error: nil,
      lost_observations: 0
    }

    {:ok, reopen(state)}
  end

  def handle_cast({:observe, id, kind, attrs}, state) do
    state =
      try do
        if !state.db, do: raise("SQLite unavailable")
        Database.record!(state.db, state.runtime, id, kind, attrs, state.limit)
        %{state | error: nil}
      rescue
        error ->
          %{
            state
            | error: Exception.message(error),
              lost_observations: state.lost_observations + 1
          }
      after
        Admission.release(state.name)
      end

    {:noreply, state}
  end

  def handle_call(operation, _, state) do
    try do
      {reply, next} = perform(operation, state)
      {:reply, {:ok, reply}, next}
    rescue
      error ->
        {:reply, {:error, Exception.message(error)}, %{state | error: Exception.message(error)}}
    after
      Admission.release(state.name)
    end
  end

  def handle_info(:reopen, %{db: nil} = state), do: {:noreply, reopen(state)}
  def handle_info(:reconcile, state), do: {:noreply, reconcile(state)}
  def handle_info(_, state), do: {:noreply, state}
  def terminate(_, state), do: Database.close(state.db)

  defp perform(:status, state) do
    pending =
      if state.db do
        [[rows, bytes, oldest]] =
          Database.query!(
            state.db,
            "SELECT count(*), coalesce(sum(length(CAST(payload AS BLOB)) + 256), 0), min(observed_at) FROM outbox"
          )

        %{rows: rows, bytes: bytes, oldest_event_at: oldest}
      else
        %{rows: nil, bytes: nil, oldest_event_at: nil}
      end

    last_commit = if state.db, do: meta(state.db, "last_archive_commit"), else: nil

    files =
      for file <- [
            state.file,
            state.file <> "-wal",
            Path.join(Path.dirname(state.file), "history.duckdb"),
            Path.join(Path.dirname(state.file), "history.duckdb.wal")
          ],
          into: %{} do
        size =
          case File.stat(file) do
            {:ok, stat} -> stat.size
            _ -> 0
          end

        {Path.basename(file), size}
      end

    {%{
       persistence: if(state.db, do: "available", else: "unavailable"),
       error: state.error,
       archive_error: state.archive_error,
       lost_observations: state.lost_observations,
       outbox: pending,
       admission: Admission.counts(state.name),
       files: files,
       disk: Window.Storage.DiskSpace.status(),
       last_archive_commit: last_commit,
       outbox_limit: state.limit
     }, state}
  end

  defp perform({:archive_error, error}, state), do: {%{}, %{state | archive_error: error}}

  defp perform(_, %{db: nil}), do: raise("SQLite unavailable")

  defp perform({:backup, archive}, state),
    do: {Window.Storage.Backup.snapshot!(state, archive), state}

  defp perform(:reconcile, state) do
    next = reconcile(state)
    if next.error, do: raise(next.error)
    {%{}, next}
  end

  defp perform({:list_after, id}, state) do
    rows =
      Database.query!(
        state.db,
        "SELECT payload FROM sessions WHERE id > ? ORDER BY id LIMIT 250",
        [id]
      )

    {Enum.map(rows, fn [payload] -> Jason.decode!(payload) end), state}
  end

  defp perform(:list, state) do
    rows =
      Database.query!(
        state.db,
        "SELECT payload FROM sessions ORDER BY updated_at DESC, id LIMIT 250"
      )

    {Enum.map(rows, fn [payload] -> Jason.decode!(payload) end), state}
  end

  defp perform({:rename, id, name}, state) when is_binary(name) do
    name = String.trim(name)

    if !String.valid?(name) or byte_size(name) not in 1..128,
      do: raise("Use a name between 1 and 128 bytes")

    if Database.query!(state.db, "SELECT id FROM sessions WHERE id = ?", [id]) == [],
      do: raise("Session not found")

    {Database.record!(
       state.db,
       state.runtime,
       id,
       "renamed",
       %{"name" => name, "reason" => "user renamed session"},
       state.limit
     ), state}
  end

  defp perform(:batch, state), do: {Database.batch!(state.db), state}

  defp perform(:identity, state),
    do:
      {%{
         archive_id: meta(state.db, "archive_id"),
         allow_create: meta(state.db, "archive_bound") != "1"
       }, state}

  defp perform(:bind_archive, state) do
    Database.execute!(
      state.db,
      "INSERT OR REPLACE INTO storage_meta VALUES ('archive_bound', '1')"
    )

    {%{}, state}
  end

  defp perform({:acknowledge, ids}, state) when is_list(ids) and length(ids) <= 250 do
    Database.acknowledge!(state.db, ids)
    {%{}, %{state | archive_error: nil}}
  end

  defp perform({:record, id, kind, attrs}, state) do
    {Database.record!(state.db, state.runtime, id, kind, attrs, state.limit),
     %{state | error: nil}}
  end

  defp perform({:pending_timeline, id}, state) do
    rows =
      Database.query!(
        state.db,
        "SELECT id, revision, kind, observed_at, payload FROM outbox WHERE session_id = ? ORDER BY revision DESC LIMIT 250",
        [id]
      )

    {Enum.map(rows, &Map.new(Enum.zip(~w(id revision kind observed_at payload), &1))), state}
  end

  defp perform(_, _), do: raise("unsupported store operation")

  defp reopen(state) do
    try do
      db = Database.open!(state.file)

      reconcile(%{state | db: db, error: nil})
    rescue
      error ->
        Process.send_after(self(), :reopen, 5000)
        %{state | error: Exception.message(error)}
    end
  end

  defp reconcile(state) do
    try do
      rows =
        Database.query!(
          state.db,
          "SELECT id FROM sessions WHERE runtime_id != ? AND state IN ('live', 'detached', 'starting', 'close_requested')",
          [state.runtime]
        )

      for [id] <- rows do
        Database.record!(
          state.db,
          state.runtime,
          id,
          "runtime_interrupted",
          %{"state" => "interrupted", "reason" => "prior runtime ended; process outcome unknown"},
          state.limit
        )
      end

      %{state | error: nil}
    rescue
      error ->
        Process.send_after(self(), :reconcile, 5000)
        %{state | error: Exception.message(error)}
    end
  end

  defp meta(db, key) do
    case Database.query!(db, "SELECT value FROM storage_meta WHERE key = ?", [key]) do
      [[value]] -> value
      [] -> nil
    end
  end
end

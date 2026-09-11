defmodule Window.Storage.Database do
  @moduledoc false
  alias Exqlite.Sqlite3

  def open!(file) do
    File.mkdir_p!(Path.dirname(file))
    {:ok, db} = Sqlite3.open(file)

    try do
      execute!(
        db,
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=250;"
      )

      [[version]] = query!(db, "PRAGMA user_version")
      if version not in [0, 1], do: raise("unsupported SQLite schema #{version}")

      transaction!(db, fn ->
        execute!(db, """
        CREATE TABLE IF NOT EXISTS sessions (
          id TEXT PRIMARY KEY, runtime_id TEXT NOT NULL, revision INTEGER NOT NULL,
          state TEXT NOT NULL, name TEXT NOT NULL, launch_cwd TEXT NOT NULL,
          updated_at INTEGER NOT NULL, last_event_id TEXT NOT NULL, payload TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS outbox (
          commit_order INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
          session_id TEXT NOT NULL REFERENCES sessions(id), revision INTEGER NOT NULL,
          kind TEXT NOT NULL, observed_at INTEGER NOT NULL, schema_version INTEGER NOT NULL,
          payload TEXT NOT NULL, digest TEXT NOT NULL, UNIQUE(session_id, revision)
        );
        CREATE TABLE IF NOT EXISTS storage_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        PRAGMA user_version=1;
        """)

        execute!(db, "INSERT OR IGNORE INTO storage_meta VALUES ('archive_id', ?)", [uuid()])
      end)

      db
    rescue
      error ->
        Sqlite3.close(db)
        reraise error, __STACKTRACE__
    end
  end

  def close(nil), do: :ok
  def close(db), do: Sqlite3.close(db)

  def query!(db, sql, values \\ []) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, values)
      {:ok, rows} = Sqlite3.fetch_all(db, statement)
      rows
    after
      Sqlite3.release(db, statement)
    end
  end

  def execute!(db, sql), do: checked(Sqlite3.execute(db, sql))

  def execute!(db, sql, values) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, values)

      case Sqlite3.step(db, statement) do
        :done -> :ok
        error -> raise "SQLite statement failed: #{inspect(error)}"
      end
    after
      Sqlite3.release(db, statement)
    end
  end

  def transaction!(db, fun) do
    execute!(db, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      execute!(db, "COMMIT")
      result
    rescue
      error ->
        Sqlite3.execute(db, "ROLLBACK")
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        Sqlite3.execute(db, "ROLLBACK")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def record!(db, runtime, id, kind, attrs, limit \\ 67_108_864) do
    result =
      transaction!(db, fn ->
        [[pending]] =
          query!(db, "SELECT coalesce(sum(length(CAST(payload AS BLOB)) + 256), 0) FROM outbox")

        old =
          case query!(db, "SELECT payload FROM sessions WHERE id = ?", [id]) do
            [[payload]] ->
              Jason.decode!(payload)

            [] ->
              %{
                "id" => id,
                "name" => "Terminal",
                "launch_cwd" => "",
                "revision" => 0,
                "state" => "unknown"
              }
          end

        now = System.system_time(:millisecond)
        event_id = uuid()

        state =
          old
          |> Map.merge(
            Map.take(attrs, ["name", "launch_cwd", "state", "reason", "exit_code", "signal"])
          )
          |> Map.merge(%{
            "id" => id,
            "runtime_id" => runtime,
            "revision" => old["revision"] + 1,
            "updated_at" => now,
            "last_event_id" => event_id
          })

        payload = Jason.encode!(state)
        if byte_size(payload) > 8192, do: raise("metadata payload exceeds 8 KiB")
        if pending + byte_size(payload) + 256 > limit, do: raise("outbox admission limit reached")
        digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

        execute!(
          db,
          """
          INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET runtime_id=excluded.runtime_id, revision=excluded.revision,
            state=excluded.state, name=excluded.name, launch_cwd=excluded.launch_cwd,
            updated_at=excluded.updated_at, last_event_id=excluded.last_event_id, payload=excluded.payload
          """,
          [
            id,
            runtime,
            state["revision"],
            state["state"] || "unknown",
            state["name"],
            state["launch_cwd"],
            now,
            event_id,
            payload
          ]
        )

        execute!(
          db,
          "INSERT INTO outbox(id, session_id, revision, kind, observed_at, schema_version, payload, digest) VALUES (?, ?, ?, ?, ?, 1, ?, ?)",
          [event_id, id, state["revision"], kind, now, payload, digest]
        )

        fault(:before_sqlite_commit)
        state
      end)

    fault(:after_sqlite_commit)
    result
  end

  def batch!(db) do
    keys = ~w(commit_order id session_id revision kind observed_at schema_version payload digest)

    query!(
      db,
      "SELECT commit_order, id, session_id, revision, kind, observed_at, schema_version, payload, digest FROM outbox ORDER BY commit_order LIMIT 250"
    )
    |> Enum.map(&Map.new(Enum.zip(keys, &1)))
  end

  def acknowledge!(db, ids) do
    transaction!(db, fn ->
      for id <- ids, do: execute!(db, "DELETE FROM outbox WHERE id = ?", [id])

      execute!(
        db,
        "INSERT INTO storage_meta VALUES ('last_archive_commit', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [to_string(System.system_time(:millisecond))]
      )
    end)
  end

  def uuid do
    <<head::48, _::4, middle::12, _::2, tail::62>> = :crypto.strong_rand_bytes(16)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> =
      <<head::48, 4::4, middle::12, 2::2, tail::62>> |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  defp checked(:ok), do: :ok
  defp checked(error), do: raise("SQLite failed: #{inspect(error)}")

  defp fault(point) do
    if hook = Application.get_env(:window, :storage_fault_hook), do: hook.(point)
  end
end

alias Window.Storage.Database, as: DB
Application.ensure_all_started(:exqlite)
directory = Path.join(System.tmp_dir!(), "window-storage-smoke-#{DB.uuid()}")
File.mkdir_p!(directory)
helper = Path.expand("../native/archive/target/debug/window-archive", __DIR__)
start_archive = fn ->
  Port.open({:spawn_executable, String.to_charlist(helper)}, [:binary, {:packet, 4}, :exit_status,
    args: [String.to_charlist(Path.join(directory, "history.duckdb"))]])
end
request = fn port, value ->
  Port.command(port, Jason.encode!(value))
  receive do
    {^port, {:data, data}} -> Jason.decode!(data)
    {^port, {:exit_status, code}} -> raise "archive exited #{code}"
  after 10_000 -> raise "archive timed out"
  end
end
try do
  db = DB.open!(Path.join(directory, "current.sqlite"))
  state = DB.record!(db, "runtime", "session", "created", %{"state" => "live", "name" => "Quote ' test", "launch_cwd" => "/tmp"})
  batch = DB.batch!(db)
  port = start_archive.()
  expected_ids = Enum.map(batch, & &1["id"])
  for _ <- 1..2 do
    %{"ok" => %{"ids" => ^expected_ids}} = request.(port, %{op: "append", events: batch})
  end
  %{"ok" => %{"events" => 1}} = request.(port, %{op: "status"})
  DB.acknowledge!(db, expected_ids)
  :ok = DB.close(db)
  Port.close(port)
  Process.sleep(100)
  db = DB.open!(Path.join(directory, "current.sqlite"))
  [[payload]] = DB.query!(db, "SELECT payload FROM sessions WHERE id = ?", ["session"])
  ^state = Jason.decode!(payload)
  [] = DB.batch!(db)
  port = start_archive.()
  %{"ok" => %{"events" => [%{"payload" => ^payload}]}} = request.(port, %{op: "timeline", session_id: "session"})
  Port.close(port)
  DB.close(db)
  IO.puts("PASS: SQLite atomic state/outbox, bound parameters, DuckDB transaction, idempotent retry and restart readback")
after
  File.rm_rf!(directory)
end

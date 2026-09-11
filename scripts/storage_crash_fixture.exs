Application.ensure_all_started(:exqlite)
alias Window.Storage.Database, as: DB
[directory, point] = System.argv()
Application.put_env(:window, :storage_fault_hook, fn current ->
  if Atom.to_string(current) == point do
    IO.puts("FAULT_READY")
    Process.sleep(:infinity)
  end
end)
db = DB.open!(Path.join(directory, "current.sqlite"))
DB.record!(db, "fixture", "session", "created", %{"state" => "live", "launch_cwd" => "/tmp"})
DB.close(db)

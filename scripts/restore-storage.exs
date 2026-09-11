Application.ensure_all_started(:exqlite)
[source, destination] = System.argv()
result = Window.Storage.Restore.run!(source, destination, Application.fetch_env!(:window, :archive_helper))
IO.puts("Restored and drained: #{result}")

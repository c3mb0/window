# Isolated browser fixture; assets/check.mjs supplies a disposable data directory.
case System.get_env("WINDOW_STORAGE_PROBE") do
  "archive_outage" -> Application.put_env(:window, :archive_helper, "/nonexistent/window-archive-fixture")
  "sqlite_outage" -> File.mkdir_p!(Path.join(Application.fetch_env!(:window, :storage_directory), "current.sqlite"))
  _ -> :ok
end
{:ok, _} = Application.ensure_all_started(:window)
if System.get_env("WINDOW_STORAGE_PROBE") == "load" do
  Task.start(fn ->
    for revision <- 1..10_000 do
      Window.SessionStore.request({:record, "load-fixture", "fixture_observed",
        %{"state" => "exited", "name" => "Archive load fixture", "reason" => "measurement #{revision}"}})
      if rem(revision, 25) == 0 do
        case Window.Archive.request(%{op: "status"}) do
          {:ok, %{"events" => count}} -> IO.puts("ARCHIVE_LOAD_COMMITTED #{count}")
          _ -> :ok
        end
      end
      Process.sleep(5)
    end
  end)
end
Process.sleep(:infinity)

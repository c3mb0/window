defmodule Window.Storage.Restore do
  @moduledoc "Offline restore into a new directory; never opens the live archive."
  alias Window.{Archive, SessionStore, ArchiveDrainer}
  alias Window.Storage.{Database, Backup}

  def run!(source, destination, helper) do
    source = Path.expand(source)
    destination = Path.expand(destination)
    if File.exists?(destination), do: raise("Restore destination must not exist")
    manifest = source |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    if manifest["version"] != 1 or manifest["sqlite_schema"] != 1 or
         manifest["archive_schema"] != 1,
       do: raise("Unsupported backup manifest")

    staging = destination <> ".restoring-" <> Database.uuid()
    File.mkdir!(staging)

    try do
      for name <- ["current.sqlite", "history.duckdb"] do
        file = Path.join(source, name)
        expected = manifest["files"][name]
        actual = Backup.fingerprint(file) |> Jason.encode!() |> Jason.decode!()
        if expected != actual, do: raise("Backup checksum mismatch: #{name}")
        File.cp!(file, Path.join(staging, name))

        if Backup.fingerprint(Path.join(staging, name)) |> Jason.encode!() |> Jason.decode!() !=
             expected,
           do: raise("Restore copy mismatch")
      end

      verify_snapshot!(staging, manifest)
      recover!(staging, manifest, helper)

      Backup.write_sync!(
        Path.join(staging, "restored-from.json"),
        Jason.encode!(manifest, pretty: true)
      )

      # A destination created during validation is never overwritten.
      if File.exists?(destination), do: raise("Restore destination appeared during validation")
      File.rename!(staging, destination)
      destination
    rescue
      error ->
        File.rm_rf(staging)
        reraise error, __STACKTRACE__
    end
  end

  defp verify_snapshot!(directory, manifest) do
    {:ok, db} = Exqlite.Sqlite3.open(Path.join(directory, "current.sqlite"))

    try do
      [[1]] = Database.query!(db, "PRAGMA user_version")
      [["ok"]] = Database.query!(db, "PRAGMA quick_check")

      order =
        case Database.query!(db, "SELECT seq FROM sqlite_sequence WHERE name = 'outbox'") do
          [[seq]] -> seq
          [] -> 0
        end

      if order != manifest["commit_watermark"], do: raise("Backup watermark mismatch")
    after
      Database.close(db)
    end
  end

  defp recover!(directory, manifest, helper) do
    {:ok, store} =
      SessionStore.start_link(
        name: __MODULE__.Store,
        file: Path.join(directory, "current.sqlite"),
        runtime: Database.uuid()
      )

    try do
      {:ok, %{archive_id: identity, allow_create: false}} =
        SessionStore.request(:identity, __MODULE__.Store)

      if identity != manifest["archive_id"], do: raise("Restored archive identity mismatch")

      {:ok, archive} =
        Archive.start_link(
          name: __MODULE__.Archive,
          file: Path.join(directory, "history.duckdb"),
          helper: helper
        )

      try do
        {:ok, %{"commit_order" => order}} =
          Archive.request(%{op: "watermark"}, __MODULE__.Archive)

        if order > manifest["commit_watermark"], do: raise("Archive is ahead of paired snapshot")
        drain_all!()
        {:ok, _} = SessionStore.request(:reconcile, __MODULE__.Store)
        drain_all!()
        verify_latest!("")
        # Close and checkpoint both owners before exposing the destination.
        {:ok, _} = Archive.shutdown(__MODULE__.Archive)
      after
        GenServer.stop(archive)
      end
    after
      GenServer.stop(store)
    end
  end

  defp verify_latest!(cursor) do
    {:ok, sessions} = SessionStore.request({:list_after, cursor}, __MODULE__.Store)

    for state <- sessions do
      {:ok, %{"events" => [latest | _]}} =
        Archive.request(%{op: "timeline", session_id: state["id"]}, __MODULE__.Archive)

      if Jason.decode!(latest["payload"]) != state,
        do: raise("Restored latest state does not match archive")
    end

    if sessions != [], do: verify_latest!(List.last(sessions)["id"])
  end

  defp drain_all! do
    :ok = ArchiveDrainer.drain(__MODULE__.Store, __MODULE__.Archive)

    case SessionStore.request(:batch, __MODULE__.Store) do
      {:ok, []} -> :ok
      {:ok, [_ | _]} -> drain_all!()
      other -> raise("Restore drain failed: #{inspect(other)}")
    end
  end
end

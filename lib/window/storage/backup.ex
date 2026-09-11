defmodule Window.Storage.Backup do
  @moduledoc "Paired backups are complete only when their manifest has been written."
  alias Window.{SessionStore, Archive, ArchiveDrainer}
  alias Window.Storage.Database, as: DB

  def create(store \\ SessionStore, archive \\ Archive, drainer \\ ArchiveDrainer) do
    case ArchiveDrainer.pause(drainer) do
      :ok ->
        try do
          SessionStore.backup(archive, store)
        after
          ArchiveDrainer.resume(drainer)
        end

      error ->
        error
    end
  catch
    :exit, _ ->
      {:error,
       "Backup unavailable or timed out; check the backup directory for a completed manifest"}
  end

  # Called inside SessionStore: commits are quiesced and admitted observations wait.
  def snapshot!(state, archive) do
    root = Path.join(Path.dirname(state.file), "backups")
    File.mkdir_p!(root)
    destination = Path.join(root, "#{System.system_time(:millisecond)}-#{DB.uuid()}")
    File.mkdir!(destination)

    try do
      [[identity]] =
        DB.query!(state.db, "SELECT value FROM storage_meta WHERE key = 'archive_id'")

      bound =
        DB.query!(state.db, "SELECT value FROM storage_meta WHERE key = 'archive_bound'") == [
          ["1"]
        ]

      {:ok, _} =
        Archive.request(%{op: "identity", archive_id: identity, allow_create: !bound}, archive)

      DB.execute!(state.db, "INSERT OR REPLACE INTO storage_meta VALUES ('archive_bound', '1')")

      watermark =
        case DB.query!(state.db, "SELECT seq FROM sqlite_sequence WHERE name = 'outbox'") do
          [[seq]] -> seq
          [] -> 0
        end

      DB.execute!(state.db, "VACUUM INTO ?", [Path.join(destination, "current.sqlite")])
      {:ok, _} = Archive.snapshot(Path.join(destination, "history.duckdb"), archive)

      files =
        for name <- ["current.sqlite", "history.duckdb"],
            into: %{},
            do: {name, fingerprint(Path.join(destination, name))}

      manifest = %{
        version: 1,
        sqlite_schema: 1,
        archive_schema: 1,
        archive_id: identity,
        commit_watermark: watermark,
        created_at: System.system_time(:millisecond),
        files: files
      }

      write_sync!(Path.join(destination, "manifest.json"), Jason.encode!(manifest, pretty: true))
      %{directory: destination, manifest: manifest}
    rescue
      error ->
        # An incomplete directory never has a valid completion manifest.
        File.rm_rf(destination)
        reraise error, __STACKTRACE__
    end
  end

  def fingerprint(file) do
    # Sync copied data before publishing a manifest, hash with bounded memory.
    {:ok, io} = :file.open(String.to_charlist(file), [:read, :write, :raw, :binary])

    try do
      :ok = :file.sync(io)
    after
      :file.close(io)
    end

    digest =
      file
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    %{bytes: File.stat!(file).size, sha256: digest}
  end

  def write_sync!(file, data) do
    {:ok, io} = :file.open(String.to_charlist(file), [:write, :exclusive, :raw, :binary])

    try do
      :ok = :file.write(io, data)
      :ok = :file.sync(io)
    after
      :file.close(io)
    end
  end
end

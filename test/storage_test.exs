defmodule Window.StorageTest do
  use ExUnit.Case, async: false
  alias Window.Storage.Database, as: DB
  alias Window.{SessionStore, Archive, ArchiveDrainer}
  @store Window.TestSessionStore
  @archive Window.TestArchive

  setup do
    directory = Path.join(System.tmp_dir!(), "window-storage-test-#{DB.uuid()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    start_supervised!(
      {SessionStore,
       name: @store, file: Path.join(directory, "current.sqlite"), runtime: "runtime-one"}
    )

    start_supervised!(
      {Archive,
       name: @archive,
       file: Path.join(directory, "history.duckdb"),
       helper: Path.expand("native/archive/target/debug/window-archive")}
    )

    %{directory: directory}
  end

  defp record(id \\ "one", attrs \\ %{}) do
    SessionStore.request(
      {:record, id, "created",
       Map.merge(%{"state" => "live", "name" => "A ' quoted name", "launch_cwd" => "/tmp"}, attrs)},
      @store
    )
  end

  test "state and outbox are atomic and duplicate archive delivery is identical" do
    assert {:ok, state} = record()
    assert {:ok, [event]} = SessionStore.request(:batch, @store)
    assert Jason.decode!(event["payload"]) == state

    for _ <- 1..2,
        do:
          assert(
            {:ok, %{"ids" => [_]}} = Archive.request(%{op: "append", events: [event]}, @archive)
          )

    assert {:ok, %{"events" => 1}} = Archive.request(%{op: "status"}, @archive)
    assert :ok = ArchiveDrainer.drain(@store, @archive)
    assert {:ok, []} = SessionStore.request(:batch, @store)

    assert {:ok, %{"events" => [%{"payload" => payload}]}} =
             Archive.request(%{op: "timeline", session_id: "one"}, @archive)

    assert Jason.decode!(payload) == state
  end

  test "conflicting identity and incompatible schema roll back a whole batch" do
    {:ok, _} = record()
    {:ok, [event]} = SessionStore.request(:batch, @store)
    assert {:ok, _} = Archive.request(%{op: "append", events: [event]}, @archive)
    new = %{event | "id" => DB.uuid(), "session_id" => "two"}
    conflict = %{event | "payload" => "different content"}
    assert {:error, _} = Archive.request(%{op: "append", events: [new, conflict]}, @archive)

    assert {:error, _} =
             Archive.request(%{op: "append", events: [%{new | "schema_version" => 2}]}, @archive)

    assert {:ok, %{"events" => 1}} = Archive.request(%{op: "status"}, @archive)
    assert {:ok, [_]} = SessionStore.request(:batch, @store)
  end

  test "SQLite busy rolls back and recovers without changing current state", %{
    directory: directory
  } do
    {:ok, before} = record()
    {:ok, blocker} = Exqlite.Sqlite3.open(Path.join(directory, "current.sqlite"))
    DB.execute!(blocker, "BEGIN IMMEDIATE")

    assert {:error, _} =
             SessionStore.request({:record, "one", "detached", %{"state" => "detached"}}, @store)

    DB.execute!(blocker, "ROLLBACK")
    DB.close(blocker)
    assert {:ok, [^before]} = SessionStore.request(:list, @store)
    assert {:ok, [_]} = SessionStore.request(:batch, @store)

    assert {:ok, %{"revision" => 2}} =
             SessionStore.request({:record, "one", "detached", %{"state" => "detached"}}, @store)
  end

  test "actual SQLite full failure and outbox admission retain previously committed events" do
    {:ok, before} = record()
    db = :sys.get_state(@store).db
    [[pages]] = DB.query!(db, "PRAGMA page_count")
    DB.query!(db, "PRAGMA max_page_count=#{pages}")
    assert {:error, reason} = record("two", %{"name" => String.duplicate("x", 7000)})
    assert reason =~ "full"
    DB.query!(db, "PRAGMA max_page_count=1073741823")
    assert {:ok, [^before]} = SessionStore.request(:list, @store)
    :sys.replace_state(@store, &%{&1 | limit: 1})
    assert {:error, reason} = record("two")
    assert reason =~ "admission"
    assert {:ok, [_]} = SessionStore.request(:batch, @store)
  end

  test "archive worker restart preserves archive identity and pending batches" do
    {:ok, _} = record()
    assert :ok = ArchiveDrainer.drain(@store, @archive)
    port = :sys.get_state(@archive).port
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("/bin/kill", ["-KILL", to_string(os_pid)])
    Process.sleep(100)
    {:ok, _} = record("two")
    assert :ok = ArchiveDrainer.drain(@store, @archive)
    assert {:ok, %{"events" => 2}} = Archive.request(%{op: "status"}, @archive)
    assert {:ok, []} = SessionStore.request(:batch, @store)
  end

  test "runtime restart marks prior live rows interrupted with an event", %{directory: directory} do
    {:ok, _} = record()
    stop_supervised(SessionStore)

    start_supervised!(
      {SessionStore,
       name: @store, file: Path.join(directory, "current.sqlite"), runtime: "runtime-two"}
    )

    assert {:ok, [%{"state" => "interrupted", "revision" => 2, "runtime_id" => "runtime-two"}]} =
             SessionStore.request(:list, @store)

    assert {:ok, [_, %{"kind" => "runtime_interrupted"}]} = SessionStore.request(:batch, @store)
  end

  test "observation queue is bounded while store is suspended" do
    pid = Process.whereis(@store)
    :sys.suspend(pid)

    try do
      for _ <- 1..1024,
          do: assert(:ok = SessionStore.observe("one", "attached", %{"state" => "live"}, @store))

      assert {:error, _} = SessionStore.observe("one", "attached", %{}, @store)
      assert %{queued: 1024, rejected: 1} = Window.Storage.Admission.counts(@store)
    after
      :sys.resume(pid)
    end
  end

  test "paired backup retains pending events and restores them before reporting success", %{
    directory: directory
  } do
    {:ok, _} = record("archived")
    assert :ok = ArchiveDrainer.drain(@store, @archive)
    {:ok, _} = record("pending", %{"state" => "exited"})
    assert {:ok, %{directory: backup}} = SessionStore.backup(@archive, @store)
    assert File.exists?(Path.join(backup, "manifest.json"))
    restored = Path.join(directory, "restored")

    assert ^restored =
             Window.Storage.Restore.run!(
               backup,
               restored,
               Path.expand("native/archive/target/debug/window-archive")
             )

    db = DB.open!(Path.join(restored, "current.sqlite"))
    assert [[0]] = DB.query!(db, "SELECT count(*) FROM outbox")
    assert [["interrupted"]] = DB.query!(db, "SELECT state FROM sessions WHERE id = 'archived'")
    assert [["exited"]] = DB.query!(db, "SELECT state FROM sessions WHERE id = 'pending'")
    DB.close(db)

    assert_raise RuntimeError, ~r/must not exist/, fn ->
      Window.Storage.Restore.run!(backup, restored, "unused")
    end

    File.write!(Path.join(backup, "history.duckdb"), "corrupt")

    assert_raise RuntimeError, ~r/checksum/, fn ->
      Window.Storage.Restore.run!(backup, restored <> "-bad", "unused")
    end

    refute File.exists?(restored <> "-bad")
    # The live owners also remain usable after the snapshot.
    assert :ok = ArchiveDrainer.drain(@store, @archive)
  end

  test "a missing previously bound archive cannot silently replace history", %{
    directory: directory
  } do
    {:ok, _} = record()
    assert :ok = ArchiveDrainer.drain(@store, @archive)
    assert :ok = Archive.restart(@archive)
    Process.sleep(100)
    File.rm!(Path.join(directory, "history.duckdb"))
    File.rm(Path.join(directory, "history.duckdb.wal"))
    {:ok, _} = record("two")
    assert {:error, reason} = ArchiveDrainer.drain(@store, @archive)
    assert reason =~ "identity"
    assert {:ok, [_]} = SessionStore.request(:batch, @store)
  end
end

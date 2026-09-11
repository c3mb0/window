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
    conflict = %{event | "kind" => "different kind"}
    assert {:error, reason} = Archive.request(%{op: "append", events: [new, conflict]}, @archive)
    assert reason =~ "identity conflict"

    assert {:error, reason} =
             Archive.request(%{op: "append", events: [%{event | "digest" => "wrong"}]}, @archive)

    assert reason =~ "digest"

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

    {output, code} =
      System.cmd(Path.expand("scripts/restore-storage"), [backup, restored <> "-cli"],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "Restored and drained:"
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

  test "archive admission is bounded and drains after a blocked worker resumes" do
    pid = Process.whereis(@archive)
    :sys.suspend(pid)
    tasks = for _ <- 1..16, do: Task.async(fn -> Archive.request(%{op: "status"}, @archive) end)

    try do
      wait_queue(@archive, 16)
      assert {:error, reason} = Archive.request(%{op: "status"}, @archive)
      assert reason =~ "admission"
      assert %{queued: 16, rejected: 1} = Window.Storage.Admission.counts(@archive)
    after
      :sys.resume(pid)
    end

    for task <- tasks, do: assert({:ok, _} = Task.await(task, 15_000))
    assert %{queued: 0} = Window.Storage.Admission.counts(@archive)
  end

  test "drainer pause quiesces delivery and owner death automatically resumes it" do
    drainer =
      start_supervised!(
        {ArchiveDrainer, name: Window.TestDrainer, store: @store, archive: @archive}
      )

    parent = self()

    owner =
      spawn(fn ->
        :ok = ArchiveDrainer.pause(drainer)
        send(parent, :paused)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :paused
    {:ok, _} = record()
    Process.sleep(350)
    assert {:ok, [_]} = SessionStore.request(:batch, @store)
    send(owner, :stop)
    wait_drained(30)
    assert {:ok, %{"events" => 1}} = Archive.request(%{op: "status"}, @archive)
  end

  test "backup queues new observations after its paired watermark" do
    {:ok, _} = record("one", %{"state" => "exited"})
    parent = self()

    Application.put_env(:window, :backup_fault_hook, fn ->
      send(parent, {:backup_paused, self()})

      receive do
        :continue -> :ok
      after
        5000 -> raise("test barrier timed out")
      end
    end)

    on_exit(fn -> Application.delete_env(:window, :backup_fault_hook) end)
    task = Task.async(fn -> SessionStore.backup(@archive, @store) end)
    assert_receive {:backup_paused, store}, 2000
    assert :ok = SessionStore.observe("one", "renamed", %{"name" => "After snapshot"}, @store)
    assert %{queued: 2} = Window.Storage.Admission.counts(@store)
    send(store, :continue)
    assert {:ok, %{directory: directory, manifest: manifest}} = Task.await(task)
    assert manifest.commit_watermark == 1
    db = DB.open!(Path.join(directory, "current.sqlite"))
    assert [[1]] = DB.query!(db, "SELECT revision FROM sessions")
    assert [[1]] = DB.query!(db, "SELECT count(*) FROM outbox")
    DB.close(db)

    assert {:ok, [%{"revision" => 2, "name" => "After snapshot"}]} =
             SessionStore.request(:list, @store)
  end

  defp wait_queue(server, count, attempts \\ 50)
  defp wait_queue(_, _, 0), do: flunk("queue did not reach expected occupancy")

  defp wait_queue(server, count, attempts) do
    if Window.Storage.Admission.counts(server).queued != count do
      Process.sleep(10)
      wait_queue(server, count, attempts - 1)
    end
  end

  defp wait_drained(0), do: flunk("drainer did not resume")

  defp wait_drained(attempts) do
    case SessionStore.request(:batch, @store) do
      {:ok, []} ->
        :ok

      _ ->
        Process.sleep(50)
        wait_drained(attempts - 1)
    end
  end
end

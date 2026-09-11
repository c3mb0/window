# Storage operations and schema

Schema version 1 is the only implemented version. SQLite stores `PRAGMA
user_version=1`; DuckDB stores `archive_meta.version=1`. Opening a future version
fails visibly. Version-zero SQLite files receive an atomic initial migration;
there is no destructive downgrade or automatic rewriting of archived payloads.

`lib/window/storage/database.ex` owns the SQLite schema. `native/archive/src/main.rs`
owns the DuckDB schema and its fixed operation set. Session and event IDs are UUIDs;
revisions order events within a session. The outbox's AUTOINCREMENT commit order
is local to this database lineage. Wall-clock timestamps are for display only.
The exact UTF-8 JSON payload is SHA-256 hashed; DuckDB checks that digest before
append and compares every field on duplicate delivery. History rows cannot be
updated/deleted through the worker API. This is not tamper-proof storage.

Lifecycle payloads carry resulting metadata and observation reason. A rename is
a new full-state event. Close requested, grace expired, owner stopped, and observed
child exit are distinct observations. Owner disappearance does not prove cleanup.
No PID or persisted row is reattachment authority; the live runtime registry and
session process decide whether the shelf can focus a terminal.

The SQLite owner admits at most 1,024 queued operations/observations. Observations
are nonblocking casts; synchronous rename/metadata requests return errors when
admission or a commit fails. SQLite waits at most 250 ms for a busy writer. The
outbox cap counts UTF-8 payload bytes plus a 256-byte per-event estimate, not exact
on-disk allocation. WAL/main-file sizes are shown separately.

The archive owner admits 16 operations, handles one at a time, and kills an
unresponsive Port after 10 seconds. Requests are at most 4 MiB. Batches and timeline
results are at most 250 events; each metadata payload is at most 8 KiB. DuckDB uses
two threads and a 256 MiB memory limit with external access disabled. The drainer
retries between 250 ms and 10 seconds, retaining committed outbox records on errors.
There is no in-memory event copy queue in the drainer. The shelf lists the most
recent 250 sessions and 250 events for a selected session; older history remains
in the archive. Use a backup for independent analysis, never a second writer on
the live DuckDB file.

Storage availability is independent of terminal input/close. Counters cover the
current storage process lifetime and cannot reconstruct observations lost before
commit or across a process crash. Last observed state is explicitly not a liveness
claim. If storage restarts with the same server runtime, live Registry checks still
control focus; full application restart reconciles old live-looking metadata.

## Backup consistency

The drainer pauses and finishes its current batch before backup begins. The
SQLite owner then serializes the whole paired copy while incoming observations
remain behind it in its bounded queue. `VACUUM INTO` creates a consistent SQLite
backup including committed WAL content; this is SQLite's documented backup
alternative, not a raw copy of a live main file. DuckDB checkpoints, closes its
connection, and exits before its file is copied. Both copied files are synced and
hashed before the completion manifest is written and synced. The manifest records
schema versions, shared archive ID, SQLite commit watermark, hashes and sizes.
A crash during a copy may leave an incomplete directory; restore rejects missing
or mismatched files. Filesystem/hardware durability still governs power-loss behavior.

Source: https://www.sqlite.org/lang_vacuum.html#vacuum_with_an_into_clause

Restore stages into a new sibling directory, checks the pair, drains the outbox,
reconciles interrupted state, drains again, and compares every latest session row
with the latest archive event using bounded pages. Only then is the destination
published. Existing destinations are rejected. Retained backup history is unchanged;
reconciliation creates new events in the restored working copy.

## Repeatable gates

- `make check`: native build/fmt/clippy, Elixir fmt/compile/tests, TypeScript/assets.
- `make storage-crash-check`: actual SIGKILL at four commit boundaries in disposable data.
- `make storage-browser-check`: Chromium/Firefox shelf plus archive/SQLite outage checks.
- `WINDOW_OPEN_BROWSER=0 WINDOW_REFRESH_ONLY=1 node assets/check.mjs`, with and
  without `WINDOW_BROWSER=firefox`: existing real-PTY refresh contract with storage.
- `WINDOW_OPEN_BROWSER=0 WINDOW_ECHO_ONLY=1 WINDOW_STORAGE=0 node assets/check.mjs`
  and `WINDOW_OPEN_BROWSER=0 WINDOW_ECHO_ONLY=1 WINDOW_STORAGE_PROBE=load node assets/check.mjs`:
  isolated baseline/load measurements, 5 warmups plus 40 samples, Enter dispatch to
  real PTY output received on the browser WebSocket. Rendering is awaited separately.
  Run these sequentially without other build workloads. JSON results are in ignored
  `test-results/`; record the measurements in the acceptance receipt.

All fixture data lives in temporary directories. The browser fixture uses a
controlled shell configuration with shell history disabled. Failure tests never
fill the user's disk or restart an existing user terminal.

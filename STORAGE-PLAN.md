# SQLite current state + DuckDB append-only history

Status: implemented and automatically verified. Grounded in window at `c9f6cd6`.
See `STORAGE-IMPLEMENTATION.md` for gate evidence and manual acceptance limits.

## Outcome and first slice

SQLite keeps the latest recorded state of each entity. DuckDB keeps immutable
events explaining how it got there. A transactional SQLite outbox bridges the
two stores; committed history moves out of SQLite after DuckDB acknowledges it.

Start with a session shelf and lifecycle receipts: names, initial project/cwd,
creation, attachment, detachment, reattachment, observed exit, close request,
and refresh-grace expiry. Existing PTY ownership, browser Web Locks, screen
snapshots, and refresh behavior continue to serve the running terminal.

The first slice does not record keystrokes, terminal output, environment variables,
startup capabilities, or conversation content. A cwd is the known launch cwd or
an explicitly supplied project path, not a claim to observe shell `cd` commands.
Command/build receipts and user-supplied resume recipes can follow separately.

## Data contract

| Store | Table | Purpose |
|---|---|---|
| SQLite | `sessions` | Latest state per session: UUID, runtime UUID, name, launch cwd, revision, last event ID, observed state and timestamps |
| SQLite | `outbox` | Pending immutable events: UUID, local commit order, session UUID/revision, kind, schema version, observed time, exact payload and digest |
| SQLite | `storage_meta` | Schema version, archive identity and delivery progress |
| DuckDB | `session_events` | Same immutable event records, unique event UUID and session/revision pair |

Runtime PIDs, OS PIDs, and browser ownership keys are not durable identity or
reattachment authority. Persisted state means **last observed**, not necessarily
currently alive. Wall-clock timestamps support display; revisions and commit
order support ordering. No claim of universal ordering across runtime instances.

Corrections append a new event referencing the old event. Reusing an event ID
with different content is an integrity failure, not a successful retry. Historical
payloads retain their original schema version; readers adapt old versions.
Each lifecycle payload includes the resulting metadata state and its observation
reason, so replay can reconstruct the latest row without guessing missing fields.

## Commit and archive protocol

1. One SQLite transaction advances the session revision, updates its latest row,
   and inserts the corresponding outbox event. No durable state-only updates.
2. A supervised drainer reads a bounded batch in commit order. Initial tuning:
   at most 250 events per batch, with a 250 ms flush interval when work exists.
3. One DuckDB transaction inserts the batch. Existing IDs must have identical
   content; identical retries are skipped, conflicting content stops delivery.
4. Only after the DuckDB commit succeeds does a SQLite transaction acknowledge
   and remove those exact outbox IDs. Never delete by an unverified timestamp.
5. After any uncertain response, retry the same IDs. This is at-least-once delivery
   with idempotent archival, not an atomic transaction across both databases.

Use SQLite WAL with `synchronous=FULL`, foreign keys, a bounded busy timeout,
and explicit transactions. Put both databases in a local application data
directory selected by `WINDOW_DATA_DIR`; keep it outside Git and browser assets.

DuckDB is logically append-only through the application's writer interface.
Its database engine still supports mutation: this is not a tamper-proof archive.

## Runtime integration

- `Window.SessionStore` owns serialized SQLite writes and current-state reads.
- `Window.ArchiveDrainer` supervises retries and batch acknowledgments.
- One application-owned process owns the writable DuckDB file. Queries use
  that owner with bounded results/timeouts; another CLI process does not open
  the live writable file. Export snapshots for independent analysis.
- Hook semantic transitions in `Window.TerminalSession`, not every PTY chunk,
  credit, heartbeat, or keypress. Keep the terminal data path free of database I/O.
- Preserve the window/play repository boundary. Storage belongs to window;
  no changes to play's PTY protocol or teardown policy are planned.

First implementation gate: prove a maintained, pinned SQLite Elixir binding and
DuckDB integration on the existing macOS arm64 toolchain. Prefer an isolated
Rust Port worker for DuckDB so analytical work and native faults stay outside
BEAM schedulers. Verify parameter binding, transactions, native packaging and
shutdown before choosing the final dependency pins. Reuse framing conventions
where useful without treating the PTY helper as the database service.

Process actions and database commits are not one transaction. Distinguish
`close_requested`, observed child exit, and session-owner disappearance. Do not
invent successful cleanup because a row was updated. On application restart,
append reconciliation events marking prior-runtime live-looking rows as
`interrupted`/`unknown`; never resurrect a PID from SQLite or infer an exit code.

## Failure behavior

| Failure point | Required recovery |
|---|---|
| Before SQLite commit | Neither latest-state update nor outbox event commits |
| After SQLite commit, before DuckDB commit | Pending outbox survives and is retried |
| After DuckDB commit, before outbox acknowledgment | Retry creates no duplicate history |
| Conflicting event ID or incompatible schema | Stop the batch, retain pending events, show the fault |
| DuckDB unavailable | Keep committed events in SQLite; show archive lag and retry with capped backoff |
| SQLite unavailable | Report persistence unavailable; preserve terminal input and cleanup paths; do not claim unrecorded observations are durable |
| Application restart | Drain pending events and reconcile last-observed session state against the new runtime |

Bound the drainer's in-memory queue. Track outbox rows, bytes, oldest-event age,
last successful archive commit, and last error. Start with a configurable 64 MiB
outbox admission limit; reject additional metadata operations that require durable
success when that limit is reached. Terminal close and cleanup must always remain
available. Never discard an already committed event to relieve backlog. Observations
lost before a SQLite commit cannot be reconstructed exactly; report that limitation.

History grows by design. Show file sizes and free disk space; no silent pruning.
A future explicit archive/delete policy must acknowledge that physical append-only
history and deletion requirements are different policies.

## Delivery sequence and gates

1. **Storage smoke test:** disposable directory, pinned bindings, one current row,
   one event, restart and readback. Stop and report if native integration cannot
   satisfy the transaction/process-ownership contract.
2. **Commit bridge:** schemas, migrations, SQLite transaction, DuckDB drainer,
   duplicate checks and fault injection. No UI until recovery gates pass.
3. **Lifecycle wiring:** record real session transitions and reconcile a crashed
   runtime. Retain existing refresh/close semantics and pass `make check` plus
   Chromium/Firefox refresh checks.
4. **Inspectable shelf:** list current/last-observed sessions, inspect one timeline,
   and show persistence/archive status. Clicking an entry focuses a live session
   only when runtime ownership confirms it. No automatic command execution.
5. **Recovery and handoff:** backup/restore procedure, usage and schema docs,
   clean commits, and a reviewable acceptance receipt before expanding scope.

Acceptance requires process-kill tests at each commit boundary, repeated delivery
of the same batch, conflicting-payload rejection, database-busy/full failures,
archive-worker restart, and an unavailable archive while terminal input and close
remain usable. Verify bounded queues and backlog admission. Measure terminal echo
latency before/after under archive load and report the results; do not substitute
successful database writes for evidence of terminal responsiveness.

Backup uses SQLite's backup facility, not a copy of a live main file that omits
its WAL. Quiesce metadata commits and the drainer at one recorded watermark while
making a paired backup and checkpoint/copying the closed DuckDB archive. Terminal
I/O continues; incoming observations use a bounded queue with explicit failure
reporting if it fills. On restore, drain retained outbox
events idempotently before presenting archive status as current. Test this path.

Success receipt: latest SQLite row equals the latest committed session event;
pending events explain any archive lag; after a complete drain each committed
event appears exactly once in DuckDB; restart does not label a dead session live.
Separate offline tests, browser runtime checks and user acceptance.

## Source constraints checked while planning

- SQLite single-file atomic commit: https://www.sqlite.org/atomiccommit.html
- SQLite WAL durability settings: https://www.sqlite.org/wal.html
- DuckDB process/concurrency model: https://duckdb.org/docs/stable/connect/concurrency.html
- DuckDB transactions: https://duckdb.org/docs/current/sql/statements/transactions

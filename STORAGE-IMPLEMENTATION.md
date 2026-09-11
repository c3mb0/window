# Storage implementation receipt

Status: implemented and automatically verified on macOS arm64, September 11,
2026. User acceptance and other-platform validation remain separate. Baseline:
`c9f6cd6`; first storage milestone: `ed4e508`.

## Delivered

- SQLite schema 1: latest session row and matching immutable outbox event in one
  WAL/FULL transaction, UUIDs, revision/previous-event linkage, full resulting state,
  SHA-256 digest and local commit order. No terminal content is captured.
- Isolated DuckDB 1.5.5 Port owner with pinned Rust dependencies, fixed operations,
  byte/queue/batch/time limits, digest and duplicate-content checks, archive identity,
  transactional append, exact-ID acknowledgment and capped retry backoff.
- Semantic PTY lifecycle observations and restart reconciliation. Runtime ownership
  controls live focus; stored state is last observed and never recreates a process.
- Session shelf: names, launch cwd, bounded timeline, pending-event distinction,
  live focus, durable rename, storage errors/backlog/disk/counter visibility.
- Paired backup with a quiesced commit watermark, SQLite `VACUUM INTO`, closed and
  checkpointed DuckDB copy, file sync/hashes and final manifest. Bounded observations
  wait behind the snapshot. Restore rejects existing destinations or bad pairs,
  drains retained events, reconciles state, and validates every latest row against
  history before publishing a fresh data directory.

## Acceptance evidence

| Contract | Executed evidence | Result |
|---|---|---|
| Native integration | `scripts/storage_smoke.exs`; bound quoted parameters, duplicate append, close/reopen and exact readback | Pass |
| SQLite atomicity | Real SIGKILL before and after SQLite commit | Before: neither row nor event; after: both survive |
| Archive recovery | Real SIGKILL before DuckDB commit and after commit before SQLite acknowledgment | Rollback before commit; one event after identical retry |
| Integrity failures | Conflicting identity, invalid digest, unsupported event version; batch rollback | Error, prior archive and pending events retained |
| Capacity/fault isolation | Actual SQLite busy and full failures, outbox admission cap, 1,024 store slots and 16 archive slots | Bounded, committed history retained; recovery succeeds |
| Worker/runtime restart | Kill/reopen archive, reject missing previously bound archive, reconcile prior live-looking state | Pass |
| Paired backup | Pause at SQLite snapshot; enqueue a later observation | Snapshot revision 1/watermark 1; live store later reaches revision 2 |
| Restore | Pending events, interrupted-state reconciliation, exact latest-row equality, corrupt-file rejection, existing-destination rejection and real shell CLI | Pass |
| Drainer pause | Pause delivery, terminate pause owner, resume automatically | Pass |
| Existing behavior | `make check`: native build/fmt/clippy, warnings-as-errors, all 19 Elixir tests, TypeScript/assets | Pass |
| Shelf | Chromium and Firefox real-shell tests: timeline, rename, focus, refresh, backup, closed-focus rejection | Pass |
| Storage outages | Unavailable archive and unavailable SQLite with visible status, real shell input and close | Pass |
| Refresh | Chromium and Firefox repeated reloads, identical PTYs/variables/cwd, foreground job, alternate screen, streaming output, Web Lock competition | Pass |
| Host shutdown | Direct-PID and group SIGINT, tracked processes absent | 19/15 processes absent in 0.107/0.114 s |

Chromium's broader terminal/job-control suite also passed with storage enabled.
Shelf screenshots were inspected locally under ignored `test-results/`; browser
fixtures and storage/crash tests use disposable data and controlled shell history.
The user's existing server and sessions were not restarted for these checks.

## Echo measurement

Sequential Chromium runs, 5 warmups then 40 samples each, measured Enter dispatch
through real PTY output received on the browser WebSocket. Rendering was awaited
separately. The load run confirmed **239 archived events** from its concurrent
metadata fixture. No build workloads ran during this recorded pair.

| Mode | Median | p95 | Maximum |
|---|---:|---:|---:|
| Storage disabled | 18.17 ms | 23.90 ms | 26.00 ms |
| Continuous metadata/archive load | 15.20 ms | 23.94 ms | 25.67 ms |

These short local samples show no observed p95 regression at this load; they do
not establish that storage improves latency or predict other machines/heavy
analytical workloads. Reproduction commands are in `STORAGE-OPERATIONS.md`.

## Practical limits

- The shelf displays the latest 250 sessions/events; older archive history remains.
- Uncommitted observations lost through failure cannot be reconstructed. Admission
  and failure counters cover the current storage-process lifetime only.
- This is metadata persistence, not PTY resurrection or Codex transcript storage.
  Existing refresh continuity still uses its original 30-second in-memory handoff.
- Archive history is append-only through this writer, not tamper-proof against
  external database edits. There is no automatic pruning.
- Backup needs free disk space. A timeout is unconfirmed; incomplete or corrupted
  pairs are rejected. Filesystem/hardware behavior governs power-loss durability.
- Native integration is validated on this macOS arm64 toolchain. The smaller
  official prebuilt DuckDB library replaced a bundled debug build that exhausted
  local disk during the initial probe; only this task's build outputs were cleaned.
- User hands-on acceptance, native clipboard/IME/Safari and other platforms remain
  the existing manual boundaries documented in `VERIFICATION.md`.

Storage operations, schema behavior, configuration, and repeatable checks:
`STORAGE-OPERATIONS.md`. Full requested scope: `STORAGE-PLAN.md`.

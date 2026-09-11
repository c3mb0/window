# Dependencies and repository boundary

Backend: https://github.com/c3mb0/play.git, complete Git submodule at `vendor/play`.
Current pin: **34e906212c3f2914f151cc8edda1f2a993bf0f6d**.
Initial planning pin: a04bbb62f21290e8372ec788991c1926b924e0c0.

The adopted revision adds an owner-bound, unrecorded interactive session API,
resize/readback, output credits, early child-exit notification, and bounded
shell/foreground-group hangup. Existing lab recording/deadlines remain separate.
Shared changes were developed, checked, committed and pushed in play before this
pin update. Its original tests and receipts remain in that repository.

Mix uses `vendor/play/erlang/pty_lab` with rebar3. The launcher builds the external
helper from that checkout with Cargo.lock. No backend source is copied into window,
no company checkout is required. A window-owned GenServer owns each PTY worker
and grants input to one attached Phoenix channel at a time, allowing a bounded
refresh handoff without changing play's owner-bound API. Mix and npm
lockfiles pin Phoenix, its transport dependencies, xterm.js and asset tooling.

`phoenix_template` temporarily overrides Hex 1.0.4 with upstream commit
`a5dd67cee1190bca4b7662ec3553373b5d67a0e6`, which fixes the Elixir 1.20
bitstring-size pin warning in `unsuffix/2` (upstream PR #11). Return to a Hex
release containing that fix when available. No dependency source is patched locally.

window owns Phoenix, TypeScript/CSS, tab lifecycle, refresh snapshots and grace periods, local capability/origin policy,
and the Signal theme adapter. play owns Erlang sessions and Rust Unix mechanisms.
Future shared changes belong in play, followed by an explicit gitlink update here.

`assets/src/theme.json` is the sole local palette snapshot. Its role values were
checked against Signal's `signal.go`, `gruvbox.go` and `roles.go` at
b8efbdf9c00cccc68b93884b7b942a64ebd369ee. Reuse is explicitly authorized by the owner.
The ANSI mapping in `app.ts` is window's adapter: bright colors alias their base
roles except brightBlack=dim; bold is independent of bright. 256-color/truecolor
sequences remain application supplied. Signal is neither a build nor runtime
dependency. No Signal source or shell configuration was modified.

The current pin corrects interactive teardown to kill every discovered process
group in the owned PTY session, including background jobs, without a HUP grace.
This does not contain processes that deliberately daemonize into another session.

## Window-owned metadata storage

SQLite uses `exqlite == 0.40.0`, pinned with its native-build/runtime dependencies
in `mix.lock`. DuckDB runs in `native/archive` as an isolated Rust Port process:
`duckdb = 1.10505.0` maps to upstream DuckDB **1.5.5**, with the full Rust dependency
graph in `native/archive/Cargo.lock`. It is not part of play.

`scripts/build-archive` sets `DUCKDB_DOWNLOAD_LIB=1` and uses the binding's download
support for the matching upstream native library. The macOS arm64 build downloads
`libduckdb-osx-universal.zip` from the DuckDB v1.5.5 release; the loader searches
beside the executable and its `deps` directory. Keep the executable and downloaded
library together. First build needs network access; subsequent locked builds use
the local cache. No system DuckDB installation is required.

The official prebuilt library avoids a multi-gigabyte local C++ debug build.
`build.rs` supplies loader-relative paths for macOS and Linux. The current runtime
and tests use the debug profile; portability outside the tested macOS arm64 host
is not claimed. Sources: https://github.com/duckdb/duckdb-rs and
https://github.com/duckdb/duckdb/releases/tag/v1.5.5.

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

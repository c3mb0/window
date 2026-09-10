# Dependencies and repository boundary

Backend: https://github.com/c3mb0/play.git, complete Git submodule at `vendor/play`.
Current pin: **3963c301a31147c68acbc316c3f387d2b6fd90ea**.
Initial planning pin: a04bbb62f21290e8372ec788991c1926b924e0c0.

The adopted revision adds an owner-bound, unrecorded interactive session API,
resize/readback, output credits, early child-exit notification, and bounded
shell/foreground-group hangup. Existing lab recording/deadlines remain separate.
Shared changes were developed, checked, committed and pushed in play before this
pin update. Its original tests and receipts remain in that repository.

Mix uses `vendor/play/erlang/pty_lab` with rebar3. The launcher builds the external
helper from that checkout with Cargo.lock. No backend source is copied into window,
no company checkout is required, and there is no second PTY owner. Mix and npm
lockfiles pin Phoenix, its transport dependencies, xterm.js and asset tooling.

window owns Phoenix, TypeScript/CSS, tab lifecycle, local capability/origin policy,
and the Signal theme adapter. play owns Erlang sessions and Rust Unix mechanisms.
Future shared changes belong in play, followed by an explicit gitlink update here.

`assets/src/theme.json` is the sole local palette snapshot. Its role values were
checked against Signal's `signal.go`, `gruvbox.go` and `roles.go` at
b8efbdf9c00cccc68b93884b7b942a64ebd369ee. Reuse is explicitly authorized by the owner.
The ANSI mapping in `app.ts` is window's adapter: bright colors alias their base
roles except brightBlack=dim; bold is independent of bright. 256-color/truecolor
sequences remain application supplied. Signal is neither a build nor runtime
dependency. No Signal source or shell configuration was modified.

# Backend dependency declaration

Repository: git@github.com:c3mb0/play.git
HTTPS equivalent: https://github.com/c3mb0/play.git
Initial revision: **a04bbb62f21290e8372ec788991c1926b924e0c0**
Local development checkout: /Users/cem/play/pty-lab

This is a declared source pin, not an installed dependency or working build.
There is currently no submodule, Mix dependency, copied backend or generated binary.
The revision was read from the clean play checkout during window setup.

## Next-session wiring

Use a Git submodule at vendor/play pinned to the revision above. It is a complete
upstream repository reference, not selectively copied source. Configure the
Phoenix application's local rebar dependency to vendor/play/erlang/pty_lab, with
manager rebar3. Build the Rust helper from that same checkout and Cargo.lock;
record/resolve its location rather than assuming a prebuilt binary exists.

The resulting .gitmodules and Git submodule entry are the actual dependency pin;
update this document alongside them. A normal build must not depend on the
operator's separate /Users/cem/play checkout. Do not add node-pty or a competing
Rust PTY owner alongside the existing helper.

## Shared changes

The pinned lab version is not yet a complete personal-terminal backend. It still
needs the interactive lifetime/recording policy support, live resize and suitable
flow control described in TERMINAL-UI-HANDOFF.md. Do not claim those capabilities
are implemented just because a dependency has been declared.

Develop shared changes in play, retain its tests and evidence, commit/publish the
change, then move window's submodule pin deliberately. Keep personal UI/session
policy in window; common mechanism and API semantics stay in play. Preserve each
repository's existing uncommitted work if the next session encounters any.

Signal palette source: /Users/cem/ins_repo/signal. Its role values will be copied
into a small local theme snapshot under the user's explicit authorization.
Signal is not a runtime or Git-submodule dependency of window.

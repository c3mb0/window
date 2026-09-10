# window

A personal web terminal. Tabs, **+** to open one, **×** to close it. The terminal
fills the rest. Signal colors. No extra application controls.

**Status: repository and plan only. No runnable application yet.**

The selected direction is Phoenix + xterm.js, backed by play's Erlang sessions
and external Rust PTY helper. window owns the personal application; play owns the
shared process machinery. No backend source is copied here.

Start the implementation session with [the terminal handoff](TERMINAL-UI-HANDOFF.md)
and [the backend dependency declaration](DEPENDENCIES.md). No UI or backend
implementation was started during repository setup.

## Repository boundary

| window | play |
| --- | --- |
| Phoenix application and browser assets | Rust PTY helper and framed protocol |
| Tab lifecycle and personal-session policy | Erlang session API and ownership mechanisms |
| Signal theme snapshot and terminal rendering | Reproducible experiments and original receipts |

Shared resize, flow-control or lifecycle mechanisms should be implemented and
checked in play, then adopted by an explicit pin update here. No third framework
repository and no second PTY implementation.

[MIT licensed](LICENSE).

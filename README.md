# window

A personal local web terminal: tabs, **+** to open, **×** to close. Phoenix and
xterm.js, with Signal colors and play's Erlang/Rust controlling PTY backend.

```sh
make terminal
```

Requires Git, Erlang/OTP 29+, Elixir 1.17+, rebar3, Rust 1.95 and Node/npm.
The launcher initializes the pinned submodule, builds the helper and local assets,
and opens a capability-bearing URL in Google Chrome on macOS (an installed
Chrome/Chromium executable on Linux). It also prints that exact URL for manual
opening. Set `WINDOW_OPEN_BROWSER=0` to skip opening the browser. The launcher
does not install a browser; `make browser-check` installs a separate Playwright
Chromium for tests. The service listens on
**127.0.0.1:4050**; set `WINDOW_PORT` to change the port. Stop with Ctrl-C (twice if
the BEAM break menu appears). First build needs network access for dependencies.

Each tab launches `$SHELL -il` in your home directory with the inherited environment
and `TERM=xterm-256color`. macOS falls back to `/bin/zsh`. Your shell startup files
and their own history policy still apply. window creates no transcript files;
scrollback is limited to 5,000 lines per tab. Refresh snapshots temporarily store
that screen content in tab-scoped browser session storage. Assets and fonts stay local (system
monospace text with a bundled Nerd Fonts Symbols Mono fallback for prompt icons).

Switching tabs retains each screen and shell. An exited shell keeps its screen.
Closing the last tab leaves **+**. Ctrl-C always goes to the terminal, including
when text is selected. Copy/paste use Cmd-C/V on macOS and Ctrl-Shift-C/V on Linux.
Ctrl-Shift-V reads the browser clipboard and uses xterm paste; Cmd-V uses native
paste. Both preserve bracketed paste when enabled by the application. Clipboard
permission failures appear in the tab label. Option acts as Meta. Links remain text and are not opened automatically.
Shift-Enter sends the distinct CSI-u key sequence for a newline in Codex's
composer; plain Enter keeps its normal submit behavior.

Browser heartbeats run every 10 seconds; the server permits 120 seconds of
silence so idle shells do not race the heartbeat timer. Transport loss disables
input and automatic reconnect. **Refresh reattaches the same PTYs**, retaining
shell variables, working directories, foreground jobs, screens, tabs, and the
active tab. A Web Lock gives the page exclusive browser ownership; session storage
carries its reconnect IDs and xterm screen snapshots. Reload within **30 seconds**
of server-side disconnect. The server keeps at most 256 KiB of recent output per
terminal for replay and applies the existing 64 KiB output backpressure while
disconnected. Unacknowledged input is never replayed.

The terminal **×** closes its PTY immediately. Closing/navigating away from the
browser page lets the 30-second grace expire; browsers cannot reliably distinguish
that departure from refresh. A dead connection may first need the WebSocket
timeout to be detected. This is refresh continuity, not persistence through server
restarts, browser crashes, or expired sessions. Missing/expired server sessions
show an error rather than silently substituting a new shell. Storage must be
available with enough quota for the snapshot, and Web Locks must be supported.

After opening the launcher URL once, the capability is retained in tab-scoped
session storage. It is removed from the URL and changes when the server restarts.
Open the new launcher URL after a server restart or in a new browser tab.
If browser storage is unavailable, the URL fragment is retained, but refresh
continuity is unavailable. A first reload from an older version of window still
loses its old sessions: this behavior applies to sessions created by the new version.

Closing sends terminal hangup to the owned shell group and current foreground
job group, closes the PTY, then escalates those groups after 150 ms. This is **not
arbitrary descendant containment**: background/escaped jobs are outside that
cleanup scope. Close events report the cleanup request, not proof that every
process has disappeared.

## Checks

```sh
make check                 # compile, ExUnit (includes 61-second lifetime), assets
make browser-check         # installs Chromium, runs real-shell browser checks
```

Run backend checks in `vendor/play` with `make interactive-check`, `make lint`,
`make protocol-check`, `make ownership-check`, and `make receipt-check` (Cargo must
be on PATH). See [verification and remaining manual checks](VERIFICATION.md).

[Backend pin and repository boundary](DEPENDENCIES.md) ·
[Original implementation scope](TERMINAL-UI-HANDOFF.md) · [MIT license](LICENSE)

## Operator stop

One Ctrl-C/SIGINT on the running launcher now terminates BEAM without opening
its break menu (`scripts/runtime`, `+Bd`). Closing its helper pipes tears down
all discovered process groups in each owned PTY session, including background
jobs ignoring HUP/TERM. Teardown uses SIGKILL, so those jobs do not get a chance
to save work. Ctrl-C *inside a browser terminal* still belongs to that terminal's
foreground program; it is not the host application's kill switch.

`make shutdown-check` runs a real VM with foreground/background PTY jobs and
asserts that its tracked process tree disappears after direct and group SIGINT.
Observed local cleanup was approximately0.1seconds; the regression ceiling is
2seconds. This is not literal zero-time termination, remote-service cancellation,
or containment of a program deliberately escaping into another daemon session.
The browser itself is not owned by this launcher and is not killed.

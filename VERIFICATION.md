# Terminal verification

Implementation is runnable and checked on macOS arm64. This is a first local
version; product acceptance by the user remains separate from automated checks.

## Passed

- Rust build, clippy and unit checks; OTP EUnit (7) and xref.
- Existing play protocol, ownership and receipt-recovery gates, with new immutable
  receipts at `receipts/{protocol-20260910T220131Z,ownership-20260910T220229Z,receipt-20260910T220232Z}`.
- `tests/interactive_check.py`: native initial size, live resize/readback, foreground
  SIGWINCH, 64 KiB pause/resume credit window, exact 200,008 output bytes, and
  independent absence check for a controlled foreground job after close.
- window ExUnit: startup token rejection/acceptance, real PTY channel, resize,
  input sequence rejection, excess-credit rejection, close, survival for 61 seconds,
  owner-loss grace/cleanup, visible worker failure, same-worker refresh handoff,
  idempotent replay credits, invalid-snapshot rejection, and expiry without replacement.
- TypeScript checking and bundled local assets. npm audit reports zero findings
  for the installed lockfile at this checkpoint.
- Chromium real-shell interaction: independent tabs, preserved screens, inactive
  close, final-tab empty state, exited screen retained, hidden high output while
  another shell responds, split UTF-8 and ANSI with wide characters, resize,
  Ctrl-Z/fg/Ctrl-C and Ctrl-D, Backspace/history, paste-event handling, less alternate
  screen across resize, and disconnect with no rejoin or new shell. Screenshot inspected.

Browser checks use a disposable zsh configuration and no shell history. An earlier
run also exercised the actual user login shell. No application transcript files
are created. Existing shell-owned history is outside window's recording policy.

## Limits and manual checks

- Native macOS IME composition, Cmd-C/V clipboard integration, Option combinations,
  selection persistence while scrolling/output arrives, and full Safari/Firefox
  behavior need hands-on acceptance. Standard xterm handlers are wired; these are
  not claimed as independently validated.
- Cleanup covers the shell group and sampled foreground group. Background and
  escaped descendants are not contained; cleanup event state is unverified.
- A child may exit before its output holders. The tab reports exit immediately;
  output drains under credits until EOF or explicit close. Refresh handoff is bounded
  to 30 seconds; there is no persistence through a server restart.
- The browser has bounded queued input (64 KiB), a 64 KiB output-credit window and
  bounded scrollback per tab. Oversized queued paste disconnects visibly instead
  of silently losing part of the input. Resize and close bypass data credit.
- Each tab uses its own WebSocket so a busy tab's transport queue does not block
  another. The server rejects frames over 32 KiB. No hostile-client stress claim.
- Dependency `phoenix_template` emits an Elixir-1.20 bitstring deprecation warning
  during its own compilation; window compiles with warnings-as-errors.

## Bottom-row layout regression

`node assets/layout-check.mjs` checks a running local server (`WINDOW_URL` override,
4050 default) without a capability or shell. Install its browsers with
`npx --prefix assets playwright install chromium firefox` first. Firefox and
Chromium pass at six viewport sizes: the final row, screen and scroll viewport
remain inside the fitted panel with at least 8 px below it. Panel spacing uses
positioning insets because FitAddon does not subtract parent padding.

## Refresh continuity

`WINDOW_OPEN_BROWSER=0 WINDOW_REFRESH_ONLY=1 node assets/check.mjs` (also with
`WINDOW_BROWSER=firefox`) checks repeated reloads of two PTYs. Shell PID variables,
working directory, shell variables, retained screens, active-tab selection, a
foreground sleep job, and an alternate-screen read survive the handoff. Streaming
numbered output across reload checks for missing or duplicate rendered lines.
A competing page seeded with the same page ownership ID is rejected by Web Locks.

The window session process owns the unchanged play worker. Output carries a
monotonic sequence, with 256 KiB of recent raw output retained in server memory.
Rendered sequence acknowledgments replenish the original 64 KiB credit window;
repeated acknowledgments after replay do not replenish it twice. Input acknowledgments
remain connection-local and no unacknowledged input is replayed.

ExUnit checks reconnect to the identical worker, credit idempotence, non-owner
command rejection, invalid snapshot rejection, and expiration that closes the
worker rather than creating a replacement. The expiry test uses a short configured
grace; the production default is 30 seconds after detected channel loss. Explicit
terminal close ends the session immediately.

Screen snapshots use xterm's serialize addon and browser sessionStorage. They
include scrollback, modes, and the alternate screen, but are not a durable PTY
checkpoint or a byte-level snapshot of xterm's incomplete escape/UTF-8 parser state.
Reload at an incomplete control-sequence boundary remains a limitation. Storage
quota exhaustion, browser crashes without pagehide, and full Safari behavior are
not claimed as supported refresh cases. Existing sessions created by the old
channel-owned implementation cannot be migrated in place.

The broader historical Firefox test reached terminal/job-control checks, but its
synthetic clipboard event did not deliver paste; that is not recorded as a native
Firefox clipboard pass.

## Idle browser connection regression

The earlier 61-second test exercised the OTP worker, not a browser WebSocket.
The original server inactivity limit and client heartbeat interval were both
30 seconds, leaving no scheduling/round-trip margin. They are now 120 seconds
and 10 seconds respectively.

`WINDOW_BROWSER=firefox WINDOW_IDLE_ONLY=1 node assets/check.mjs` leaves two real
shells idle for 125 seconds (one terminal hidden), watches for even transient
failure labels, then checks each shell's distinct environment sentinel through
new terminal input. This tests continued ownership, not replacement shells.

A separate Firefox probe against the original running server reproduced the
failure on three authenticated connections: WebSocket close code 1002 at
30,008 / 30,014 / 30,017 ms with 30-second heartbeats. Bandit's timeout path emits
that code. No shell sessions were created by this transport-only probe.

Fixed Firefox run: PASS after the full 125 seconds. Both original shells returned
their distinct sentinels and no disconnect/failure transition was observed.

## Unix clipboard shortcut wiring

Ctrl-Shift-C/V explicitly invoke copy/paste; plain Ctrl-C always passes to xterm,
including with a selection. Cmd-C/V remain available for macOS. Async paste checks
that the session is still connected before delivering text through xterm.paste.

`WINDOW_CLIPBOARD_ONLY=1 node assets/check.mjs` (also with WINDOW_BROWSER=firefox)
uses real rendered selection and keyboard events, a controlled clipboard API,
and a real foreground sleep job. It checks selected-text copy, a single paste,
and Ctrl-C interrupt with text selected. Native Linux desktop clipboard permissions
and compositor/browser-reserved shortcuts remain a separate hands-on check.

## Shift-Enter forwarding

Shift-Enter sends CSI-u `ESC [ 13 ; 2 u` once per keydown through the normal input
queue. Plain Enter remains CR; other modifier combinations retain xterm behavior.

`WINDOW_OPEN_BROWSER=0 WINDOW_KEYS_ONLY=1 node assets/check.mjs` (also with
`WINDOW_BROWSER=firefox`) passed in Chromium and Firefox. The check reads actual
raw PTY bytes for Shift-Enter followed by Enter, verifies
`1b 5b 31 33 3b 32 75 0d`, and confirms the shell remains usable afterward.
This verifies browser-to-PTY forwarding; the live Codex composer remains a manual
acceptance check. Reloading window replaces its shell sessions, so this check
does not refresh an existing user session.

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
  owner-loss grace/cleanup, and visible worker failure. Four tests pass (the failure-path test was added and run separately after the full three-test run).
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
  output drains under credits until EOF or explicit close. No detach or persistence.
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

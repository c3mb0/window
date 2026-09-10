# A web terminal that does not suck

Status: IMPLEMENTED FIRST LOCAL VERSION. See README.md for the launcher and
VERIFICATION.md for checked behavior and remaining hands-on acceptance. The
original scope below is retained as the implementation contract.

## Product decision

A local browser terminal: Phoenix + xterm.js + a small TypeScript/CSS frontend.
Keep Erlang/OTP session ownership and the external Rust helper. No desktop wrapper,
no alternative toolkit evaluation, no dashboard. The user explicitly wants:

- A tab strip. Click a tab to switch terminals.
- **+** opens a new terminal tab.
- **×** on a tab closes that terminal session.
- The active terminal fills everything below the strip.

That is the entire application UI. No sidebar, settings panel, toolbar, search
panel, font controls, inspector, telemetry badges or lab controls. Use sensible
fixed defaults and the Signal palette. Keyboard input, selection, scrolling,
copy/paste and ordinary terminal behavior are intrinsic terminal functionality.

Suggested shape:

    [ Terminal 1 × ] [ Terminal 2 × ]  +
    ┌──────────────────────────────────┐
    │ shell                            │
    │                                  │
    └──────────────────────────────────┘

The drawing's border is illustrative, not required chrome. Use a quiet tab strip
and the full available viewport. Errors/exit/disconnect information goes in the
existing terminal surface or tab label, never a new control panel.

## Workspace and authority

Application repository: /Users/cem/window, origin git@github.com:c3mb0/window.git,
MIT. This is the selected home of the UI, not a subdirectory of play.
Backend repository: /Users/cem/play/pty-lab, origin git@github.com:c3mb0/play.git.
Initial backend pin: a04bbb62f21290e8372ec788991c1926b924e0c0.
See DEPENDENCIES.md: the pin is recorded, but no dependency checkout/build wiring
has been installed yet. Check both working trees before changes. Read applicable
AGENTS instructions and play's erlang/pty_lab/API.md, protocol/README.md,
RECEIPTS.md and OPERATOR-WISHLIST.md. Preserve lab tests and receipts.

The user selected separate repositories. window owns Phoenix, browser assets,
theme snapshot, tab UX and personal-session policy. play owns the helper, Erlang
session API and protocol. Shared mechanism changes land in play with appropriate
checks; window adopts a new pinned revision explicitly. Do not duplicate the PTY
backend or introduce a third shared-framework repository. This next-session plan
supersedes the earlier suggestion to put a sibling app inside play.

Signal palette reuse is explicitly authorized by the user. Source:
/Users/cem/ins_repo/signal, signal.go + gruvbox.go + roles.go (Roles() export).
Inspected source revision b8efbdf9c00cccc68b93884b7b942a64ebd369ee. This is a source
pointer, not a permission or hash gate. Copy/export the role values into one local
theme snapshot; normal builds must not require the Signal checkout or Go. Do not
modify Signal. User describes it as their own work and is its sole contributor/user.

Typography source: typography.go; Signal Mono / FiraCode, Nerd Fonts v3.4.0,
ligatures disabled. Use an available monospace fallback initially. If bundling
font files, include their SIL OFL terms/notices. Pick one readable default size;
no font UI in this version.

## Palette lifted into the plan

| Role | Value | Proposed use |
| --- | --- | --- |
| canvas | #1d2021 | terminal background |
| surface | #282828 | tab/title strip |
| surfaceRaised | #32302f | small menus/preferences |
| text | #e8e4dc | default terminal foreground/cursor |
| toolText | #adb3b8 | secondary chrome text |
| muted | #929ca5 | inactive labels |
| dim | #808a95 | quiet terminal/chrome detail |
| chromeTitle | #bbc0c5 | window/session title |
| chromeBorder | #65717c | chrome boundary |
| separator | #46515b | restrained dividers |
| positive | #8fb573 | positive status / ANSI green candidate |
| negative | #d96b63 | failure status / ANSI red candidate |
| pending | #d8bd72 | pending status / ANSI yellow candidate |
| identityBlue | #82a9cc | ANSI blue candidate |
| identityViolet | #b49be0 | ANSI magenta candidate |
| identityAqua | #78b9a2 | ANSI cyan candidate |
| identityOrange | #e09a65 | optional accent |
| copySurface | #203446 | copy feedback; selection-background candidate to review |

These values are observed Signal definitions. Their mapping to terminal ANSI
slots is a NEW proposed adapter, not an existing Signal ANSI theme. First palette:
black=canvas, red=negative, green=positive, yellow=pending, blue=identityBlue,
magenta=identityViolet, cyan=identityAqua, white=text. Start bright variants as
aliases, except brightBlack=dim, then check actual ANSI samples before accepting
that mapping. Do not invent brighter hex values merely to fill slots. Preserve
application-provided 256-color and truecolor sequences; do not recolor their bytes.

One CSS-token/JSON source snapshot should drive chrome and the xterm ITheme
adapter. Cursor accent can use canvas against text. Review selection contrast,
bold versus bright, dim text, Unicode/box drawing and screenshot legibility in the
actual terminal. Color names do not imply validated contrast on every background.

## Architecture

    Browser: tab strip + one xterm instance per live tab
        ↕ Phoenix channel, ordered terminal bytes/control messages
    Elixir terminal-session adapter
        ↕ Erlang public session API with explicit interactive extensions
    session_worker → Rust relay → guardian → controlling PTY → shell

Create the Phoenix application in this window repository, depending on the pinned
play checkout's erlang/pty_lab application. Keep frontend assets here. xterm owns emulation, screen buffers, terminal
input encoding and selection. TypeScript owns tab state. Phoenix owns transport;
Erlang owns sessions; Rust owns Unix mechanics. No React/Svelte requirement and no
LiveView diffing of terminal content. No second PTY owner in the frontend layer.

## Tab behavior — implement exactly

1. First load opens one shell tab. **+** creates a fresh independent session and
   focuses it. Creation failure stays visible in that tab; no invisible retry.
2. Switching tabs preserves each shell, screen, scrollback, selection where
   supported, and output processing. It must not restart, reconnect or replay input.
3. **×** closes that exact session, initiates bounded terminal cleanup and disposes
   its frontend listeners/buffers. Stop the close click from also selecting the tab.
   Closing an inactive tab must not disturb the active one. After closing the
   active tab, select the nearest remaining tab and focus its terminal.
4. Closing the final tab leaves an empty surface with **+** available. Do not
   automatically create a replacement shell.
5. A shell that exits leaves its final screen visible in an exited tab until ×.
   Never silently restart it. A disconnected tab is visibly disconnected and
   cannot keep accepting input as if it were connected.
6. Accessible names for +/×, sensible focus order, and browser resize behavior are
   required. No additional controls are implied by accessibility support.

## Necessary machinery, kept behind the two controls

- **A real shell:** controlling PTY (ctty), new session, correct foreground group.
  Use the configured user shell with an explicit interactive/login choice; /bin/zsh
  is the Mac fallback. Explicit cwd (home default) and usable inherited environment,
  including appropriate TERM. Do not reuse the lab's minimal environment or change
  the user's shell startup files. Ctrl-C/Ctrl-Z travel as terminal input, allowing
  the kernel and shell to implement normal job control.
- **Interactive lifetime:** the current worker caps sessions at 60000 ms. Add a
  separate interactive policy with owner monitoring/renewable lease and bounded
  disconnect grace. Keep existing experiment deadlines unchanged. First version
  has no detach/persistence: page refresh/browser closure cancels its old sessions
  after the stated grace; a new page does not resurrect them. Brief transport
  reconnect must not duplicate input or create a replacement shell.
- **Live size:** measure terminal cells after fonts load, set initial dimensions
  before shell launch, and forward resize(rows, cols) to Rust TIOCSWINSZ. Validate
  bounds and acknowledge observed size. Resize active/hidden tabs correctly when
  shown. Test foreground application SIGWINCH behavior; initial-width evidence
  alone is insufficient.
- **Bytes and flow control:** preserve stream order, split UTF-8 and escape sequences.
  Decode helper hex to bytes and use xterm's byte input rather than separately
  decoding chunks to strings. Forward onData/onBinary correctly. Bound backend
  mailboxes and browser queues; use xterm processing acknowledgements/credits to
  propagate backpressure without starving resize/close. One busy or hidden tab
  must not freeze the others. Do not silently drop terminal output.
- **Truthful close:** caller death is not currently worker death. Explicitly bind
  tab ownership to session lifetime. Separate shell exit, stream EOF and cleanup;
  descendants can retain output descriptors. Implement conventional terminal
  hangup and bounded escalation for the documented job/process scope. Check a
  controlled foreground job and report incomplete cleanup honestly. Do not claim
  arbitrary descendant containment or kill unrelated processes.
- **Personal-use recording:** default full input/output recording OFF. The lab
  currently journals raw keystrokes, including potential passwords. Use bounded
  in-memory scrollback and minimal lifecycle records for personal sessions; no
  recording/export UI in this version. Preserve lab recording and immutable evidence.
- **Local app boundary:** loopback-only service, origin validation and startup
  capability/token for shell access. Local assets; terminal bytes never become
  injected HTML/backend commands. Explicit clipboard/hyperlink handling. No remote
  shell service, accounts, multi-tenancy, deployment or approval platform.

## Build order

1. Bind both workspaces and inspect the session boundary. Materialize the pinned
   play dependency as described in DEPENDENCIES.md, then scaffold Phoenix here
   without overwriting this repo's LICENSE/docs. Pin dependencies and lockfiles;
   no ecosystem re-evaluation.
2. Export the Signal theme and wire xterm into the exact tab strip above. Use a
   temporary specimen only to check fonts/colors/selection, then connect a real shell.
3. Complete one shell's controlling-terminal, lifetime, recording and ordered-byte
   path. Provide one documented command, preferably make terminal, to start the
   local app and print its URL. No company checkout dependency at runtime.
4. Finish live resize, flow control and explicit close semantics; wire independent
   sessions to +/×. Do not defer tabs: they are the requested product.
5. Verify the useful acceptance list below, document the launcher and limitations,
   commit and push. Stop. Desktop packaging and extra UI are outside this plan.

## Acceptance: can the user actually use it?

- One command starts the local app. Open URL, get shell. + creates another shell;
  switching tabs preserves both; × closes the selected session only; last close
  leaves +. No other app controls exist.
- A shell survives beyond 60 seconds; owner loss is handled according to the
  documented grace. No accidental duplication after reconnect or refresh.
- Backspace, arrows/history, Ctrl-C, Ctrl-Z/fg, Ctrl-D, Option/Alt, Cmd-C/V,
  bracketed paste, IME and Unicode/wide characters work as specified on macOS.
  Copy shortcuts must not consume terminal Ctrl-C. Selection survives ordinary
  output and scrolling; new output does not yank a user away from older scrollback.
- less or an installed editor uses alternate screen and redraws correctly through
  repeated resize and tab switching. stty size matches the rendered cell grid.
- A bounded high-output command loses no bytes, keeps memory bounded, and leaves
  other tabs and close controls responsive. Test split UTF-8/escape sequences.
- Exiting shell, closing a tab with a controlled foreground job, browser loss and
  helper failure produce truthful state and cleanup for the documented scope.
- No default on-disk keystroke/output transcripts. Existing lab receipt behavior
  remains intact. Palette literals come from one snapshot and adapter.
- Run the existing checks appropriate to changed helper/protocol/OTP code. Keep
  failures visible; do not turn this into another open-ended lab campaign.

## References for implementation

- https://github.com/xtermjs/xterm.js
- https://xtermjs.org/docs/api/terminal/interfaces/itheme/
- https://xtermjs.org/docs/guides/flowcontrol/
- https://hexdocs.pm/phoenix/channels.html

Repository setup began with license and planning documents only. The application,
submodule/build wiring and local theme snapshot are now implemented; current
verification evidence is recorded in VERIFICATION.md.

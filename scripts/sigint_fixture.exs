helper = System.fetch_env!("CHECK_HELPER")
marker = System.fetch_env!("CHECK_MARKER")

spec = %{
  "executable" => "/bin/bash",
  "argv" => [
    "-c",
    "set -m; trap '' HUP TERM; echo $$ > \"$CHECK_MARKER\"; (trap '' HUP TERM; while :; do sleep 1; done) & echo $! >> \"$CHECK_MARKER\"; sleep 600"
  ],
  "cwd" => "/tmp",
  "environment" => %{"PATH" => "/usr/bin:/bin", "CHECK_MARKER" => marker, "TERM" => "xterm"},
  "attachment" => "ctty",
  "terminal" => %{"dimensions" => %{"rows" => 24, "cols" => 80, "xpixel" => 0, "ypixel" => 0}}
}

{:ok, session} =
  Window.TerminalSession.open(
    "sigint-check",
    %{
      helper: String.to_charlist(helper),
      identity: %{"experiment" => "sigint", "cell" => "owned-jobs", "session" => "check"},
      spec: spec
    },
    false
  )

{:ok, _} = Window.TerminalSession.call(session, {:attach, 0})
Process.sleep(:infinity)

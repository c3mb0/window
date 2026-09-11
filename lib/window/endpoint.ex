defmodule Window.Endpoint do
  use Phoenix.Endpoint, otp_app: :window

  socket("/socket", Window.Socket,
    # Leave ample room beyond the browser heartbeat, including timer throttling.
    websocket: [max_frame_size: 32_768, timeout: 120_000],
    longpoll: false
  )

  plug(:boundary)
  plug(Plug.Static, at: "/assets", from: {:window, "priv/static"}, only: ~w(app.js app.css fonts))
  plug(:page)

  defp boundary(conn, _) do
    conn
    |> Plug.Conn.put_resp_header(
      "content-security-policy",
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
    )
    |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
  end

  defp page(%{request_path: "/", method: "GET"} = conn, _) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>window</title><link rel="stylesheet" href="/assets/app.css"><script type="module" src="/assets/app.js"></script></head><body><nav aria-label="Terminals"><div id="tabs" role="tablist"></div><button id="new" aria-label="Open terminal">+</button></nav><main id="terminals"></main></body></html>
    """)
  end

  defp page(conn, _), do: Plug.Conn.send_resp(conn, 404, "Not found")
end

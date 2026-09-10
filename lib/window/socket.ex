defmodule Window.Socket do
  use Phoenix.Socket
  channel("terminal:*", Window.TerminalChannel)

  def connect(%{"token" => token}, socket, _) when is_binary(token) do
    expected = Application.get_env(:window, :token, "")

    if byte_size(expected) > 0 and Plug.Crypto.secure_compare(token, expected),
      do: {:ok, socket},
      else: :error
  end

  def connect(_, _, _), do: :error
  def id(_), do: nil
end

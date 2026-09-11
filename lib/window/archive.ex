defmodule Window.Archive do
  @moduledoc "One bounded request at a time to an isolated DuckDB owner."
  use GenServer
  alias Window.Storage.Admission

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def request(request, server \\ __MODULE__) do
    with :ok <- Admission.take(server, 16),
         do: GenServer.call(server, {:request, request}, 12_000)
  catch
    :exit, _ -> {:error, "archive unavailable or request timed out"}
  end

  def restart(server \\ __MODULE__) do
    with :ok <- Admission.take(server, 16), do: GenServer.call(server, :restart)
  end

  def shutdown(server \\ __MODULE__), do: snapshot(nil, server)

  def snapshot(destination, server \\ __MODULE__) do
    with :ok <- Admission.take(server, 16),
         do: GenServer.call(server, {:snapshot, destination}, 120_000)
  catch
    :exit, _ -> {:error, "archive snapshot unavailable or timed out"}
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    Admission.init(name)

    {:ok,
     %{
       name: name,
       file: Keyword.fetch!(opts, :file),
       helper: Keyword.fetch!(opts, :helper),
       port: nil
     }}
  end

  def handle_call(:restart, _, state) do
    close(state.port)
    Admission.release(state.name)
    {:reply, :ok, %{state | port: nil}}
  end

  def handle_call({:snapshot, destination}, from, state) do
    # Keep ownership serialized through shutdown, OS-process exit, and file copy.
    # The nested handler releases the single admitted slot.
    case handle_call({:request, %{op: "shutdown"}}, from, state) do
      {:reply, {:ok, _}, next} ->
        port = next.port

        result =
          receive do
            {^port, {:exit_status, 0}} ->
              if(destination, do: File.cp(state.file, destination), else: :ok)

            {^port, {:exit_status, _}} ->
              {:error, "archive shutdown failed"}
          after
            10_000 ->
              close(port)
              {:error, "archive shutdown timed out"}
          end

        reply =
          case result do
            :ok -> {:ok, destination}
            {:error, reason} -> {:error, to_string(reason)}
          end

        {:reply, reply, %{next | port: nil}}

      other ->
        other
    end
  end

  def handle_call({:request, request}, _, state) do
    try do
      data = Jason.encode!(request)
      if byte_size(data) > 4_194_304, do: raise("archive request exceeds 4 MiB")

      port =
        state.port ||
          Port.open(
            {:spawn_executable, String.to_charlist(state.helper)},
            [:binary, {:packet, 4}, :exit_status, args: [String.to_charlist(state.file)]]
          )

      Port.command(port, data)

      receive do
        {^port, {:data, response}} ->
          case Jason.decode(response) do
            {:ok, %{"ok" => result}} ->
              {:reply, {:ok, result}, %{state | port: port}}

            {:ok, %{"error" => error}} ->
              {:reply, {:error, error}, %{state | port: port}}

            _ ->
              close(port)
              {:reply, {:error, "invalid archive response"}, %{state | port: nil}}
          end

        {^port, {:exit_status, _}} ->
          {:reply, {:error, "archive worker exited"}, %{state | port: nil}}

        {:EXIT, ^port, _} ->
          {:reply, {:error, "archive worker exited"}, %{state | port: nil}}
      after
        10_000 ->
          close(port)
          {:reply, {:error, "archive request timed out"}, %{state | port: nil}}
      end
    rescue
      error ->
        close(state.port)
        {:reply, {:error, Exception.message(error)}, %{state | port: nil}}
    after
      Admission.release(state.name)
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:noreply, %{state | port: nil}}

  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:noreply, %{state | port: nil}}
  def handle_info(_, state), do: {:noreply, state}
  def terminate(_, state), do: close(state.port)
  defp close(nil), do: :ok

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end

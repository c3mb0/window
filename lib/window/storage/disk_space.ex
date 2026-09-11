defmodule Window.Storage.DiskSpace do
  @moduledoc false
  use GenServer

  def start_link(directory), do: GenServer.start_link(__MODULE__, directory, name: __MODULE__)

  def status do
    :ets.lookup_element(__MODULE__, :sample, 2)
  rescue
    ArgumentError -> %{free_bytes: nil, sampled_at: nil}
  end

  def init(directory) do
    :ets.new(__MODULE__, [:named_table, :protected])
    :ets.insert(__MODULE__, {:sample, %{free_bytes: nil, sampled_at: nil}})
    send(self(), :sample)
    {:ok, directory}
  end

  def handle_info(:sample, directory) do
    :ets.insert(
      __MODULE__,
      {:sample, %{free_bytes: available(directory), sampled_at: System.system_time(:millisecond)}}
    )

    Process.send_after(self(), :sample, 30_000)
    {:noreply, directory}
  end

  def handle_info(_, directory), do: {:noreply, directory}

  defp available(directory) do
    port =
      Port.open({:spawn_executable, ~c"/bin/df"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-Pk", directory]
      ])

    deadline = System.monotonic_time(:millisecond) + 2000
    collect(port, "", deadline)
  rescue
    _ -> nil
  end

  defp collect(port, data, deadline) do
    receive do
      {^port, {:data, chunk}} when byte_size(data) + byte_size(chunk) <= 16_384 ->
        collect(port, data <> chunk, deadline)

      {^port, {:exit_status, 0}} ->
        fields = data |> String.split("\n", trim: true) |> List.last() |> String.split()

        case Integer.parse(Enum.at(fields, 3, "")) do
          {kb, ""} -> kb * 1024
          _ -> nil
        end

      {^port, _} ->
        Port.close(port)
        nil
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        Port.close(port)
        nil
    end
  end
end

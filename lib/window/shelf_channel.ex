defmodule Window.ShelfChannel do
  use Phoenix.Channel
  alias Window.{SessionStore, Archive}

  def join("shelf", _, socket), do: {:ok, socket}

  def handle_in("list", _, socket) do
    result =
      with {:ok, status} <- SessionStore.request(:status) do
        case SessionStore.request(:list) do
          {:ok, sessions} ->
            {:ok,
             %{
               sessions: Enum.map(sessions, &Map.put(&1, "runtime", runtime(&1["id"]))),
               status: status
             }}

          {:error, reason} ->
            {:ok, %{sessions: [], status: %{status | error: reason}}}
        end
      end

    respond(result, socket)
  end

  def handle_in("timeline", %{"id" => id}, socket) when is_binary(id) and byte_size(id) <= 128 do
    # Pending first: a drain between these reads can duplicate an ID but cannot hide it.
    result =
      with {:ok, pending} <- SessionStore.request({:pending_timeline, id}) do
        {archived, error} =
          case archived_timeline(id) do
            {:ok, %{"events" => events}} -> {events, nil}
            {:error, error} -> {[], error}
          end

        events =
          (archived ++ pending)
          |> Enum.uniq_by(& &1["id"])
          |> Enum.sort_by(& &1["revision"], :desc)
          |> Enum.take(250)

        pending_ids = MapSet.new(pending, & &1["id"])
        archived_ids = MapSet.new(archived, & &1["id"])

        events =
          Enum.map(
            events,
            &Map.put(
              &1,
              "pending",
              MapSet.member?(pending_ids, &1["id"]) and !MapSet.member?(archived_ids, &1["id"])
            )
          )

        {:ok, %{events: events, archive_error: error}}
      end

    respond(result, socket)
  end

  def handle_in("rename", %{"id" => id, "name" => name}, socket)
      when is_binary(id) and byte_size(id) <= 128 and is_binary(name) and byte_size(name) <= 128 do
    respond(SessionStore.request({:rename, id, name}), socket)
  end

  def handle_in("focus", %{"id" => id}, socket) when is_binary(id) and byte_size(id) <= 128 do
    result =
      if runtime(id).live, do: {:ok, %{id: id}}, else: {:error, "Session is no longer live"}

    respond(result, socket)
  end

  def handle_in("backup", _, socket), do: respond(Window.Storage.Backup.create(), socket)
  def handle_in(_, _, socket), do: respond({:error, "Unsupported shelf request"}, socket)

  defp archived_timeline(id) do
    with {:ok, identity} <- SessionStore.request(:identity),
         {:ok, _} <-
           Archive.request(%{
             op: "identity",
             archive_id: identity.archive_id,
             allow_create: false
           }) do
      Archive.request(%{op: "timeline", session_id: id})
    end
  end

  def runtime(id) do
    case Registry.lookup(Window.Terminals, id) do
      [{pid, _}] -> GenServer.call(pid, :runtime_status, 50)
      [] -> %{live: false, attached: false}
    end
  catch
    :exit, _ -> %{live: false, attached: false}
  end

  defp respond({:ok, result}, socket), do: {:reply, {:ok, result}, socket}
  defp respond({:error, reason}, socket), do: {:reply, {:error, %{reason: reason}}, socket}
end

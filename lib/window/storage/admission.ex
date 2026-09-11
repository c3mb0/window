defmodule Window.Storage.Admission do
  @moduledoc false
  def init(name) do
    :ets.new(name, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(name, [{:pending, 0}, {:rejected, 0}])
  end

  def take(name, limit) do
    if :ets.update_counter(name, :pending, 1) <= limit do
      :ok
    else
      release(name)
      :ets.update_counter(name, :rejected, 1)
      {:error, "storage queue admission limit reached"}
    end
  rescue
    ArgumentError -> {:error, "storage process unavailable"}
  end

  def release(name) do
    :ets.update_counter(name, :pending, -1)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def counts(name) do
    %{
      queued: :ets.lookup_element(name, :pending, 2),
      rejected: :ets.lookup_element(name, :rejected, 2)
    }
  rescue
    ArgumentError -> %{queued: 0, rejected: 0}
  end
end

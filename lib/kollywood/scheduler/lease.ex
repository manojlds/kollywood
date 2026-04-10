defmodule Kollywood.Scheduler.Lease do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Query

  alias Kollywood.Repo

  @primary_key false
  schema "scheduler_leases" do
    field(:name, :string, primary_key: true)
    field(:owner_id, :string)
    field(:lease_expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type status :: %{
          name: String.t(),
          leader?: boolean(),
          owner_id: String.t() | nil,
          lease_expires_at: DateTime.t() | nil
        }

  @spec acquire(String.t(), String.t(), pos_integer()) :: {:ok, status()} | {:error, term()}
  def acquire(name, owner_id, ttl_ms)
      when is_binary(name) and name != "" and is_binary(owner_id) and owner_id != "" and
             is_integer(ttl_ms) and ttl_ms > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, ttl_ms, :millisecond)

    ensure_row(name, now)

    {updated_count, _} =
      __MODULE__
      |> where([lease], lease.name == ^name)
      |> where(
        [lease],
        is_nil(lease.owner_id) or lease.owner_id == ^owner_id or
          lease.lease_expires_at < ^now
      )
      |> Repo.update_all(set: [owner_id: owner_id, lease_expires_at: expires_at, updated_at: now])

    case updated_count do
      1 -> {:ok, %{name: name, leader?: true, owner_id: owner_id, lease_expires_at: expires_at}}
      _ -> {:ok, status_from_entry(name, Repo.get(__MODULE__, name), owner_id)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def acquire(_name, _owner_id, _ttl_ms), do: {:error, :invalid_arguments}

  @spec release(String.t(), String.t()) :: :ok | {:error, term()}
  def release(name, owner_id)
      when is_binary(name) and name != "" and is_binary(owner_id) and owner_id != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ =
      __MODULE__
      |> where([lease], lease.name == ^name and lease.owner_id == ^owner_id)
      |> Repo.update_all(set: [owner_id: nil, lease_expires_at: nil, updated_at: now])

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  def release(_name, _owner_id), do: {:error, :invalid_arguments}

  @spec status(String.t(), String.t() | nil) :: {:ok, status()} | {:error, term()}
  def status(name, owner_id \\ nil)

  def status(name, owner_id) when is_binary(name) and name != "" do
    {:ok, status_from_entry(name, Repo.get(__MODULE__, name), owner_id)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  def status(_name, _owner_id), do: {:error, :invalid_arguments}

  defp ensure_row(name, now) do
    Repo.insert(
      %__MODULE__{name: name, inserted_at: now, updated_at: now},
      on_conflict: :nothing,
      conflict_target: [:name]
    )
  end

  defp status_from_entry(name, nil, owner_id) do
    %{name: name, leader?: false, owner_id: nil, lease_expires_at: nil_for(owner_id)}
  end

  defp status_from_entry(name, entry, owner_id) do
    %{
      name: name,
      leader?: is_binary(owner_id) and owner_id != "" and entry.owner_id == owner_id,
      owner_id: entry.owner_id,
      lease_expires_at: entry.lease_expires_at
    }
  end

  defp nil_for(_owner_id), do: nil
end

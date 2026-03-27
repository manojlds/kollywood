defmodule Kollywood.Orchestrator.EphemeralStore do
  @moduledoc """
  Persistent storage for short-lived orchestrator markers.

  This stores claimed/completed markers with expiry so the orchestrator can
  restore safe guards across restarts without keeping permanent locks.
  """

  import Ecto.Query

  alias Kollywood.Repo

  @valid_kinds ["claimed", "completed"]

  defmodule Entry do
    use Ecto.Schema
    import Ecto.Changeset

    @valid_kinds ["claimed", "completed"]

    @primary_key false
    schema "orchestrator_ephemeral_entries" do
      field(:issue_id, :string)
      field(:kind, :string)
      field(:expires_at_ms, :integer)

      timestamps(type: :utc_datetime_usec)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(entry, attrs) do
      entry
      |> cast(attrs, [:issue_id, :kind, :expires_at_ms])
      |> validate_required([:issue_id, :kind, :expires_at_ms])
      |> validate_inclusion(:kind, @valid_kinds)
    end
  end

  @spec upsert(atom() | String.t(), String.t(), integer()) :: :ok | {:error, String.t()}
  def upsert(kind, issue_id, expires_at_ms)
      when is_binary(issue_id) and is_integer(expires_at_ms) do
    attrs = %{
      issue_id: issue_id,
      kind: encode_kind(kind),
      expires_at_ms: expires_at_ms
    }

    changeset = Entry.changeset(%Entry{}, attrs)

    case Repo.insert(changeset,
           on_conflict: {:replace, [:expires_at_ms, :updated_at]},
           conflict_target: [:issue_id, :kind]
         ) do
      {:ok, _entry} -> :ok
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def upsert(_kind, _issue_id, _expires_at_ms), do: {:error, "invalid ephemeral entry"}

  @spec delete(atom() | String.t(), String.t()) :: :ok | {:error, String.t()}
  def delete(kind, issue_id) when is_binary(issue_id) do
    encoded_kind = encode_kind(kind)

    _ =
      Repo.delete_all(
        from(entry in Entry,
          where: entry.issue_id == ^issue_id and entry.kind == ^encoded_kind
        )
      )

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  def delete(_kind, _issue_id), do: {:error, "issue_id must be a string"}

  @spec list_active(integer()) :: {:ok, [map()]} | {:error, String.t()}
  def list_active(now_ms) when is_integer(now_ms) do
    _ = Repo.delete_all(from(entry in Entry, where: entry.expires_at_ms <= ^now_ms))

    entries =
      Repo.all(
        from(entry in Entry,
          where: entry.expires_at_ms > ^now_ms,
          order_by: [asc: entry.updated_at]
        )
      )

    {:ok,
     Enum.map(entries, fn entry ->
       %{
         issue_id: entry.issue_id,
         kind: decode_kind(entry.kind),
         expires_at_ms: entry.expires_at_ms
       }
     end)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @spec clear() :: :ok | {:error, String.t()}
  def clear do
    _ = Repo.delete_all(Entry)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp encode_kind(kind) when is_atom(kind), do: encode_kind(Atom.to_string(kind))
  defp encode_kind(kind) when kind in @valid_kinds, do: kind
  defp encode_kind(_kind), do: "claimed"

  defp decode_kind("completed"), do: :completed
  defp decode_kind(_kind), do: :claimed

  defp changeset_error(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} ->
        message
      end)

    inspect(errors)
  end
end

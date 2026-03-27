defmodule Kollywood.Orchestrator.RetryStore do
  @moduledoc """
  Persistent storage for orchestrator retry entries.

  This keeps retry intent durable across orchestrator restarts.
  """

  import Ecto.Query
  require Logger

  alias Kollywood.Repo

  @valid_kinds ["run", "finalize_done", "finalize_resumable"]

  defmodule Entry do
    use Ecto.Schema
    import Ecto.Changeset

    @valid_kinds ["run", "finalize_done", "finalize_resumable"]

    @primary_key {:issue_id, :string, autogenerate: false}
    schema "orchestrator_retry_entries" do
      field(:attempt, :integer)
      field(:reason, :string)
      field(:kind, :string, default: "run")
      field(:due_at_ms, :integer)
      field(:issue_term, :binary)
      field(:finalization_term, :binary)

      timestamps(type: :utc_datetime_usec)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(entry, attrs) do
      entry
      |> cast(attrs, [
        :issue_id,
        :attempt,
        :reason,
        :kind,
        :due_at_ms,
        :issue_term,
        :finalization_term
      ])
      |> validate_required([:issue_id, :attempt, :kind, :due_at_ms, :issue_term])
      |> validate_number(:attempt, greater_than: 0)
      |> validate_inclusion(:kind, @valid_kinds)
    end
  end

  @spec upsert(String.t(), map()) :: :ok | {:error, String.t()}
  def upsert(issue_id, retry_entry) when is_binary(issue_id) and is_map(retry_entry) do
    with {:ok, issue_term} <- encode_term(Map.get(retry_entry, :issue)),
         {:ok, finalization_term} <- encode_optional_term(Map.get(retry_entry, :finalization)) do
      attrs = %{
        issue_id: issue_id,
        attempt: Map.get(retry_entry, :attempt),
        reason: Map.get(retry_entry, :reason),
        kind: encode_kind(Map.get(retry_entry, :kind)),
        due_at_ms: Map.get(retry_entry, :due_at_ms),
        issue_term: issue_term,
        finalization_term: finalization_term
      }

      changeset = Entry.changeset(%Entry{}, attrs)

      case Repo.insert(changeset,
             on_conflict: {
               :replace,
               [
                 :attempt,
                 :reason,
                 :kind,
                 :due_at_ms,
                 :issue_term,
                 :finalization_term,
                 :updated_at
               ]
             },
             conflict_target: [:issue_id]
           ) do
        {:ok, _entry} -> :ok
        {:error, changeset} -> {:error, changeset_error(changeset)}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def upsert(_issue_id, _retry_entry), do: {:error, "invalid retry entry"}

  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(issue_id) when is_binary(issue_id) do
    _ = Repo.delete_all(from(entry in Entry, where: entry.issue_id == ^issue_id))
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  def delete(_issue_id), do: {:error, "issue_id must be a string"}

  @spec list() :: {:ok, [map()]} | {:error, String.t()}
  def list do
    entries = Repo.all(from(entry in Entry, order_by: [asc: entry.updated_at]))

    retry_entries =
      Enum.reduce(entries, [], fn entry, acc ->
        case to_retry_entry(entry) do
          {:ok, retry_entry} ->
            [retry_entry | acc]

          {:error, reason} ->
            _ = Repo.delete(entry)

            Logger.warning(
              "Discarding invalid persisted retry issue_id=#{entry.issue_id}: #{reason}"
            )

            acc
        end
      end)
      |> Enum.reverse()

    {:ok, retry_entries}
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

  defp to_retry_entry(%Entry{} = entry) do
    with {:ok, issue} <- decode_term(entry.issue_term),
         {:ok, finalization} <- decode_optional_term(entry.finalization_term) do
      {:ok,
       %{
         issue_id: entry.issue_id,
         issue: issue,
         attempt: entry.attempt,
         reason: entry.reason,
         kind: decode_kind(entry.kind),
         finalization: finalization,
         due_at_ms: entry.due_at_ms
       }}
    end
  end

  defp encode_term(term), do: {:ok, :erlang.term_to_binary(term, [:compressed])}

  defp encode_optional_term(nil), do: {:ok, nil}
  defp encode_optional_term(term), do: encode_term(term)

  defp decode_term(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp decode_term(_value), do: {:error, "term binary is invalid"}

  defp decode_optional_term(nil), do: {:ok, nil}
  defp decode_optional_term(binary), do: decode_term(binary)

  defp encode_kind(kind) when is_atom(kind), do: encode_kind(Atom.to_string(kind))
  defp encode_kind(kind) when kind in @valid_kinds, do: kind
  defp encode_kind(_kind), do: "run"

  defp decode_kind("finalize_done"), do: :finalize_done
  defp decode_kind("finalize_resumable"), do: :finalize_resumable
  defp decode_kind(_kind), do: :run

  defp changeset_error(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} ->
        message
      end)

    inspect(errors)
  end
end

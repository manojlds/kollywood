defmodule Kollywood.RunQueue do
  @moduledoc """
  Persistent work queue backed by SQLite.

  The orchestrator enqueues dispatch intents; worker nodes claim and execute
  them. Results are written back to the queue and broadcast via PubSub so
  the orchestrator can react without polling.

  Statuses: pending -> claimed -> running -> completed | failed | cancelled
  """

  import Ecto.Query

  alias Kollywood.Repo
  alias Kollywood.RunQueue.Entry

  @pubsub Kollywood.PubSub
  @topic "run_queue"
  @stale_claim_threshold_ms 600_000

  # --- PubSub ---

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(@pubsub, @topic, {:run_queue, event})

  # --- Enqueue ---

  @spec enqueue(map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(attrs) when is_map(attrs) do
    %Entry{}
    |> Entry.changeset(Map.put(attrs, :status, "pending"))
    |> Repo.insert()
    |> case do
      {:ok, entry} = ok ->
        broadcast({:enqueued, entry.id, entry.issue_id})
        ok

      error ->
        error
    end
  end

  # --- Claim ---

  @spec claim(String.t(), pos_integer()) :: {:ok, Entry.t()} | :none
  def claim(node_id, count \\ 1) when is_binary(node_id) and count > 0 do
    now = DateTime.utc_now()

    entry =
      Entry
      |> where([e], e.status == "pending")
      |> order_by([e], desc: e.priority, asc: e.inserted_at)
      |> limit(1)
      |> Repo.one()

    case entry do
      nil ->
        :none

      entry ->
        {updated_count, _} =
          Entry
          |> where([e], e.id == ^entry.id and e.status == "pending")
          |> Repo.update_all(
            set: [
              status: "claimed",
              claimed_by_node: node_id,
              claimed_at: now,
              updated_at: now
            ]
          )

        if updated_count == 1 do
          updated = Repo.get!(Entry, entry.id)
          broadcast({:claimed, updated.id, updated.issue_id, node_id})
          {:ok, updated}
        else
          :none
        end
    end
  end

  @spec claim_batch(String.t(), pos_integer()) :: [Entry.t()]
  def claim_batch(node_id, count) when is_binary(node_id) and count > 0 do
    Enum.reduce_while(1..count, [], fn _i, acc ->
      case claim(node_id) do
        {:ok, entry} -> {:cont, [entry | acc]}
        :none -> {:halt, acc}
      end
    end)
    |> Enum.reverse()
  end

  # --- Mark running ---

  @spec mark_running(integer()) :: {:ok, Entry.t()} | {:error, term()}
  def mark_running(entry_id) do
    case Repo.get(Entry, entry_id) do
      nil ->
        {:error, :not_found}

      entry ->
        entry
        |> Entry.changeset(%{status: "running", started_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  # --- Complete ---

  @spec complete(integer(), map()) :: {:ok, Entry.t()} | {:error, term()}
  def complete(entry_id, result_attrs \\ %{}) do
    case Repo.get(Entry, entry_id) do
      nil ->
        {:error, :not_found}

      entry ->
        payload =
          Map.get(result_attrs, :result_payload) || Map.get(result_attrs, "result_payload")

        changeset =
          Entry.changeset(entry, %{
            status: "completed",
            result_payload: encode_payload(payload),
            completed_at: DateTime.utc_now()
          })

        case Repo.update(changeset) do
          {:ok, updated} = ok ->
            broadcast(
              {:completed, updated.id, updated.issue_id, decode_payload(updated.result_payload)}
            )

            ok

          error ->
            error
        end
    end
  end

  # --- Fail ---

  @spec fail(integer(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def fail(entry_id, error_message) do
    case Repo.get(Entry, entry_id) do
      nil ->
        {:error, :not_found}

      entry ->
        changeset =
          Entry.changeset(entry, %{
            status: "failed",
            error: error_message,
            completed_at: DateTime.utc_now()
          })

        case Repo.update(changeset) do
          {:ok, updated} = ok ->
            broadcast({:failed, updated.id, updated.issue_id, error_message})
            ok

          error ->
            error
        end
    end
  end

  # --- Cancel ---

  @spec cancel(integer()) :: {:ok, Entry.t()} | {:error, term()}
  def cancel(entry_id) do
    case Repo.get(Entry, entry_id) do
      nil ->
        {:error, :not_found}

      entry ->
        entry
        |> Entry.changeset(%{status: "cancelled", completed_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  # --- Queries ---

  @spec list_pending() :: [Entry.t()]
  def list_pending do
    Entry
    |> where([e], e.status == "pending")
    |> order_by([e], desc: e.priority, asc: e.inserted_at)
    |> Repo.all()
  end

  @spec list_by_status(String.t() | [String.t()]) :: [Entry.t()]
  def list_by_status(status) when is_binary(status) do
    Entry
    |> where([e], e.status == ^status)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  def list_by_status(statuses) when is_list(statuses) do
    Entry
    |> where([e], e.status in ^statuses)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @spec get(integer()) :: Entry.t() | nil
  def get(entry_id), do: Repo.get(Entry, entry_id)

  @spec get_by_issue(String.t()) :: Entry.t() | nil
  def get_by_issue(issue_id) do
    Entry
    |> where([e], e.issue_id == ^issue_id)
    |> where([e], e.status in ["pending", "claimed", "running"])
    |> order_by([e], desc: e.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec pending_count() :: non_neg_integer()
  def pending_count do
    Entry
    |> where([e], e.status == "pending")
    |> Repo.aggregate(:count)
  end

  @spec queue_overview_stats() :: %{
          pending_count: non_neg_integer(),
          running_count: non_neg_integer(),
          completed_last_hour_count: non_neg_integer(),
          failed_last_hour_count: non_neg_integer()
        }
  def queue_overview_stats do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    %{
      pending_count: count_by_status("pending"),
      running_count: count_by_status("running"),
      completed_last_hour_count: count_completed_since(cutoff),
      failed_last_hour_count: count_failed_since(cutoff)
    }
  end

  @spec list_recent(non_neg_integer()) :: [Entry.t()]
  def list_recent(limit \\ 10) when is_integer(limit) and limit > 0 do
    Entry
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # --- Stale claim recovery ---

  @spec reclaim_stale(pos_integer()) :: non_neg_integer()
  def reclaim_stale(threshold_ms \\ @stale_claim_threshold_ms) do
    cutoff = DateTime.add(DateTime.utc_now(), -threshold_ms, :millisecond)

    {count, _} =
      Entry
      |> where([e], e.status == "claimed")
      |> where([e], e.claimed_at < ^cutoff)
      |> Repo.update_all(
        set: [
          status: "pending",
          claimed_by_node: nil,
          claimed_at: nil,
          started_at: nil,
          updated_at: DateTime.utc_now()
        ]
      )

    if count > 0 do
      broadcast({:reclaimed_stale, count})
    end

    count
  end

  # --- Cleanup ---

  @spec prune_completed(pos_integer()) :: non_neg_integer()
  def prune_completed(older_than_ms \\ 86_400_000) do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_ms, :millisecond)

    {count, _} =
      Entry
      |> where([e], e.status in ["completed", "failed", "cancelled"])
      |> where([e], e.completed_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  # --- Payload encoding ---

  defp encode_payload(nil), do: nil
  defp encode_payload(payload) when is_binary(payload), do: payload

  defp encode_payload(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> json
      {:error, _} -> inspect(payload)
    end
  end

  defp decode_payload(nil), do: nil

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _} -> payload
    end
  end

  defp count_by_status(status) do
    Entry
    |> where([e], e.status == ^status)
    |> Repo.aggregate(:count)
  end

  defp count_completed_since(cutoff) do
    Entry
    |> where([e], e.status == "completed")
    |> where([e], e.completed_at > ^cutoff)
    |> Repo.aggregate(:count)
  end

  defp count_failed_since(cutoff) do
    Entry
    |> where([e], e.status == "failed")
    |> where([e], e.completed_at > ^cutoff)
    |> Repo.aggregate(:count)
  end
end

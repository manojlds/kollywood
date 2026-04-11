defmodule Kollywood.RunQueue do
  @moduledoc """
  Durable run attempt storage implementation.

  The orchestrator enqueues dispatch intents; worker nodes claim and execute
  them. Results are written back to the queue and broadcast via PubSub so
  the orchestrator can react without polling.

  Statuses: pending -> claimed -> running -> completed | failed | cancelled
            running -> cancel_requested -> cancelled
  """

  import Ecto.Query

  alias Kollywood.Repo
  alias Kollywood.RunAttempts.Attempt, as: Entry

  @pubsub Kollywood.PubSub
  @topic "run_attempts"
  @stale_claim_threshold_ms 600_000

  # --- PubSub ---

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  defp broadcast(event), do: Phoenix.PubSub.broadcast(@pubsub, @topic, {:run_attempts, event})

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
    lease_token = Ecto.UUID.generate()

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
              lease_token: lease_token,
              claimed_at: now,
              last_heartbeat_at: now,
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
    now = DateTime.utc_now()

    {updated_count, _} =
      Entry
      |> where([e], e.id == ^entry_id and e.status == "claimed")
      |> Repo.update_all(set: [status: "running", started_at: now, updated_at: now])

    case updated_count do
      1 -> {:ok, Repo.get!(Entry, entry_id)}
      _ -> ownership_error(entry_id)
    end
  end

  @spec mark_running_for_worker(integer(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def mark_running_for_worker(entry_id, worker_id, lease_token)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) do
    now = DateTime.utc_now()

    {updated_count, _} =
      owned_active_query(entry_id, worker_id, lease_token)
      |> where([e], e.status == "claimed")
      |> Repo.update_all(
        set: [
          status: "running",
          started_at: now,
          last_heartbeat_at: now,
          updated_at: now
        ]
      )

    case updated_count do
      1 -> {:ok, Repo.get!(Entry, entry_id)}
      _ -> worker_transition_error(entry_id, worker_id, lease_token)
    end
  end

  def mark_running_for_worker(_entry_id, _worker_id, _lease_token),
    do: {:error, :invalid_arguments}

  # --- Complete ---

  @spec complete(integer(), map()) :: {:ok, Entry.t()} | {:error, term()}
  def complete(entry_id, result_attrs \\ %{}) do
    payload = Map.get(result_attrs, :result_payload) || Map.get(result_attrs, "result_payload")
    now = DateTime.utc_now()

    {updated_count, _} =
      Entry
      |> where([e], e.id == ^entry_id and e.status in ["claimed", "running"])
      |> Repo.update_all(
        set: [
          status: "completed",
          result_payload: encode_payload(payload),
          completed_at: now,
          updated_at: now
        ]
      )

    case updated_count do
      1 ->
        updated = Repo.get!(Entry, entry_id)

        broadcast(
          {:completed, updated.id, updated.issue_id, decode_payload(updated.result_payload)}
        )

        {:ok, updated}

      _ ->
        ownership_error(entry_id)
    end
  end

  @spec complete_for_worker(integer(), String.t(), String.t(), map()) ::
          {:ok, Entry.t()} | {:error, term()}
  def complete_for_worker(entry_id, worker_id, lease_token, result_attrs \\ %{})

  def complete_for_worker(entry_id, worker_id, lease_token, result_attrs)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) and
             is_map(result_attrs) do
    payload = Map.get(result_attrs, :result_payload) || Map.get(result_attrs, "result_payload")
    now = DateTime.utc_now()

    {updated_count, _} =
      owned_active_query(entry_id, worker_id, lease_token)
      |> Repo.update_all(
        set: [
          status: "completed",
          result_payload: encode_payload(payload),
          completed_at: now,
          last_heartbeat_at: now,
          updated_at: now
        ]
      )

    case updated_count do
      1 ->
        updated = Repo.get!(Entry, entry_id)

        broadcast(
          {:completed, updated.id, updated.issue_id, decode_payload(updated.result_payload)}
        )

        {:ok, updated}

      _ ->
        worker_transition_error(entry_id, worker_id, lease_token)
    end
  end

  def complete_for_worker(_entry_id, _worker_id, _lease_token, _result_attrs),
    do: {:error, :invalid_arguments}

  # --- Fail ---

  @spec fail(integer(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def fail(entry_id, error_message) do
    now = DateTime.utc_now()

    {updated_count, _} =
      Entry
      |> where([e], e.id == ^entry_id and e.status in ["claimed", "running"])
      |> Repo.update_all(
        set: [status: "failed", error: error_message, completed_at: now, updated_at: now]
      )

    case updated_count do
      1 ->
        updated = Repo.get!(Entry, entry_id)
        broadcast({:failed, updated.id, updated.issue_id, error_message})
        {:ok, updated}

      _ ->
        ownership_error(entry_id)
    end
  end

  @spec fail_for_worker(integer(), String.t(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def fail_for_worker(entry_id, worker_id, lease_token, error_message)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) and
             is_binary(error_message) do
    now = DateTime.utc_now()

    {updated_count, _} =
      owned_active_query(entry_id, worker_id, lease_token)
      |> Repo.update_all(
        set: [
          status: "failed",
          error: error_message,
          completed_at: now,
          last_heartbeat_at: now,
          updated_at: now
        ]
      )

    case updated_count do
      1 ->
        updated = Repo.get!(Entry, entry_id)
        broadcast({:failed, updated.id, updated.issue_id, error_message})
        {:ok, updated}

      _ ->
        worker_transition_error(entry_id, worker_id, lease_token)
    end
  end

  def fail_for_worker(_entry_id, _worker_id, _lease_token, _error_message),
    do: {:error, :invalid_arguments}

  @doc "Marks running queue entries owned by one worker node as failed."
  @spec fail_running_for_node(String.t(), String.t()) :: non_neg_integer()
  def fail_running_for_node(node_id, error_message)
      when is_binary(node_id) and is_binary(error_message) do
    entry_ids =
      Entry
      |> where([e], e.status == "running")
      |> where([e], e.claimed_by_node == ^node_id)
      |> select([e], e.id)
      |> Repo.all()

    Enum.reduce(entry_ids, 0, fn entry_id, acc ->
      case fail(entry_id, error_message) do
        {:ok, _entry} -> acc + 1
        _other -> acc
      end
    end)
  end

  # --- Cancel ---

  @spec cancel(integer(), String.t() | nil) :: {:ok, Entry.t()} | {:error, term()}
  def cancel(entry_id, reason \\ nil)

  def cancel(entry_id, reason)
      when is_integer(entry_id) and (is_binary(reason) or is_nil(reason)) do
    now = DateTime.utc_now()

    case Repo.get(Entry, entry_id) do
      nil ->
        {:error, :not_found}

      %Entry{status: "pending"} ->
        {updated_count, _} =
          Entry
          |> where([e], e.id == ^entry_id and e.status == "pending")
          |> Repo.update_all(
            set: [
              status: "cancelled",
              cancel_requested_at: now,
              cancel_reason: reason,
              completed_at: now,
              lease_token: nil,
              last_heartbeat_at: nil,
              updated_at: now
            ]
          )

        case updated_count do
          1 ->
            updated = Repo.get!(Entry, entry_id)
            broadcast({:cancelled, updated.id, updated.issue_id, updated.cancel_reason})
            {:ok, updated}

          _ ->
            ownership_error(entry_id)
        end

      %Entry{status: status} when status in ["claimed", "running"] ->
        {updated_count, _} =
          Entry
          |> where([e], e.id == ^entry_id and e.status in ["claimed", "running"])
          |> Repo.update_all(
            set: [
              status: "cancel_requested",
              cancel_requested_at: now,
              cancel_reason: reason,
              updated_at: now
            ]
          )

        case updated_count do
          1 ->
            updated = Repo.get!(Entry, entry_id)
            broadcast({:cancel_requested, updated.id, updated.issue_id, updated.cancel_reason})
            {:ok, updated}

          _ ->
            ownership_error(entry_id)
        end

      %Entry{} = entry ->
        {:ok, entry}
    end
  end

  def cancel(_entry_id, _reason), do: {:error, :invalid_arguments}

  @spec heartbeat_for_worker(integer(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def heartbeat_for_worker(entry_id, worker_id, lease_token)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) do
    now = DateTime.utc_now()

    {updated_count, _} =
      owned_active_query(entry_id, worker_id, lease_token)
      |> Repo.update_all(set: [last_heartbeat_at: now, updated_at: now])

    case updated_count do
      1 -> {:ok, Repo.get!(Entry, entry_id)}
      _ -> worker_transition_error(entry_id, worker_id, lease_token)
    end
  end

  def heartbeat_for_worker(_entry_id, _worker_id, _lease_token), do: {:error, :invalid_arguments}

  @spec get_for_worker(integer(), String.t(), String.t()) :: Entry.t() | nil
  def get_for_worker(entry_id, worker_id, lease_token)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) do
    Entry
    |> where(
      [e],
      e.id == ^entry_id and e.claimed_by_node == ^worker_id and e.lease_token == ^lease_token
    )
    |> where([e], e.status in ["claimed", "running"])
    |> Repo.one()
  end

  def get_for_worker(_entry_id, _worker_id, _lease_token), do: nil

  @spec get_owned_entry(integer(), String.t(), String.t()) :: Entry.t() | nil
  def get_owned_entry(entry_id, worker_id, lease_token)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) do
    Entry
    |> where(
      [e],
      e.id == ^entry_id and e.claimed_by_node == ^worker_id and e.lease_token == ^lease_token
    )
    |> Repo.one()
  end

  def get_owned_entry(_entry_id, _worker_id, _lease_token), do: nil

  @spec cancel_ack_for_worker(integer(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def cancel_ack_for_worker(entry_id, worker_id, lease_token)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) do
    now = DateTime.utc_now()

    {updated_count, _} =
      Entry
      |> where(
        [e],
        e.id == ^entry_id and e.claimed_by_node == ^worker_id and e.lease_token == ^lease_token and
          e.status == "cancel_requested"
      )
      |> Repo.update_all(
        set: [
          status: "cancelled",
          completed_at: now,
          last_heartbeat_at: nil,
          lease_token: nil,
          updated_at: now
        ]
      )

    case updated_count do
      1 ->
        updated = Repo.get!(Entry, entry_id)
        broadcast({:cancelled, updated.id, updated.issue_id, updated.cancel_reason})
        {:ok, updated}

      _ ->
        worker_transition_error(entry_id, worker_id, lease_token)
    end
  end

  def cancel_ack_for_worker(_entry_id, _worker_id, _lease_token), do: {:error, :invalid_arguments}

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
    |> where([e], e.status in ["pending", "claimed", "running", "cancel_requested"])
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
    now = DateTime.utc_now()

    {requeue_count, _} =
      Entry
      |> where([e], e.status in ["claimed", "running"])
      |> where(
        [e],
        (not is_nil(e.last_heartbeat_at) and e.last_heartbeat_at < ^cutoff) or
          (is_nil(e.last_heartbeat_at) and not is_nil(e.claimed_at) and e.claimed_at < ^cutoff)
      )
      |> Repo.update_all(
        set: [
          status: "pending",
          claimed_by_node: nil,
          lease_token: nil,
          claimed_at: nil,
          last_heartbeat_at: nil,
          started_at: nil,
          cancel_requested_at: nil,
          cancel_reason: nil,
          updated_at: now
        ]
      )

    {cancel_count, _} =
      Entry
      |> where([e], e.status == "cancel_requested")
      |> where(
        [e],
        (not is_nil(e.last_heartbeat_at) and e.last_heartbeat_at < ^cutoff) or
          (is_nil(e.last_heartbeat_at) and not is_nil(e.claimed_at) and e.claimed_at < ^cutoff)
      )
      |> Repo.update_all(
        set: [
          status: "cancelled",
          completed_at: now,
          last_heartbeat_at: nil,
          lease_token: nil,
          updated_at: now
        ]
      )

    count = requeue_count + cancel_count

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

  defp owned_active_query(entry_id, worker_id, lease_token) do
    Entry
    |> where(
      [e],
      e.id == ^entry_id and e.claimed_by_node == ^worker_id and e.lease_token == ^lease_token
    )
    |> where([e], e.status in ["claimed", "running"])
  end

  defp worker_transition_error(entry_id, worker_id, lease_token) do
    case get_owned_entry(entry_id, worker_id, lease_token) do
      nil -> ownership_error(entry_id)
      %Entry{status: "cancel_requested"} -> {:error, :cancel_requested}
      %Entry{} -> {:error, :conflict}
    end
  end

  defp ownership_error(entry_id) do
    case Repo.get(Entry, entry_id) do
      nil -> {:error, :not_found}
      _entry -> {:error, :conflict}
    end
  end
end

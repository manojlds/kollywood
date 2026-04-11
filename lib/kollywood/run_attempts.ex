defmodule Kollywood.RunAttempts do
  @moduledoc """
  Canonical boundary for durable run attempts.

  This is the canonical orchestration boundary for durable run attempts.
  """

  alias Kollywood.RunAttempts.Attempt
  alias Kollywood.RunQueue

  @type t :: Attempt.t()

  def subscribe, do: RunQueue.subscribe()

  def enqueue_attempt(attrs), do: RunQueue.enqueue(attrs)

  def lease_next(worker_id), do: RunQueue.claim(worker_id)
  def lease_batch(worker_id, count), do: RunQueue.claim_batch(worker_id, count)

  def start_attempt(entry_id, worker_id, lease_token),
    do: RunQueue.mark_running_for_worker(entry_id, worker_id, lease_token)

  def heartbeat_attempt(entry_id, worker_id, lease_token),
    do: RunQueue.heartbeat_for_worker(entry_id, worker_id, lease_token)

  def complete_attempt(entry_id, worker_id, lease_token, result_payload),
    do:
      RunQueue.complete_for_worker(entry_id, worker_id, lease_token, %{
        result_payload: result_payload
      })

  def fail_attempt(entry_id, worker_id, lease_token, error_message),
    do: RunQueue.fail_for_worker(entry_id, worker_id, lease_token, error_message)

  def request_cancel(entry_id, reason \\ nil), do: RunQueue.cancel(entry_id, reason)

  def acknowledge_cancel(entry_id, worker_id, lease_token),
    do: RunQueue.cancel_ack_for_worker(entry_id, worker_id, lease_token)

  def get_attempt(entry_id), do: RunQueue.get(entry_id)

  def get_owned_attempt(entry_id, worker_id, lease_token),
    do: RunQueue.get_owned_entry(entry_id, worker_id, lease_token)

  def get_active_for_worker(entry_id, worker_id, lease_token),
    do: RunQueue.get_for_worker(entry_id, worker_id, lease_token)

  def get_active_for_issue(issue_id), do: RunQueue.get_by_issue(issue_id)

  def recover_orphaned_running_for_worker(worker_id, error_message),
    do: RunQueue.fail_running_for_node(worker_id, error_message)

  def reclaim_stale_attempts(threshold_ms \\ 600_000), do: RunQueue.reclaim_stale(threshold_ms)

  def list_by_status(statuses), do: RunQueue.list_by_status(statuses)
  def list_recent(limit \\ 10), do: RunQueue.list_recent(limit)
  def stats, do: RunQueue.queue_overview_stats()
end

defmodule Kollywood.RunAttempts do
  @moduledoc """
  Canonical boundary for durable run attempts.

  This is the canonical orchestration boundary for durable run attempts.
  """

  alias Kollywood.RunAttempts.Attempt
  alias Kollywood.RunAttempts.Store

  @type t :: Attempt.t()

  def subscribe, do: Store.subscribe()

  def enqueue(attrs), do: Store.enqueue(attrs)

  def lease_next(worker_id), do: Store.lease_next(worker_id)
  def lease_batch(worker_id, count), do: Store.lease_batch(worker_id, count)

  def start_attempt(entry_id), do: Store.start_leased_attempt(entry_id)

  def start_attempt(entry_id, worker_id, lease_token),
    do: Store.start_attempt(entry_id, worker_id, lease_token)

  def complete_attempt(entry_id, result_payload) when is_map(result_payload),
    do: Store.complete_locally(entry_id, %{result_payload: result_payload})

  def complete_attempt(entry_id, result_payload),
    do: Store.complete_locally(entry_id, %{result_payload: result_payload})

  def heartbeat_attempt(entry_id, worker_id, lease_token),
    do: Store.heartbeat_attempt(entry_id, worker_id, lease_token)

  def complete_attempt(entry_id, worker_id, lease_token, result_payload),
    do:
      Store.complete_attempt(entry_id, worker_id, lease_token, %{
        result_payload: result_payload
      })

  def fail_attempt(entry_id, worker_id, lease_token, error_message),
    do: Store.fail_attempt(entry_id, worker_id, lease_token, error_message)

  def fail_attempt(entry_id, error_message), do: Store.fail_locally(entry_id, error_message)

  def request_cancel(entry_id, reason \\ nil), do: Store.request_cancel(entry_id, reason)

  def acknowledge_cancel(entry_id, worker_id, lease_token),
    do: Store.acknowledge_cancel(entry_id, worker_id, lease_token)

  def get_attempt(entry_id), do: Store.get(entry_id)

  def get_owned_attempt(entry_id, worker_id, lease_token),
    do: Store.get_owned_attempt(entry_id, worker_id, lease_token)

  def get_active_for_worker(entry_id, worker_id, lease_token),
    do: Store.get_active_for_worker(entry_id, worker_id, lease_token)

  def get_active_for_issue(issue_id), do: Store.get_active_for_issue(issue_id)

  def list_queued, do: Store.list_queued()
  def queued_count, do: Store.queued_count()

  def recover_orphaned_running_for_worker(worker_id, error_message),
    do: Store.fail_running_for_worker(worker_id, error_message)

  def reclaim_stale_attempts(threshold_ms \\ 600_000),
    do: Store.reclaim_stale_attempts(threshold_ms)

  def list_by_status(statuses), do: Store.list_by_status(statuses)
  def list_recent(limit \\ 10), do: Store.list_recent(limit)
  def stats, do: Store.attempt_overview_stats()
end

defmodule KollywoodWeb.InternalWorkerController do
  use KollywoodWeb, :controller

  alias Kollywood.RunQueue

  def lease_next(conn, params) do
    with {:ok, worker_id} <- require_string(params, "worker_id"),
         {:ok, limit} <- parse_limit(Map.get(params, "limit")) do
      entries = RunQueue.claim_batch(worker_id, limit)

      json(conn, %{
        data: %{
          entries: Enum.map(entries, &entry_payload/1)
        }
      })
    else
      {:error, reason} -> error_response(conn, :unprocessable_entity, reason)
    end
  end

  def start(conn, %{"id" => id} = params) do
    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, worker_id} <- require_string(params, "worker_id"),
         {:ok, _entry} <- RunQueue.mark_running_for_worker(entry_id, worker_id) do
      json(conn, %{data: %{ok: true}})
    else
      {:error, reason} -> error_response(conn, status_for_reason(reason), error_message(reason))
    end
  end

  def heartbeat(conn, %{"id" => id} = params) do
    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, worker_id} <- require_string(params, "worker_id"),
         {:ok, _entry} <- RunQueue.heartbeat_for_worker(entry_id, worker_id) do
      json(conn, %{data: %{ok: true}})
    else
      {:error, reason} -> error_response(conn, status_for_reason(reason), error_message(reason))
    end
  end

  def events(conn, %{"id" => id} = params) do
    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, worker_id} <- require_string(params, "worker_id"),
         {:ok, issue_id} <- require_string(params, "issue_id"),
         {:ok, event} <- require_map(params, "event"),
         entry when not is_nil(entry) <- RunQueue.get_for_worker(entry_id, worker_id) do
      if entry.issue_id == issue_id do
        maybe_forward_runner_event(issue_id, event)
        json(conn, %{data: %{ok: true}})
      else
        error_response(conn, :conflict, "issue_id does not match leased run")
      end
    else
      nil -> error_response(conn, :conflict, "run is not leased by this worker")
      {:error, reason} -> error_response(conn, status_for_reason(reason), error_message(reason))
    end
  end

  def complete(conn, %{"id" => id} = params) do
    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, worker_id} <- require_string(params, "worker_id"),
         {:ok, result_payload} <- require_map(params, "result_payload"),
         {:ok, _entry} <-
           RunQueue.complete_for_worker(entry_id, worker_id, %{result_payload: result_payload}) do
      json(conn, %{data: %{ok: true}})
    else
      {:error, reason} -> error_response(conn, status_for_reason(reason), error_message(reason))
    end
  end

  def fail(conn, %{"id" => id} = params) do
    with {:ok, entry_id} <- parse_entry_id(id),
         {:ok, worker_id} <- require_string(params, "worker_id"),
         {:ok, error_message} <- require_string(params, "error"),
         {:ok, _entry} <- RunQueue.fail_for_worker(entry_id, worker_id, error_message) do
      json(conn, %{data: %{ok: true}})
    else
      {:error, reason} -> error_response(conn, status_for_reason(reason), error_message(reason))
    end
  end

  defp maybe_forward_runner_event(issue_id, event) do
    case Process.whereis(Kollywood.Orchestrator) do
      pid when is_pid(pid) -> send(pid, {:runner_event, issue_id, event})
      _other -> :ok
    end
  end

  defp entry_payload(entry) do
    %{
      id: entry.id,
      issue_id: entry.issue_id,
      identifier: entry.identifier,
      project_slug: entry.project_slug,
      attempt: entry.attempt,
      config_snapshot: entry.config_snapshot,
      run_opts_snapshot: entry.run_opts_snapshot
    }
  end

  defp require_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "#{key} is required"}
    end
  end

  defp require_map(params, key) do
    case Map.get(params, key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, "#{key} must be an object"}
    end
  end

  defp parse_entry_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_entry_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {value, ""} when value > 0 -> {:ok, value}
      _other -> {:error, "id must be a positive integer"}
    end
  end

  defp parse_entry_id(_id), do: {:error, "id must be a positive integer"}

  defp parse_limit(nil), do: {:ok, 1}
  defp parse_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, min(limit, 20)}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {value, ""} when value > 0 -> {:ok, min(value, 20)}
      _other -> {:error, "limit must be a positive integer"}
    end
  end

  defp parse_limit(_limit), do: {:error, "limit must be a positive integer"}

  defp status_for_reason(:not_found), do: :not_found
  defp status_for_reason(:conflict), do: :conflict
  defp status_for_reason(:invalid_arguments), do: :unprocessable_entity
  defp status_for_reason(_reason), do: :unprocessable_entity

  defp error_message(:not_found), do: "run not found"
  defp error_message(:conflict), do: "run is not leased by this worker"
  defp error_message(:invalid_arguments), do: "invalid request"
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  defp error_response(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: reason})
  end
end

defmodule Kollywood.WorkerConsumer do
  @moduledoc """
  Pulls work from the RunQueue and executes it via the local AgentPool.

  This process runs on worker nodes (`:worker`, `:orchestrator`, `:all` modes).
  It polls the queue for pending entries, claims them, spawns RunWorkers, and
  writes results back to the queue + PubSub.

  The consumer self-throttles based on the number of active local workers
  vs. a configured concurrency limit.
  """

  use GenServer
  require Logger

  alias Kollywood.AgentPool
  alias Kollywood.AgentRunner
  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.RunQueue

  @default_poll_interval_ms 2_000
  @default_max_local_workers 2
  @default_stale_reclaim_interval_ms 120_000

  defstruct [
    :agent_pool,
    :poll_timer_ref,
    :stale_reclaim_timer_ref,
    :node_id,
    poll_interval_ms: @default_poll_interval_ms,
    max_local_workers: @default_max_local_workers,
    stale_reclaim_interval_ms: @default_stale_reclaim_interval_ms,
    active_workers: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    worker_id = Keyword.get(opts, :worker_id, 1)

    %{
      id: {__MODULE__, worker_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    node_id = Keyword.get(opts, :node_id, node_identifier())

    state = %__MODULE__{
      agent_pool: Keyword.get(opts, :agent_pool, AgentPool),
      poll_interval_ms:
        pos_int(Keyword.get(opts, :poll_interval_ms), @default_poll_interval_ms),
      max_local_workers:
        pos_int(Keyword.get(opts, :max_local_workers), @default_max_local_workers),
      stale_reclaim_interval_ms:
        pos_int(Keyword.get(opts, :stale_reclaim_interval_ms), @default_stale_reclaim_interval_ms),
      node_id: node_id,
      active_workers: %{}
    }

    RunQueue.subscribe()

    state =
      state
      |> schedule_poll(0)
      |> schedule_stale_reclaim()

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      node_id: state.node_id,
      active_workers: map_size(state.active_workers),
      max_local_workers: state.max_local_workers,
      available_slots: max(state.max_local_workers - map_size(state.active_workers), 0)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = try_claim_and_run(state)
    state = schedule_poll(state)
    {:noreply, state}
  end

  def handle_info(:reclaim_stale, state) do
    reclaimed = RunQueue.reclaim_stale()

    if reclaimed > 0 do
      Logger.info("WorkerConsumer reclaimed #{reclaimed} stale queue entries")
    end

    state = schedule_stale_reclaim(state)
    {:noreply, state}
  end

  def handle_info({:run_queue, {:enqueued, _id, _issue_id}}, state) do
    state = try_claim_and_run(state)
    {:noreply, state}
  end

  def handle_info({:run_queue, _event}, state) do
    {:noreply, state}
  end

  def handle_info({:worker_done, entry_id, worker_pid, result}, state) do
    case Map.pop(state.active_workers, entry_id) do
      {%{worker_pid: ^worker_pid, monitor_ref: ref}, active_workers} ->
        Process.demonitor(ref, [:flush])
        state = %{state | active_workers: active_workers}
        handle_worker_result(state, entry_id, result)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_worker_by_ref(state, ref) do
      {entry_id, %{worker_pid: ^pid}} ->
        active_workers = Map.delete(state.active_workers, entry_id)
        state = %{state | active_workers: active_workers}

        error_msg = "Worker process exited: #{inspect(reason)}"
        RunQueue.fail(entry_id, error_msg)

        Logger.warning("WorkerConsumer: worker for entry #{entry_id} crashed: #{error_msg}")

        state = try_claim_and_run(state)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # --- Core logic ---

  defp try_claim_and_run(state) do
    available_slots = max(state.max_local_workers - map_size(state.active_workers), 0)

    if available_slots == 0 do
      state
    else
      entries = RunQueue.claim_batch(state.node_id, available_slots)

      Enum.reduce(entries, state, fn entry, acc ->
        start_worker_for_entry(acc, entry)
      end)
    end
  end

  defp start_worker_for_entry(state, entry) do
    entry_id = entry.id
    issue_id = entry.issue_id
    consumer_pid = self()

    run_fun = fn ->
      run_opts = decode_run_opts(entry)
      issue = decode_issue_from_entry(entry)
      run_opts = inject_on_event(run_opts, issue_id, entry.attempt)

      RunQueue.mark_running(entry_id)

      case invoke_runner(issue, run_opts) do
        {:ok, _result} = ok ->
          send(consumer_pid, {:worker_done, entry_id, self(), ok})

        {:error, _result} = err ->
          send(consumer_pid, {:worker_done, entry_id, self(), err})
      end
    end

    case AgentPool.start_run(state.agent_pool,
           orchestrator: consumer_pid,
           issue_id: issue_id,
           run_fun: run_fun
         ) do
      {:ok, worker_pid} ->
        monitor_ref = Process.monitor(worker_pid)

        worker_entry = %{
          worker_pid: worker_pid,
          monitor_ref: monitor_ref,
          issue_id: issue_id,
          started_at: DateTime.utc_now()
        }

        %{state | active_workers: Map.put(state.active_workers, entry_id, worker_entry)}

      {:ok, worker_pid, _info} ->
        monitor_ref = Process.monitor(worker_pid)

        worker_entry = %{
          worker_pid: worker_pid,
          monitor_ref: monitor_ref,
          issue_id: issue_id,
          started_at: DateTime.utc_now()
        }

        %{state | active_workers: Map.put(state.active_workers, entry_id, worker_entry)}

      error ->
        Logger.error("WorkerConsumer: failed to start worker for entry #{entry_id}: #{inspect(error)}")
        RunQueue.fail(entry_id, "failed to start worker: #{inspect(error)}")
        state
    end
  end

  defp handle_worker_result(state, entry_id, {:ok, result}) do
    result_payload = serialize_result(result)
    RunQueue.complete(entry_id, %{result_payload: result_payload})

    state = try_claim_and_run(state)
    {:noreply, state}
  end

  defp handle_worker_result(state, entry_id, {:error, result}) do
    error_msg =
      cond do
        is_map(result) and Map.has_key?(result, :error) -> to_string(result.error)
        is_binary(result) -> result
        true -> inspect(result)
      end

    RunQueue.fail(entry_id, error_msg)

    state = try_claim_and_run(state)
    {:noreply, state}
  end

  # --- Serialization helpers ---

  defp decode_run_opts(entry) do
    case entry.run_opts_snapshot do
      nil -> []
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> opts_from_map(map)
          _ -> []
        end
    end
  end

  @known_run_opt_keys ~w(
    config story_overrides_resolved run_settings_snapshot attempt
    session_opts continuation log_files mode turn_limit
  )

  defp opts_from_map(map) do
    Enum.reduce(map, [], fn {key, value}, acc ->
      if key in @known_run_opt_keys do
        atom_key = String.to_existing_atom(key)
        resolved_value = resolve_opt_value(atom_key, value)
        [{atom_key, resolved_value} | acc]
      else
        acc
      end
    end)
  end

  defp resolve_opt_value(:config, value) when is_map(value) do
    Config.from_serialized_map(value)
  end

  defp resolve_opt_value(:story_overrides_resolved, value) do
    value == true or value == "true"
  end

  defp resolve_opt_value(_key, value), do: value

  defp decode_issue_from_entry(entry) do
    config_snapshot = entry.config_snapshot

    base = %{
      "id" => entry.issue_id,
      "identifier" => entry.identifier
    }

    case config_snapshot do
      nil ->
        base

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"issue" => issue}} when is_map(issue) -> issue
          _ -> base
        end
    end
  end

  defp inject_on_event(run_opts, issue_id, attempt) do
    log_files = Keyword.get(run_opts, :log_files)

    run_log_context =
      if is_map(log_files) do
        attempt_int =
          case attempt do
            n when is_integer(n) -> n
            s when is_binary(s) -> String.to_integer(s)
            _ -> 0
          end

        attempt_dir =
          case Map.get(log_files, :events) || Map.get(log_files, "events") do
            path when is_binary(path) -> Path.dirname(path)
            _ -> nil
          end

        files =
          Map.new(log_files, fn {k, v} ->
            {if(is_atom(k), do: k, else: String.to_atom(k)), v}
          end)

        %{issue_id: issue_id, attempt: attempt_int, attempt_dir: attempt_dir, files: files}
      end

    on_event = fn event ->
      if run_log_context, do: RunLogs.append_event(run_log_context, event)

      Phoenix.PubSub.broadcast(
        Kollywood.PubSub,
        "orchestrator:events",
        {:runner_event, issue_id, event}
      )
    end

    Keyword.put(run_opts, :on_event, on_event)
  end

  defp invoke_runner(issue, run_opts) do
    AgentRunner.run_issue(issue, run_opts)
  end

  defp serialize_result(result) when is_map(result) do
    safe =
      result
      |> Map.from_struct()
      |> Map.drop([:__struct__])
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), serializable_value(v)} end)

    case Jason.encode(safe) do
      {:ok, json} -> json
      {:error, _} -> inspect(result)
    end
  rescue
    _ -> inspect(result)
  end

  defp serialize_result(result), do: inspect(result)

  defp serializable_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serializable_value(value) when is_pid(value), do: inspect(value)
  defp serializable_value(value) when is_reference(value), do: inspect(value)
  defp serializable_value(value) when is_function(value), do: nil
  defp serializable_value(value) when is_map(value) do
    Enum.into(value, %{}, fn {k, v} -> {to_string(k), serializable_value(v)} end)
  rescue
    _ -> inspect(value)
  end
  defp serializable_value(value) when is_list(value) do
    Enum.map(value, &serializable_value/1)
  end
  defp serializable_value(value), do: value

  # --- Scheduling ---

  defp schedule_poll(state, delay \\ nil) do
    if state.poll_timer_ref, do: Process.cancel_timer(state.poll_timer_ref)
    ref = Process.send_after(self(), :poll, delay || state.poll_interval_ms)
    %{state | poll_timer_ref: ref}
  end

  defp schedule_stale_reclaim(state) do
    if state.stale_reclaim_timer_ref, do: Process.cancel_timer(state.stale_reclaim_timer_ref)
    ref = Process.send_after(self(), :reclaim_stale, state.stale_reclaim_interval_ms)
    %{state | stale_reclaim_timer_ref: ref}
  end

  # --- Helpers ---

  defp find_worker_by_ref(state, ref) do
    Enum.find(state.active_workers, fn {_entry_id, worker} ->
      worker.monitor_ref == ref
    end)
  end

  defp node_identifier do
    node_name = Atom.to_string(node())

    if node_name == "nonode@nohost" do
      "local-#{:erlang.system_info(:scheduler_id)}-#{:os.getpid()}"
    else
      node_name
    end
  end

  defp pos_int(value, _default) when is_integer(value) and value > 0, do: value
  defp pos_int(_, default), do: default
end

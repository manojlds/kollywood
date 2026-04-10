defmodule Kollywood.WorkerNode do
  @moduledoc """
  Remote worker node process.

  It leases queue entries from the control plane over HTTP, executes them via
  the local AgentPool, heartbeats active runs, and reports results back.
  """

  use GenServer
  require Logger

  alias Kollywood.AgentPool
  alias Kollywood.AgentRunner
  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Worker.ControlPlaneClient

  @default_poll_interval_ms 2_000
  @default_heartbeat_interval_ms 5_000
  @default_max_local_workers 2

  defstruct [
    :agent_pool,
    :control_plane,
    :poll_timer_ref,
    :heartbeat_timer_ref,
    :worker_id,
    :started_at,
    :last_seen_at,
    :last_poll_at,
    poll_interval_ms: @default_poll_interval_ms,
    heartbeat_interval_ms: @default_heartbeat_interval_ms,
    max_local_workers: @default_max_local_workers,
    active_workers: %{},
    poll_count: 0,
    lease_attempts: 0,
    leases_succeeded: 0
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

  @impl true
  def init(opts) do
    now = DateTime.utc_now()

    state = %__MODULE__{
      agent_pool: Keyword.get(opts, :agent_pool, AgentPool),
      control_plane:
        ControlPlaneClient.new(
          base_url: Keyword.get(opts, :control_plane_url),
          token: Keyword.get(opts, :internal_api_token)
        ),
      worker_id: normalize_worker_id(Keyword.get(opts, :worker_id)),
      poll_interval_ms: pos_int(Keyword.get(opts, :poll_interval_ms), @default_poll_interval_ms),
      heartbeat_interval_ms:
        pos_int(
          Keyword.get(opts, :heartbeat_interval_ms),
          @default_heartbeat_interval_ms
        ),
      max_local_workers:
        pos_int(Keyword.get(opts, :max_local_workers), @default_max_local_workers),
      active_workers: %{},
      started_at: now,
      last_seen_at: now,
      poll_count: 0,
      lease_attempts: 0,
      leases_succeeded: 0
    }

    state = state |> schedule_poll(0) |> schedule_heartbeat()
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    uptime_ms =
      case state.started_at do
        %DateTime{} = started_at -> DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
        _ -> nil
      end

    reply = %{
      worker_id: state.worker_id,
      active_workers: map_size(state.active_workers),
      max_local_workers: state.max_local_workers,
      available_slots: max(state.max_local_workers - map_size(state.active_workers), 0),
      poll_interval_ms: state.poll_interval_ms,
      heartbeat_interval_ms: state.heartbeat_interval_ms,
      poll_count: state.poll_count,
      lease_attempts: state.lease_attempts,
      leases_succeeded: state.leases_succeeded,
      started_at: state.started_at,
      last_seen_at: state.last_seen_at,
      last_poll_at: state.last_poll_at,
      uptime_ms: uptime_ms,
      active_runs: Map.values(state.active_workers)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    now = DateTime.utc_now()
    state = %{state | last_poll_at: now, last_seen_at: now, poll_count: state.poll_count + 1}
    state = lease_and_run(state)
    {:noreply, schedule_poll(state)}
  end

  def handle_info(:heartbeat, state) do
    state = heartbeat_active_runs(state)
    {:noreply, schedule_heartbeat(state)}
  end

  def handle_info({:run_worker_result, _issue_id, worker_pid, result}, state) do
    case find_worker_by_pid(state, worker_pid) do
      {entry_id, _worker} -> handle_info({:worker_done, entry_id, worker_pid, result}, state)
      nil -> {:noreply, touch_seen(state)}
    end
  end

  def handle_info({:worker_done, entry_id, worker_pid, result}, state) do
    state = touch_seen(state)

    case Map.pop(state.active_workers, entry_id) do
      {%{worker_pid: ^worker_pid, monitor_ref: ref}, active_workers} ->
        Process.demonitor(ref, [:flush])
        state = %{state | active_workers: active_workers}
        {:noreply, handle_worker_result(state, entry_id, result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    state = touch_seen(state)

    case find_worker_by_ref(state, ref) do
      {entry_id, %{worker_pid: ^pid}} ->
        active_workers = Map.delete(state.active_workers, entry_id)
        state = %{state | active_workers: active_workers}
        error_msg = "Worker process exited: #{inspect(reason)}"
        maybe_fail_remote_run(state, entry_id, error_msg)
        {:noreply, lease_and_run(state)}

      _ ->
        {:noreply, state}
    end
  end

  defp lease_and_run(state) do
    available_slots = max(state.max_local_workers - map_size(state.active_workers), 0)

    if available_slots == 0 do
      state
    else
      state = %{state | lease_attempts: state.lease_attempts + available_slots}

      case ControlPlaneClient.lease_next(state.control_plane, state.worker_id, available_slots) do
        {:ok, entries} ->
          state = %{state | leases_succeeded: state.leases_succeeded + length(entries)}
          Enum.reduce(entries, state, &start_worker_for_entry(&2, &1))

        {:error, reason} ->
          Logger.warning("WorkerNode failed to lease work from control plane: #{inspect(reason)}")
          state
      end
    end
  end

  defp start_worker_for_entry(state, entry) do
    entry_id = entry_field(entry, :id)
    issue_id = entry_field(entry, :issue_id)
    identifier = entry_field(entry, :identifier) || issue_id
    consumer_pid = self()
    control_plane = state.control_plane
    worker_id = state.worker_id

    run_fun = fn ->
      case ControlPlaneClient.start_run(control_plane, entry_id, worker_id) do
        :ok ->
          run_opts = decode_run_opts(entry)
          issue = decode_issue_from_entry(entry)
          attempt = entry_field(entry, :attempt)

          run_opts =
            inject_on_event(
              run_opts,
              control_plane,
              entry_id,
              worker_id,
              issue_id,
              attempt,
              identifier
            )

          case invoke_runner(issue, run_opts) do
            {:ok, _result} = ok ->
              send(consumer_pid, {:worker_done, entry_id, self(), ok})

            {:error, _result} = err ->
              send(consumer_pid, {:worker_done, entry_id, self(), err})
          end

        {:error, reason} ->
          send(
            consumer_pid,
            {:worker_done, entry_id, self(),
             {:error, %{error: "failed to start leased run: #{inspect(reason)}"}}}
          )
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
          queue_entry_id: entry_id,
          issue_id: issue_id,
          identifier: identifier,
          attempt: entry_field(entry, :attempt),
          project_slug: entry_field(entry, :project_slug),
          worker_pid: worker_pid,
          monitor_ref: monitor_ref,
          started_at: DateTime.utc_now()
        }

        %{state | active_workers: Map.put(state.active_workers, entry_id, worker_entry)}

      {:ok, worker_pid, _info} ->
        monitor_ref = Process.monitor(worker_pid)

        worker_entry = %{
          queue_entry_id: entry_id,
          issue_id: issue_id,
          identifier: identifier,
          attempt: entry_field(entry, :attempt),
          project_slug: entry_field(entry, :project_slug),
          worker_pid: worker_pid,
          monitor_ref: monitor_ref,
          started_at: DateTime.utc_now()
        }

        %{state | active_workers: Map.put(state.active_workers, entry_id, worker_entry)}

      error ->
        Logger.error("WorkerNode failed to start worker for entry #{entry_id}: #{inspect(error)}")
        maybe_fail_remote_run(state, entry_id, "failed to start worker: #{inspect(error)}")
        state
    end
  end

  defp handle_worker_result(state, entry_id, {:ok, result}) do
    result_payload = serialize_result(result)

    case ControlPlaneClient.complete_run(
           state.control_plane,
           entry_id,
           state.worker_id,
           result_payload
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "WorkerNode failed to report completion for entry #{entry_id}: #{inspect(reason)}"
        )
    end

    lease_and_run(state)
  end

  defp handle_worker_result(state, entry_id, {:error, result}) do
    error_msg =
      cond do
        is_map(result) and Map.has_key?(result, :error) -> to_string(result.error)
        is_map(result) and Map.has_key?(result, "error") -> to_string(result["error"])
        is_binary(result) -> result
        true -> inspect(result)
      end

    maybe_fail_remote_run(state, entry_id, error_msg)
    lease_and_run(state)
  end

  defp maybe_fail_remote_run(state, entry_id, error_msg) do
    case ControlPlaneClient.fail_run(state.control_plane, entry_id, state.worker_id, error_msg) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "WorkerNode failed to report failure for entry #{entry_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp heartbeat_active_runs(state) do
    Enum.reduce(state.active_workers, touch_seen(state), fn {entry_id, worker}, acc ->
      case ControlPlaneClient.heartbeat_run(acc.control_plane, entry_id, acc.worker_id) do
        :ok ->
          acc

        {:error, {:conflict, _reason}} ->
          stop_lost_worker(acc, entry_id, worker)

        {:error, {:not_found, _reason}} ->
          stop_lost_worker(acc, entry_id, worker)

        {:error, {409, _reason}} ->
          stop_lost_worker(acc, entry_id, worker)

        {:error, {404, _reason}} ->
          stop_lost_worker(acc, entry_id, worker)

        {:error, reason} ->
          Logger.warning("WorkerNode heartbeat failed for entry #{entry_id}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp stop_lost_worker(state, entry_id, worker) do
    Logger.warning(
      "WorkerNode stopping local worker for entry #{entry_id} because the control plane no longer recognizes its lease"
    )

    _ = AgentPool.stop_run(state.agent_pool, worker.worker_pid)

    %{state | active_workers: Map.delete(state.active_workers, entry_id)}
  end

  defp decode_run_opts(entry) do
    case entry_field(entry, :run_opts_snapshot) do
      nil ->
        []

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> opts_from_map(map)
          _ -> []
        end
    end
  end

  @known_run_opt_keys ~w(
    config story_overrides_resolved run_settings_snapshot attempt
    session_opts continuation log_files mode turn_limit prompt_template
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

  defp resolve_opt_value(:config, value) when is_map(value), do: Config.from_serialized_map(value)
  defp resolve_opt_value(:story_overrides_resolved, value), do: value == true or value == "true"

  defp resolve_opt_value(:log_files, value) when is_map(value) do
    Map.new(value, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
    end)
  end

  defp resolve_opt_value(_key, value), do: value

  defp decode_issue_from_entry(entry) do
    base = %{
      "id" => entry_field(entry, :issue_id),
      "identifier" => entry_field(entry, :identifier)
    }

    case entry_field(entry, :config_snapshot) do
      nil ->
        base

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"issue" => issue}} when is_map(issue) -> issue
          _ -> base
        end
    end
  end

  defp inject_on_event(
         run_opts,
         control_plane,
         entry_id,
         worker_id,
         issue_id,
         attempt,
         identifier
       ) do
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

        %{
          issue_id: issue_id,
          identifier: identifier || issue_id,
          story_id: issue_id,
          attempt: attempt_int,
          attempt_dir: attempt_dir,
          files: files
        }
      end

    on_event = fn event ->
      if run_log_context do
        RunLogs.append_event(run_log_context, event)
      end

      case ControlPlaneClient.report_event(control_plane, entry_id, worker_id, issue_id, event) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("WorkerNode failed to report event for #{issue_id}: #{inspect(reason)}")
          :ok
      end
    end

    Keyword.put(run_opts, :on_event, on_event)
  end

  defp invoke_runner(issue, run_opts) do
    AgentRunner.run_issue(issue, run_opts)
  end

  defp serialize_result(result) when is_map(result) do
    safe =
      result
      |> maybe_from_struct()
      |> Map.drop([:__struct__])
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), serializable_value(v)} end)

    case Jason.encode(safe) do
      {:ok, json} -> Jason.decode!(json)
      {:error, _} -> %{"raw" => inspect(result)}
    end
  rescue
    _ -> %{"raw" => inspect(result)}
  end

  defp serialize_result(result), do: %{"raw" => inspect(result)}

  defp maybe_from_struct(%{__struct__: _} = value), do: Map.from_struct(value)
  defp maybe_from_struct(value), do: value

  defp serializable_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp serializable_value(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp serializable_value(value) when is_pid(value), do: inspect(value)
  defp serializable_value(value) when is_reference(value), do: inspect(value)
  defp serializable_value(value) when is_function(value), do: nil

  defp serializable_value(value) when is_map(value) do
    Enum.into(value, %{}, fn {k, v} -> {to_string(k), serializable_value(v)} end)
  rescue
    _ -> inspect(value)
  end

  defp serializable_value(value) when is_list(value), do: Enum.map(value, &serializable_value/1)
  defp serializable_value(value), do: value

  defp schedule_poll(state, delay \\ nil) do
    if state.poll_timer_ref, do: Process.cancel_timer(state.poll_timer_ref)
    ref = Process.send_after(self(), :poll, delay || state.poll_interval_ms)
    %{state | poll_timer_ref: ref}
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_timer_ref, do: Process.cancel_timer(state.heartbeat_timer_ref)
    ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)
    %{state | heartbeat_timer_ref: ref}
  end

  defp find_worker_by_ref(state, ref) do
    Enum.find(state.active_workers, fn {_entry_id, worker} ->
      worker.monitor_ref == ref
    end)
  end

  defp find_worker_by_pid(state, pid) do
    Enum.find(state.active_workers, fn {_entry_id, worker} ->
      worker.worker_pid == pid
    end)
  end

  defp touch_seen(state), do: %{state | last_seen_at: DateTime.utc_now()}

  defp worker_identifier do
    System.get_env("KOLLYWOOD_WORKER_ID") ||
      System.get_env("HOSTNAME") || local_worker_identifier()
  end

  defp normalize_worker_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> worker_identifier()
      trimmed -> trimmed
    end
  end

  defp normalize_worker_id(value) when is_integer(value) and value > 0 do
    "#{worker_identifier()}-#{value}"
  end

  defp normalize_worker_id(_value), do: worker_identifier()

  defp local_worker_identifier do
    node_name = Atom.to_string(node())

    if node_name == "nonode@nohost" do
      "worker-#{:os.getpid()}"
    else
      node_name
    end
  end

  defp entry_field(entry, key) when is_map(entry) and is_atom(key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp pos_int(value, _default) when is_integer(value) and value > 0, do: value
  defp pos_int(_, default), do: default
end

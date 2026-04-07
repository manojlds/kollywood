defmodule Kollywood.PreviewSessionManager do
  @moduledoc """
  Manages long-lived preview runtime sessions for pending_merge stories.

  Sessions are keyed by `{project_slug, story_id}` and own the runtime
  lifecycle (port offset lease, running processes). TTL-based expiry
  ensures resources are released even if the operator forgets to stop.

  Lifecycle:

    1. **Handoff** — `handoff_runtime/4` transfers an already-running runtime
       (e.g. from the testing phase) into a preview session without restarting
       services. The port offset lease is re-acquired under this process.

    2. **Cold start** — `start_preview/3` boots a fresh runtime from the
       project's WORKFLOW.md config and workspace path.

    3. **Stop** — `stop_preview/2` stops runtime processes, releases the
       port offset lease, and removes the session.

    4. **TTL tick** — A periodic timer checks for expired sessions and stops
       them automatically.
  """

  use GenServer

  require Logger

  alias Kollywood.Runtime
  alias Kollywood.Runtime.Broker
  alias Kollywood.RuntimeSessions

  @ttl_check_interval_ms 30_000
  @default_ttl_minutes 120

  @type session_key :: {String.t(), String.t()}
  @type session :: %{
          runtime_state: map(),
          runtime_kind: atom(),
          preview_url: String.t() | nil,
          resolved_ports: map(),
          started_at: DateTime.t(),
          expires_at: DateTime.t(),
          last_error: String.t() | nil,
          workspace_path: String.t() | nil,
          status: :starting | :running | :stopping | :failed | :stopped
        }

  # ── Public API ──────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts a fresh preview session for a story.

  `opts` must include:
    - `:config` — parsed `%Config{}`
    - `:workspace_path` — absolute path to the worktree
    - `:workspace_key` — worktree key (e.g. story identifier)
    - `:ttl_minutes` — optional override (default from preview config)
  """
  @spec start_preview(String.t(), String.t(), keyword()) ::
          {:ok, session()} | {:error, String.t()}
  def start_preview(project_slug, story_id, opts) do
    GenServer.call(__MODULE__, {:start_preview, project_slug, story_id, opts}, 180_000)
  end

  @doc """
  Stops and removes an active preview session.
  """
  @spec stop_preview(String.t(), String.t()) :: :ok | {:error, String.t()}
  def stop_preview(project_slug, story_id) do
    GenServer.call(__MODULE__, {:stop_preview, project_slug, story_id}, 120_000)
  end

  @doc """
  Transfers an already-running runtime into a preview session.

  The caller should skip its normal `Runtime.stop` / `Runtime.release`
  after a successful handoff.
  """
  @spec handoff_runtime(String.t(), String.t(), map(), keyword()) ::
          {:ok, session()} | {:error, String.t()}
  def handoff_runtime(project_slug, story_id, runtime_state, opts) do
    GenServer.call(
      __MODULE__,
      {:handoff_runtime, project_slug, story_id, runtime_state, opts},
      30_000
    )
  end

  @doc "Returns the session for a story, or nil."
  @spec get_session(String.t(), String.t()) :: session() | nil
  def get_session(project_slug, story_id) do
    GenServer.call(__MODULE__, {:get_session, project_slug, story_id})
  end

  @doc "Lists all active sessions."
  @spec list_sessions() :: [%{project: String.t(), story_id: String.t(), session: session()}]
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  @doc """
  Stops preview for a story if one is active. Safe to call even when
  no session exists (returns :ok).
  """
  @spec stop_if_active(String.t(), String.t()) :: :ok
  def stop_if_active(project_slug, story_id) do
    case get_session(project_slug, story_id) do
      nil -> :ok
      _session -> stop_preview(project_slug, story_id) |> normalize_stop_result()
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    restored_sessions = restore_sessions_from_db()
    schedule_ttl_check()
    {:ok, %{sessions: restored_sessions, start_refs: %{}}}
  end

  @impl true
  def handle_call({:start_preview, project_slug, story_id, opts}, _from, state) do
    key = {project_slug, story_id}

    case load_preview_session_from_db(project_slug, story_id) do
      %{status: status} = existing when status in [:running, :starting] ->
        {:reply, {:ok, existing}, state}

      _ ->
        runtime_state =
          case load_runtime_session_from_db(project_slug, story_id) do
            %{status: status, runtime_state: persisted_runtime}
            when status in [:running, :starting] and is_map(persisted_runtime) ->
              persisted_runtime

            _other ->
              %{}
          end

        session = build_starting_session(opts, runtime_state)
        ref = make_ref()
        launch_async_start(self(), key, opts, ref)
        persist_upsert(key, session, :preview)

        state =
          state
          |> put_session(key, session)
          |> put_start_ref(key, ref)

        {:reply, {:ok, session}, state}
    end
  end

  def handle_call({:stop_preview, project_slug, story_id}, _from, state) do
    key = {project_slug, story_id}

    case load_preview_session_from_db(project_slug, story_id) || Map.get(state.sessions, key) do
      nil ->
        {:reply, {:error, "no active preview session"}, state}

      session ->
        do_stop_session(session, key)
        persist_delete(key)

        state =
          state
          |> drop_session(key)
          |> clear_start_ref(key)

        {:reply, :ok, state}
    end
  end

  def handle_call({:handoff_runtime, project_slug, story_id, runtime_state, opts}, _from, state) do
    key = {project_slug, story_id}

    case load_preview_session_from_db(project_slug, story_id) do
      %{status: status} = existing when status in [:running, :starting] ->
        {:reply, {:ok, existing}, state}

      _ ->
        ttl_minutes = Keyword.get(opts, :ttl_minutes, @default_ttl_minutes)
        now = DateTime.utc_now()

        reacquired_state = reacquire_lease(runtime_state)

        session = %{
          runtime_state: reacquired_state,
          runtime_kind: Map.get(reacquired_state, :kind, :host),
          preview_url: build_preview_url(reacquired_state),
          resolved_ports: Map.get(reacquired_state, :resolved_ports, %{}),
          started_at: now,
          expires_at: DateTime.add(now, ttl_minutes * 60, :second),
          last_error: nil,
          workspace_path: Map.get(reacquired_state, :workspace_path),
          status: :running
        }

        Logger.info(
          "Preview session created via handoff project=#{project_slug} story=#{story_id}"
        )

        persist_upsert(key, session, :preview)

        {:reply, {:ok, session}, put_session(state, key, session)}
    end
  end

  def handle_call({:get_session, project_slug, story_id}, _from, state) do
    {:reply, load_preview_session_from_db(project_slug, story_id), state}
  end

  def handle_call(:list_sessions, _from, state) do
    list =
      case RuntimeSessions.list(session_type: :preview) do
        {:ok, entries} ->
          Enum.map(entries, fn entry ->
            %{
              project: entry.project_slug,
              story_id: entry.story_id,
              session: session_from_persisted(entry)
            }
          end)

        {:error, reason} ->
          Logger.warning("Failed to list preview sessions from db: #{reason}")
          []
      end

    {:reply, list, state}
  end

  @impl true
  def handle_info({:preview_start_complete, key, ref, result}, state) do
    case Map.get(state.start_refs, key) do
      ^ref ->
        state = clear_start_ref(state, key)

        case result do
          {:ok, session} ->
            persist_upsert(key, session, :preview)
            {:noreply, put_session(state, key, session)}

          {:error, reason} ->
            failed_session = failed_session(state, key, reason)
            persist_upsert(key, failed_session, :preview)
            {:noreply, put_session(state, key, failed_session)}
        end

      _other ->
        cleanup_stale_start_result(key, result)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:ttl_check, state) do
    now = DateTime.utc_now()

    expired = expired_preview_keys(now)

    state =
      Enum.reduce(expired, state, fn key, acc ->
        {project, story_id} = key
        Logger.info("Preview session expired project=#{project} story=#{story_id}")

        case load_preview_session_from_db(project, story_id) || Map.get(acc.sessions, key) do
          nil ->
            acc

          session ->
            do_stop_session(session, key)
            persist_delete(key)
        end

        drop_session(acc, key)
        |> clear_start_ref(key)
      end)

    schedule_ttl_check()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internal ────────────────────────────────────────────────────────

  defp do_start_preview({project_slug, story_id}, opts) do
    config = Keyword.fetch!(opts, :config)
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    workspace_key = Keyword.get(opts, :workspace_key, story_id)
    ttl_minutes = Keyword.get(opts, :ttl_minutes, preview_ttl(config))

    key = {project_slug, story_id}

    case maybe_reuse_persisted_runtime(key, workspace_path, ttl_minutes) do
      {:ok, session} ->
        Logger.info(
          "Preview session reused persisted runtime project=#{project_slug} story=#{story_id}"
        )

        {:ok, session}

      :none ->
        do_start_preview_cold(
          project_slug,
          story_id,
          config,
          workspace_path,
          workspace_key,
          ttl_minutes
        )
    end
  end

  defp build_starting_session(opts, runtime_state) do
    config = Keyword.get(opts, :config, %{})
    now = DateTime.utc_now()
    ttl_minutes = Keyword.get(opts, :ttl_minutes, preview_ttl(config))

    resolved_ports =
      case runtime_state do
        state when is_map(state) -> Map.get(state, :resolved_ports, %{})
        _other -> %{}
      end

    %{
      runtime_state: runtime_state,
      runtime_kind:
        Map.get(runtime_state, :kind) ||
          get_in(config, [Access.key(:runtime, %{}), Access.key(:kind, :host)]),
      preview_url: build_preview_url(runtime_state),
      resolved_ports: resolved_ports,
      started_at: now,
      expires_at: DateTime.add(now, ttl_minutes * 60, :second),
      last_error: nil,
      workspace_path: Keyword.get(opts, :workspace_path),
      status: :starting
    }
  end

  defp launch_async_start(manager_pid, key, opts, ref) when is_pid(manager_pid) do
    spawn(fn ->
      result =
        try do
          do_start_preview(key, opts)
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, "preview task #{kind}: #{inspect(reason)}"}
        end

      send(manager_pid, {:preview_start_complete, key, ref, result})
    end)
  end

  defp put_start_ref(state, key, ref) do
    %{state | start_refs: Map.put(state.start_refs, key, ref)}
  end

  defp clear_start_ref(state, key) do
    %{state | start_refs: Map.delete(state.start_refs, key)}
  end

  defp failed_session(state, key, reason) do
    now = DateTime.utc_now()
    existing = Map.get(state.sessions, key, %{})

    %{
      runtime_state: %{},
      runtime_kind: Map.get(existing, :runtime_kind, :host),
      preview_url: nil,
      resolved_ports: %{},
      started_at: Map.get(existing, :started_at, now),
      expires_at: Map.get(existing, :expires_at, now),
      last_error: reason,
      workspace_path: Map.get(existing, :workspace_path),
      status: :failed
    }
  end

  defp cleanup_stale_start_result(key, {:ok, session}) do
    runtime_state = Map.get(session, :runtime_state)
    safe_stop_and_release(runtime_state, runtime_context(key, runtime_state))
  end

  defp cleanup_stale_start_result(_key, _result), do: :ok

  defp do_start_preview_cold(
         project_slug,
         story_id,
         config,
         workspace_path,
         workspace_key,
         ttl_minutes
       ) do
    runtime_kind = get_in(config, [Access.key(:runtime, %{}), Access.key(:kind, :host)])

    workspace = %{path: workspace_path, key: workspace_key}
    runtime_state = Runtime.init(runtime_kind, config, workspace)
    context = runtime_context({project_slug, story_id}, runtime_state)

    with {:ok, started_runtime, _events} <- Broker.ensure_started(runtime_state, context),
         {:ok, runtime_state, _events} <- Broker.healthcheck(started_runtime, context) do
      now = DateTime.utc_now()

      session = %{
        runtime_state: runtime_state,
        runtime_kind: runtime_kind,
        preview_url: build_preview_url(runtime_state),
        resolved_ports: Map.get(runtime_state, :resolved_ports, %{}),
        started_at: now,
        expires_at: DateTime.add(now, ttl_minutes * 60, :second),
        last_error: nil,
        workspace_path: workspace_path,
        status: :running
      }

      Logger.info("Preview session started project=#{project_slug} story=#{story_id}")
      persist_upsert({project_slug, story_id}, session, :preview)
      {:ok, session}
    else
      {:error, reason, failed_state, _events} ->
        Logger.warning(
          "Preview session failed to start project=#{project_slug} story=#{story_id} reason=#{reason}"
        )

        safe_stop_and_release(failed_state, context)
        persist_delete({project_slug, story_id})
        {:error, "preview start failed: #{reason}"}
    end
  end

  defp do_stop_session(%{runtime_state: runtime_state, status: status}, key)
       when status in [:running, :starting] do
    safe_stop_and_release(runtime_state, runtime_context(key, runtime_state))

    :ok
  end

  defp do_stop_session(_session, _key), do: :ok

  defp reacquire_lease(runtime_state) do
    old_lease = Map.get(runtime_state, :offset_lease_name)

    if old_lease do
      case :global.whereis_name(old_lease) do
        :undefined ->
          case :global.register_name(old_lease, self()) do
            :yes -> runtime_state
            :no -> %{runtime_state | offset_lease_name: nil}
          end

        pid when pid == self() ->
          runtime_state

        _other_pid ->
          :global.re_register_name(old_lease, self())
          runtime_state
      end
    else
      runtime_state
    end
  end

  defp build_preview_url(runtime_state) do
    ports = Map.get(runtime_state, :resolved_ports, %{})

    case Map.get(ports, "PORT") do
      port when is_integer(port) and port > 0 ->
        "http://localhost:#{port}"

      _other ->
        nil
    end
  end

  defp preview_ttl(config) do
    get_in(config, [Access.key(:preview, %{}), Access.key(:ttl_minutes, @default_ttl_minutes)]) ||
      @default_ttl_minutes
  end

  defp put_session(state, key, session) do
    %{state | sessions: Map.put(state.sessions, key, session)}
  end

  defp drop_session(state, key) do
    %{state | sessions: Map.delete(state.sessions, key)}
  end

  defp schedule_ttl_check do
    Process.send_after(self(), :ttl_check, @ttl_check_interval_ms)
  end

  defp maybe_reuse_persisted_runtime({project_slug, story_id}, workspace_path, ttl_minutes) do
    case RuntimeSessions.get(project_slug, story_id) do
      {:ok, persisted}
      when persisted.status in [:running, :starting] and
             persisted.session_type in [:testing, :preview] ->
        runtime_state = persisted.runtime_state

        cond do
          not is_map(runtime_state) ->
            persist_delete({project_slug, story_id})
            :none

          runtime_state[:workspace_path] != workspace_path ->
            :none

          true ->
            runtime_state = reacquire_lease(runtime_state)
            context = runtime_context({project_slug, story_id}, runtime_state)

            case Broker.healthcheck(runtime_state, context) do
              {:ok, healthy_runtime, _events} ->
                now = DateTime.utc_now()

                session = %{
                  runtime_state: healthy_runtime,
                  runtime_kind: Map.get(healthy_runtime, :kind, persisted.runtime_kind || :host),
                  preview_url: build_preview_url(healthy_runtime),
                  resolved_ports: Map.get(healthy_runtime, :resolved_ports, %{}),
                  started_at: persisted.started_at || now,
                  expires_at: DateTime.add(now, ttl_minutes * 60, :second),
                  last_error: nil,
                  workspace_path: workspace_path,
                  status: :running
                }

                persist_upsert({project_slug, story_id}, session, :preview)
                {:ok, session}

              {:error, reason, failed_runtime, _events} ->
                Logger.warning(
                  "Persisted runtime not healthy project=#{project_slug} story=#{story_id} reason=#{reason}"
                )

                safe_stop_and_release(failed_runtime, context)
                persist_delete({project_slug, story_id})
                :none
            end
        end

      {:ok, _other} ->
        :none

      nil ->
        :none

      {:error, reason} ->
        Logger.warning(
          "Failed to load persisted runtime session project=#{project_slug} story=#{story_id}: #{reason}"
        )

        :none
    end
  end

  defp persist_upsert({project_slug, story_id}, session, session_type) do
    _ =
      RuntimeSessions.upsert(project_slug, story_id, session.runtime_state,
        status: session.status,
        session_type: session_type,
        preview_url: session.preview_url,
        started_at: session.started_at,
        expires_at: session.expires_at,
        last_error: session.last_error
      )

    :ok
  end

  defp persist_delete({project_slug, story_id}) do
    _ = RuntimeSessions.delete(project_slug, story_id)
    :ok
  end

  defp load_preview_session_from_db(project_slug, story_id) do
    case RuntimeSessions.get(project_slug, story_id) do
      {:ok, %{session_type: :preview} = entry} ->
        session_from_persisted(entry)

      {:ok, _other} ->
        nil

      nil ->
        nil

      {:error, reason} ->
        Logger.warning(
          "Failed to load preview session project=#{project_slug} story=#{story_id}: #{reason}"
        )

        nil
    end
  end

  defp load_runtime_session_from_db(project_slug, story_id) do
    case RuntimeSessions.get(project_slug, story_id) do
      {:ok, entry} -> session_from_persisted(entry)
      _other -> nil
    end
  end

  defp session_from_persisted(entry) when is_map(entry) do
    %{
      runtime_state: entry.runtime_state,
      runtime_kind: entry.runtime_kind,
      preview_url: entry.preview_url,
      resolved_ports: entry.resolved_ports || %{},
      started_at: entry.started_at || DateTime.utc_now(),
      expires_at:
        entry.expires_at || DateTime.add(DateTime.utc_now(), @default_ttl_minutes * 60, :second),
      last_error: entry.last_error,
      workspace_path: entry.workspace_path,
      status: entry.status || :running
    }
  end

  defp expired_preview_keys(now) do
    case RuntimeSessions.list(session_type: :preview, status: :running) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          is_struct(entry.expires_at, DateTime) and DateTime.compare(now, entry.expires_at) == :gt
        end)
        |> Enum.map(fn entry -> {entry.project_slug, entry.story_id} end)

      {:error, reason} ->
        Logger.warning("Failed to list preview sessions for ttl check: #{reason}")
        []
    end
  end

  defp restore_sessions_from_db do
    case RuntimeSessions.list(status: :running, session_type: :preview) do
      {:ok, entries} ->
        now = DateTime.utc_now()

        Enum.reduce(entries, %{}, fn entry, acc ->
          key = {entry.project_slug, entry.story_id}
          runtime_state = entry.runtime_state
          context = runtime_context(key, runtime_state)

          if is_struct(entry.expires_at, DateTime) and
               DateTime.compare(now, entry.expires_at) == :gt do
            safe_stop_and_release(runtime_state, context)
            persist_delete(key)
            acc
          else
            runtime_state = reacquire_lease(runtime_state)
            context = runtime_context(key, runtime_state)

            case Broker.healthcheck(runtime_state, context) do
              {:ok, healthy_runtime, _events} ->
                session = %{
                  runtime_state: healthy_runtime,
                  runtime_kind: Map.get(healthy_runtime, :kind, entry.runtime_kind || :host),
                  preview_url: build_preview_url(healthy_runtime),
                  resolved_ports: Map.get(healthy_runtime, :resolved_ports, %{}),
                  started_at: entry.started_at || now,
                  expires_at:
                    entry.expires_at || DateTime.add(now, @default_ttl_minutes * 60, :second),
                  last_error: entry.last_error,
                  workspace_path: entry.workspace_path,
                  status: :running
                }

                Map.put(acc, key, session)

              {:error, _reason, failed_runtime, _events} ->
                safe_stop_and_release(failed_runtime, context)
                persist_delete(key)
                acc
            end
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to restore preview sessions from db: #{reason}")
        %{}
    end
  end

  defp safe_stop_and_release(runtime_state, context)

  defp safe_stop_and_release(runtime_state, nil) do
    safe_stop_and_release(runtime_state, runtime_context({nil, nil}, runtime_state))
  end

  defp safe_stop_and_release(runtime_state, context) do
    try do
      case Broker.stop(runtime_state, context) do
        {:ok, _stopped_runtime, _events} ->
          :ok

        {:error, "invalid runtime context", _runtime, _events} ->
          :ok

        {:error, reason, _runtime, _events} ->
          Logger.warning("Error stopping preview runtime: #{reason}")
          :ok
      end
    rescue
      error ->
        Logger.warning("Error stopping preview runtime: #{Exception.message(error)}")
        :ok
    end

    :ok
  end

  defp runtime_context({project_slug, story_id}, runtime_state) do
    Broker.context(project_slug, story_id, runtime_state, session_type: :preview)
  end

  defp runtime_context(_key, runtime_state) do
    Broker.context(nil, nil, runtime_state, session_type: :preview)
  end

  defp normalize_stop_result(:ok), do: :ok
  defp normalize_stop_result({:error, _}), do: :ok
end

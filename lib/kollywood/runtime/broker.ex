defmodule Kollywood.Runtime.Broker do
  @moduledoc false

  require Logger

  alias Kollywood.PreviewSessionManager
  alias Kollywood.Runtime
  alias Kollywood.RuntimeSessions

  @type context :: %{
          project_slug: String.t(),
          story_id: String.t(),
          session_type: :testing | :preview,
          runtime_profile: atom(),
          runtime_kind: atom(),
          metadata: map()
        }

  @type status_event :: map()

  @spec context(String.t() | nil, String.t() | nil, map(), keyword()) :: context()
  def context(project_slug, story_id, runtime, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{}) |> map_or_empty()

    %{
      project_slug: optional_string(project_slug) || "default",
      story_id: optional_string(story_id) || "",
      session_type: normalize_session_type(Keyword.get(opts, :session_type, :testing)),
      runtime_profile: Map.get(runtime || %{}, :profile, :full_stack),
      runtime_kind: normalize_runtime_kind(Map.get(runtime || %{}, :kind, :host)),
      metadata: metadata
    }
  end

  @spec ensure_started(map(), context()) ::
          {:ok, map(), [status_event()]}
          | {:error, String.t(), map(), [status_event()]}
  def ensure_started(runtime, context) when is_map(runtime) and is_map(context) do
    cond do
      runtime.started? == true ->
        {:ok, runtime, []}

      not runtime_processes_configured?(runtime) ->
        {:error, "#{context.session_type} requires runtime.processes to be configured", runtime,
         []}

      true ->
        events = [runtime_starting_event(runtime, context)]

        case Runtime.start(runtime) do
          {:ok, started_runtime} ->
            {:ok, started_runtime,
             events ++
               [runtime_started_event(started_runtime, refresh_context(context, started_runtime))]}

          {:error, reason, failed_runtime} ->
            {:error, reason, failed_runtime,
             events ++
               [runtime_start_failed_event(failed_runtime, context, reason)]}
        end
    end
  end

  def ensure_started(runtime, _context), do: {:error, "invalid runtime context", runtime, []}

  @spec healthcheck(map(), context()) ::
          {:ok, map(), [status_event()]}
          | {:error, String.t(), map(), [status_event()]}
  def healthcheck(runtime, context) when is_map(runtime) and is_map(context) do
    events = [runtime_healthcheck_started_event(runtime, context)]

    case Runtime.healthcheck(runtime) do
      :ok ->
        {:ok, runtime, events ++ [runtime_healthcheck_passed_event(runtime, context)]}

      {:error, reason} ->
        {:error, "runtime healthcheck failed: #{reason}", runtime,
         events ++ [runtime_healthcheck_failed_event(runtime, context, reason)]}
    end
  end

  def healthcheck(runtime, _context), do: {:error, "invalid runtime context", runtime, []}

  @spec stop(map(), context()) ::
          {:ok, map(), [status_event()]}
          | {:error, String.t(), map(), [status_event()]}
  def stop(runtime, context) when is_map(runtime) and is_map(context) do
    if runtime.profile == :checks_only or not runtime_needs_stop?(runtime) do
      {:ok, Runtime.release(runtime), []}
    else
      events = [runtime_stopping_event(runtime, context)]

      case Runtime.stop(runtime) do
        {:ok, stopped_runtime} ->
          {:ok, stopped_runtime,
           events ++
             [runtime_stopped_event(stopped_runtime, refresh_context(context, stopped_runtime))]}

        {:error, reason, failed_runtime} ->
          {:error, reason, failed_runtime,
           events ++ [runtime_stop_failed_event(failed_runtime, context, reason)]}
      end
    end
  end

  def stop(runtime, _context), do: {:error, "invalid runtime context", runtime, []}

  @spec persist_runtime_session(map(), context(), keyword()) :: :ok | {:error, String.t()}
  def persist_runtime_session(runtime, context, opts \\ [])

  def persist_runtime_session(runtime, context, opts) when is_map(runtime) and is_map(context) do
    force? = truthy?(Keyword.get(opts, :force, false))

    if context.story_id != "" and (force? or runtime_needs_stop?(runtime)) do
      RuntimeSessions.upsert(context.project_slug, context.story_id, runtime,
        status: Keyword.get(opts, :status, :running),
        session_type: Keyword.get(opts, :session_type, context.session_type),
        preview_url: Keyword.get(opts, :preview_url),
        started_at: Keyword.get(opts, :started_at),
        expires_at: Keyword.get(opts, :expires_at),
        last_error: Keyword.get(opts, :last_error)
      )
    else
      :ok
    end
  end

  def persist_runtime_session(_runtime, _context, _opts), do: {:error, "invalid runtime context"}

  @spec clear_runtime_session(context()) :: :ok | {:error, String.t()}
  def clear_runtime_session(context) when is_map(context) do
    if context.story_id != "" do
      RuntimeSessions.delete(context.project_slug, context.story_id)
    else
      :ok
    end
  end

  def clear_runtime_session(_context), do: {:error, "invalid runtime context"}

  @spec get_runtime_session(context(), keyword()) :: {:ok, map()} | {:error, String.t()} | nil
  def get_runtime_session(context, opts \\ [])

  def get_runtime_session(context, opts) when is_map(context) and is_list(opts) do
    desired_type = requested_session_type(Keyword.get(opts, :session_type, :any))

    case RuntimeSessions.get(context.project_slug, context.story_id) do
      {:ok, session} = ok ->
        if session_type_matches?(session, desired_type), do: ok, else: nil

      other ->
        other
    end
  end

  def get_runtime_session(_context, _opts), do: {:error, "invalid runtime context"}

  @spec list_runtime_sessions(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def list_runtime_sessions(opts \\ []) when is_list(opts) do
    status = Keyword.get(opts, :status)
    session_type = requested_session_type(Keyword.get(opts, :session_type, :any))

    runtime_session_opts =
      []
      |> maybe_put_option(:status, status)
      |> maybe_put_option(:session_type, session_type)

    RuntimeSessions.list(runtime_session_opts)
  end

  @spec handoff_to_preview(map(), map(), context(), keyword()) ::
          {:ok, map(), [status_event()]} | {:error, String.t(), [status_event()]}
  def handoff_to_preview(runtime, config, context, opts \\ [])

  def handoff_to_preview(runtime, config, context, opts)
      when is_map(runtime) and is_map(config) and is_map(context) do
    ttl_minutes =
      Keyword.get(opts, :ttl_minutes) ||
        get_in(config, [Access.key(:preview, %{}), Access.key(:ttl_minutes, 120)]) || 120

    event = preview_runtime_handoff_event(runtime, context)

    case PreviewSessionManager.handoff_runtime(
           context.project_slug,
           context.story_id,
           runtime,
           ttl_minutes: ttl_minutes
         ) do
      {:ok, _session} ->
        handed_off_runtime = %{
          runtime
          | offset_lease_name: nil,
            started?: false,
            process_state: :handed_off
        }

        {:ok, handed_off_runtime, [event]}

      {:error, reason} ->
        {:error, reason, [event]}
    end
  end

  def handoff_to_preview(_runtime, _config, _context, _opts),
    do: {:error, "invalid runtime context", []}

  defp refresh_context(context, runtime) do
    %{
      context
      | runtime_profile: Map.get(runtime, :profile, context.runtime_profile),
        runtime_kind: normalize_runtime_kind(Map.get(runtime, :kind, context.runtime_kind))
    }
  end

  defp runtime_starting_event(runtime, context) do
    %{
      type: :runtime_starting,
      runtime_profile: context.runtime_profile,
      command: Map.get(runtime, :command),
      workspace_path: Map.get(runtime, :workspace_path),
      process_count: runtime_process_count(runtime)
    }
  end

  defp runtime_started_event(runtime, context) do
    %{
      type: :runtime_started,
      runtime_profile: context.runtime_profile,
      workspace_path: Map.get(runtime, :workspace_path),
      command: Map.get(runtime, :command),
      process_count: runtime_process_count(runtime),
      port_offset: Map.get(runtime, :port_offset),
      resolved_ports: Map.get(runtime, :resolved_ports, %{})
    }
  end

  defp runtime_start_failed_event(runtime, context, reason) do
    %{
      type: :runtime_start_failed,
      runtime_profile: context.runtime_profile,
      workspace_path: Map.get(runtime, :workspace_path),
      command: Map.get(runtime, :command),
      reason: reason
    }
  end

  defp runtime_healthcheck_started_event(runtime, context) do
    %{
      type: :runtime_healthcheck_started,
      runtime_profile: context.runtime_profile,
      workspace_path: Map.get(runtime, :workspace_path),
      command: Map.get(runtime, :command),
      timeout_ms: Map.get(runtime, :start_timeout_ms),
      resolved_ports: Map.get(runtime, :resolved_ports, %{})
    }
  end

  defp runtime_healthcheck_passed_event(runtime, context) do
    %{
      type: :runtime_healthcheck_passed,
      runtime_profile: context.runtime_profile,
      workspace_path: Map.get(runtime, :workspace_path),
      command: Map.get(runtime, :command),
      resolved_ports: Map.get(runtime, :resolved_ports, %{})
    }
  end

  defp runtime_healthcheck_failed_event(runtime, context, reason) do
    %{
      type: :runtime_healthcheck_failed,
      runtime_profile: context.runtime_profile,
      workspace_path: Map.get(runtime, :workspace_path),
      command: Map.get(runtime, :command),
      reason: reason,
      resolved_ports: Map.get(runtime, :resolved_ports, %{})
    }
  end

  defp runtime_stopping_event(runtime, context) do
    %{
      type: :runtime_stopping,
      runtime_profile: context.runtime_profile,
      command: Map.get(runtime, :command),
      workspace_path: Map.get(runtime, :workspace_path)
    }
  end

  defp runtime_stopped_event(runtime, context) do
    %{
      type: :runtime_stopped,
      runtime_profile: context.runtime_profile,
      workspace_path: Map.get(runtime, :workspace_path),
      command: Map.get(runtime, :command)
    }
  end

  defp runtime_stop_failed_event(runtime, context, reason) do
    %{
      type: :runtime_stop_failed,
      runtime_profile: context.runtime_profile,
      workspace_path: Map.get(runtime, :workspace_path),
      command: Map.get(runtime, :command),
      reason: reason
    }
  end

  defp preview_runtime_handoff_event(runtime, context) do
    %{
      type: :preview_runtime_handoff,
      story_id: context.story_id,
      project: context.project_slug,
      runtime_kind: Map.get(runtime, :kind, context.runtime_kind)
    }
  end

  defp runtime_needs_stop?(runtime) when is_map(runtime) do
    runtime.started? == true or runtime.process_state == :start_failed
  end

  defp runtime_needs_stop?(_runtime), do: false

  defp runtime_processes_configured?(runtime) when is_map(runtime) do
    case Map.get(runtime, :processes, []) do
      processes when is_list(processes) -> processes != []
      _other -> false
    end
  end

  defp runtime_processes_configured?(_runtime), do: false

  defp runtime_process_count(runtime) when is_map(runtime) do
    case Map.get(runtime, :processes, []) do
      processes when is_list(processes) -> length(processes)
      _other -> 0
    end
  end

  defp runtime_process_count(_runtime), do: 0

  defp normalize_session_type(:preview), do: :preview
  defp normalize_session_type("preview"), do: :preview
  defp normalize_session_type(_), do: :testing

  defp requested_session_type(:any), do: nil
  defp requested_session_type("any"), do: nil
  defp requested_session_type(nil), do: nil
  defp requested_session_type(value), do: normalize_session_type(value)

  defp session_type_matches?(session, nil) when is_map(session), do: true

  defp session_type_matches?(session, desired_type) when is_map(session) do
    Map.get(session, :session_type) == desired_type
  end

  defp session_type_matches?(_session, _desired_type), do: false

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_runtime_kind(:docker), do: :docker
  defp normalize_runtime_kind("docker"), do: :docker
  defp normalize_runtime_kind(_), do: :host

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_value), do: nil

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp truthy?(value), do: value in [true, 1, "1", "true", "TRUE", "yes", "on"]
end

defmodule Kollywood.Orchestrator.RunState do
  @moduledoc """
  Canonical per-run state reducer.

  A run state is represented as:

      %{phase: String.t(), activity: String.t() | nil, detail: map()}

  - `phase` tracks lifecycle (`queued`, `starting`, `running`, `stopping`, `finished`, `error`)
  - `activity` tracks what the run is currently doing while running
  - `detail` carries small, user-facing context (last event type, turn, cycle, message)
  """

  @type phase :: String.t()
  @type activity :: String.t() | nil
  @type detail :: map()
  @type t :: %{phase: phase(), activity: activity(), detail: detail()}

  @sticky_activities ["waiting_for_input", "blocked", "completed"]

  @new_work_events [
    "run_started",
    "workspace_ready",
    "execution_session_started",
    "session_started",
    "prompt_captured",
    "turn_started",
    "checks_started",
    "check_started",
    "review_started",
    "testing_started",
    "runtime_starting",
    "runtime_healthcheck_started",
    "publish_started"
  ]

  @progress_events [
    "run_started",
    "workspace_ready",
    "execution_session_started",
    "execution_session_completed",
    "execution_session_stopped",
    "execution_session_stop_failed",
    "session_started",
    "session_stopped",
    "session_stop_failed",
    "prompt_captured",
    "quality_cycle_started",
    "quality_cycle_passed",
    "quality_cycle_retrying",
    "turn_started",
    "turn_succeeded",
    "turn_failed",
    "checks_started",
    "check_started",
    "check_passed",
    "check_failed",
    "checks_passed",
    "checks_failed",
    "review_started",
    "review_passed",
    "review_failed",
    "review_error",
    "testing_started",
    "testing_checkpoint",
    "testing_passed",
    "testing_failed",
    "testing_error",
    "runtime_starting",
    "runtime_started",
    "runtime_start_failed",
    "runtime_healthcheck_started",
    "runtime_healthcheck_passed",
    "runtime_healthcheck_failed",
    "runtime_stopping",
    "runtime_stopped",
    "runtime_stop_failed",
    "publish_started",
    "publish_push_succeeded",
    "publish_pr_created",
    "publish_pending_merge",
    "publish_merged",
    "publish_succeeded",
    "publish_skipped",
    "publish_failed",
    "publish_merge_failed",
    "publish_merge_conflict",
    "publish_merge_conflict_resolved",
    "completion_detected",
    "idle_timeout_reached",
    "run_finished"
  ]

  @doc "Builds canonical state from coarse status values."
  @spec from_status(String.t() | atom() | nil, t() | nil) :: t()
  def from_status(status, last_state \\ nil) do
    last_state = normalize_state(last_state)

    base =
      case normalize_status(status) do
        "queued" -> %{"phase" => "queued", "activity" => "idle"}
        "starting" -> %{"phase" => "starting", "activity" => "thinking"}
        "running" -> %{"phase" => "running", "activity" => "idle"}
        "stopping" -> %{"phase" => "stopping", "activity" => "blocked"}
        "ok" -> %{"phase" => "finished", "activity" => "completed"}
        "completed" -> %{"phase" => "finished", "activity" => "completed"}
        "finished" -> %{"phase" => "finished", "activity" => "completed"}
        "max_turns_reached" -> %{"phase" => "finished", "activity" => "completed"}
        "stopped" -> %{"phase" => "finished", "activity" => "blocked"}
        "cancelled" -> %{"phase" => "finished", "activity" => "blocked"}
        "failed" -> %{"phase" => "error", "activity" => "blocked"}
        "error" -> %{"phase" => "error", "activity" => "blocked"}
        "stalled" -> %{"phase" => "running", "activity" => "stalled"}
        "offline" -> %{"phase" => "running", "activity" => "offline"}
        _other -> nil
      end

    cond do
      is_map(base) ->
        %{
          phase: base["phase"],
          activity: base["activity"],
          detail: last_state.detail
        }

      is_map(last_state) ->
        last_state

      true ->
        unknown()
    end
  end

  @doc "Reduces one runner event into canonical run state."
  @spec from_event(map(), t() | nil) :: t()
  def from_event(event, last_state \\ nil)

  def from_event(event, last_state) when is_map(event) do
    state = normalize_state(last_state)
    type = event_type(event)

    cond do
      is_nil(type) ->
        state

      sticky_activity?(state.activity) and not new_work_event?(type) and type != "run_finished" ->
        with_event_detail(state, type, event)

      true ->
        state
        |> transition_from_event(type, event)
        |> with_event_detail(type, event)
    end
  end

  def from_event(_event, last_state), do: normalize_state(last_state)

  @doc "Returns true when an event indicates forward activity progress."
  @spec progress_event?(map()) :: boolean()
  def progress_event?(event) when is_map(event) do
    case event_type(event) do
      nil -> false
      type -> type in @progress_events
    end
  end

  def progress_event?(_event), do: false

  @doc "Returns true for running states that can be downgraded to stalled/offline."
  @spec eligible_for_health_downgrade?(t() | nil) :: boolean()
  def eligible_for_health_downgrade?(state) do
    normalized = normalize_state(state)

    running?(normalized) and
      normalized.activity not in ["blocked", "completed", "offline"]
  end

  @doc "Returns true when run phase is running."
  @spec running?(t() | nil) :: boolean()
  def running?(%{phase: "running"}), do: true
  def running?(_state), do: false

  @doc "Returns the canonical phase string."
  @spec phase(t() | nil) :: String.t()
  def phase(state), do: normalize_state(state).phase

  @doc "Returns the canonical activity string (or nil)."
  @spec activity(t() | nil) :: String.t() | nil
  def activity(state), do: normalize_state(state).activity

  @doc "Returns a short display label for status surfaces."
  @spec label(t() | nil) :: String.t()
  def label(state) do
    state = normalize_state(state)

    cond do
      is_binary(state.activity) and state.activity != "" -> humanize(state.activity)
      is_binary(state.phase) and state.phase != "" -> humanize(state.phase)
      true -> "Unknown"
    end
  end

  @doc "Normalizes and returns run state as an atom-key map."
  @spec to_map(t() | nil) :: t()
  def to_map(state), do: normalize_state(state)

  @doc "Returns run state using string keys for metadata/json storage."
  @spec to_storage_map(t() | nil) :: map()
  def to_storage_map(state) do
    normalized = normalize_state(state)

    %{
      "phase" => normalized.phase,
      "activity" => normalized.activity,
      "detail" => stringify_map(normalized.detail)
    }
  end

  @spec unknown() :: t()
  def unknown do
    %{phase: "unknown", activity: nil, detail: %{}}
  end

  defp normalize_state(%{phase: phase, activity: activity, detail: detail})
       when is_binary(phase) and (is_binary(activity) or is_nil(activity)) and is_map(detail) do
    %{phase: phase, activity: activity, detail: detail}
  end

  defp normalize_state(%{"phase" => phase} = state) when is_binary(phase) do
    %{
      phase: phase,
      activity: optional_string(Map.get(state, "activity")),
      detail: map_or_empty(Map.get(state, "detail"))
    }
  end

  defp normalize_state(_state), do: unknown()

  defp transition_from_event(state, "run_finished", event) do
    event_status = Map.get(event, :status) || Map.get(event, "status")
    from_status(event_status, state)
  end

  defp transition_from_event(state, type, _event) do
    cond do
      type in ["run_started", "execution_session_started"] ->
        %{state | phase: "starting", activity: "thinking"}

      type in ["workspace_ready", "session_started"] ->
        %{state | phase: "running", activity: "idle"}

      type in [
        "prompt_captured",
        "turn_started",
        "checks_started",
        "check_started",
        "review_started",
        "testing_started",
        "runtime_starting",
        "runtime_healthcheck_started",
        "runtime_stopping",
        "publish_started"
      ] ->
        %{state | phase: "running", activity: "executing"}

      type in [
        "turn_succeeded",
        "check_passed",
        "checks_passed",
        "review_passed",
        "testing_passed",
        "testing_checkpoint",
        "quality_cycle_started",
        "quality_cycle_passed",
        "quality_cycle_retrying",
        "runtime_started",
        "runtime_healthcheck_passed",
        "runtime_stopped",
        "publish_push_succeeded",
        "publish_pending_merge",
        "publish_pr_created",
        "publish_merged",
        "publish_succeeded",
        "publish_skipped",
        "session_stopped",
        "execution_session_completed",
        "execution_session_stopped"
      ] ->
        %{state | phase: "running", activity: "idle"}

      type == "completion_detected" ->
        %{state | phase: "running", activity: "completed"}

      type in [
        "idle_timeout_reached",
        "turn_failed",
        "checks_failed",
        "review_failed",
        "review_error",
        "testing_failed",
        "testing_error",
        "runtime_start_failed",
        "runtime_healthcheck_failed",
        "runtime_stop_failed",
        "publish_failed",
        "publish_merge_failed",
        "publish_merge_conflict",
        "session_stop_failed",
        "execution_session_stop_failed"
      ] ->
        %{state | phase: "running", activity: "blocked"}

      true ->
        state
    end
  end

  defp with_event_detail(state, type, event) do
    detail =
      state.detail
      |> Map.put(:last_event_type, type)
      |> maybe_put_if_present(
        :turn,
        positive_integer(Map.get(event, :turn) || Map.get(event, "turn"))
      )
      |> maybe_put_if_present(
        :cycle,
        positive_integer(Map.get(event, :cycle) || Map.get(event, "cycle"))
      )
      |> maybe_put_if_present(
        :check_index,
        positive_integer(Map.get(event, :check_index) || Map.get(event, "check_index"))
      )
      |> maybe_put_if_present(
        :check_count,
        positive_integer(Map.get(event, :check_count) || Map.get(event, "check_count"))
      )
      |> maybe_put_if_present(
        :tool_name,
        optional_string(Map.get(event, :command) || Map.get(event, "command"))
      )
      |> maybe_put_if_present(:message, compact_reason(event))

    %{state | detail: detail}
  end

  defp compact_reason(event) when is_map(event) do
    reason =
      Map.get(event, :reason) || Map.get(event, "reason") || Map.get(event, :error) ||
        Map.get(event, "error")

    reason
    |> optional_string()
    |> case do
      nil -> nil
      value -> String.slice(value, 0, 240)
    end
  end

  defp compact_reason(_event), do: nil

  defp sticky_activity?(activity) when is_binary(activity), do: activity in @sticky_activities
  defp sticky_activity?(_activity), do: false

  defp new_work_event?(type) when is_binary(type), do: type in @new_work_events
  defp new_work_event?(_type), do: false

  defp event_type(event) when is_map(event) do
    case Map.get(event, :type) || Map.get(event, "type") do
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp event_type(_event), do: nil

  defp normalize_status(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_status()

  defp normalize_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_status(_value), do: ""

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> optional_string()

  defp optional_string(_value), do: nil

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp maybe_put_if_present(map, _key, nil), do: map
  defp maybe_put_if_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_map), do: %{}

  defp stringify_value(nil), do: nil
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end

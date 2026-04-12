defmodule Kollywood.Orchestrator.RunSteps do
  @moduledoc """
  Parses a run event stream into a sequence of discrete pipeline steps.

  Each step represents a logical unit: an agent turn, a checks pass,
  a review cycle, a testing phase, or a runtime operation. Steps carry
  their own slice of events, timing, status, prompt, and phase metadata.
  """

  alias Kollywood.RecoveryGuidance

  @type step :: %{
          idx: non_neg_integer(),
          kind: String.t(),
          label: String.t(),
          status: String.t(),
          started_at: String.t() | nil,
          ended_at: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          cycle: non_neg_integer() | nil,
          turn: non_neg_integer() | nil,
          prompt: String.t() | nil,
          events: [map()],
          error: String.t() | nil,
          detail: map()
        }

  @doc """
  Parse events into an ordered list of pipeline steps.

  Options:
    - `:run_in_progress` (boolean, default false) — when true, open steps
      keep their `"running"` status instead of being marked `"interrupted"`.
  """
  @spec from_events([map()], keyword()) :: [step()]
  def from_events(events, opts \\ [])

  def from_events(events, opts) when is_list(events) do
    run_in_progress = Keyword.get(opts, :run_in_progress, false)

    events
    |> scan_steps(run_in_progress)
    |> Enum.with_index()
    |> Enum.map(fn {step, idx} -> Map.put(step, :idx, idx) end)
  end

  def from_events(_, _opts), do: []

  defp scan_steps(events, run_in_progress) do
    {steps, current, _finished} =
      Enum.reduce(events, {[], nil, false}, fn event, {steps, current, finished} ->
        if finished do
          {steps, current, true}
        else
          type = event_type(event)
          {new_steps, new_current} = handle_event(type, event, steps, current)
          finished = type == "run_finished"
          {new_steps, new_current, finished}
        end
      end)

    finalize(steps, current, run_in_progress)
  end

  # --- Agent turn (coding or remediation) ---

  defp handle_event("turn_started", event, steps, current) do
    carried_prompt =
      if current && current.kind == "prompt_captured", do: current.prompt, else: nil

    steps = close_step(steps, current, event)
    cycle = int_field(event, "checks_cycle")

    seq = Enum.count(steps, fn s -> s.kind == "agent_turn" end) + 1

    {steps,
     %{
       kind: "agent_turn",
       label: "Agent Turn #{seq}",
       status: "running",
       started_at: timestamp(event),
       ended_at: nil,
       duration_ms: nil,
       cycle: cycle,
       turn: seq,
       prompt: carried_prompt,
       events: [event],
       error: nil,
       detail: %{}
     }}
  end

  defp handle_event("prompt_captured", event, steps, nil) do
    {steps, prompt_step(event)}
  end

  defp handle_event("prompt_captured", event, steps, %{status: "running"} = current) do
    {steps, %{current | prompt: str_field(event, "prompt"), events: current.events ++ [event]}}
  end

  defp handle_event("prompt_captured", event, steps, current) do
    steps = close_step(steps, current)
    {steps, prompt_step(event)}
  end

  defp handle_event("turn_succeeded", event, steps, %{kind: "agent_turn"} = current) do
    {steps, finish_step(current, event, "ok")}
  end

  defp handle_event("turn_failed", event, steps, %{kind: "agent_turn"} = current) do
    {steps, finish_step(current, event, "failed", str_field(event, "reason"))}
  end

  # --- Checks ---

  defp handle_event("checks_started", event, steps, current) do
    steps = close_step(steps, current, event)
    cycle = int_field(event, "cycle")
    seq = Enum.count(steps, fn s -> s.kind == "checks" end) + 1

    {steps,
     %{
       kind: "checks",
       label: "Checks#{if seq > 1, do: " (#{seq})", else: ""}",
       status: "running",
       started_at: timestamp(event),
       ended_at: nil,
       duration_ms: nil,
       cycle: cycle,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{
         check_count: int_field(event, "check_count"),
         checks: []
       }
     }}
  end

  defp handle_event("check_started", event, steps, %{kind: "checks"} = current) do
    check = %{
      index: int_field(event, "check_index"),
      command: str_field(event, "command"),
      status: "running",
      started_at: timestamp(event),
      duration_ms: nil
    }

    detail = Map.update!(current.detail, :checks, &(&1 ++ [check]))
    {steps, %{current | detail: detail, events: current.events ++ [event]}}
  end

  defp handle_event("check_passed", event, steps, %{kind: "checks"} = current) do
    detail = update_last_check(current.detail, event, "passed")
    {steps, %{current | detail: detail, events: current.events ++ [event]}}
  end

  defp handle_event("check_failed", event, steps, %{kind: "checks"} = current) do
    detail = update_last_check(current.detail, event, "failed")
    {steps, %{current | detail: detail, events: current.events ++ [event]}}
  end

  defp handle_event("checks_passed", event, steps, %{kind: "checks"} = current) do
    {steps, finish_step(current, event, "passed")}
  end

  defp handle_event("checks_failed", event, steps, %{kind: "checks"} = current) do
    {steps, finish_step(current, event, "failed")}
  end

  # --- Review ---

  defp handle_event("review_started", event, steps, current) do
    carried_prompt =
      if current && current.kind == "prompt_captured", do: current.prompt, else: nil

    steps = close_step(steps, current, event)
    cycle = int_field(event, "cycle")
    seq = Enum.count(steps, fn s -> s.kind == "review" end) + 1

    {steps,
     %{
       kind: "review",
       label: "Review#{if seq > 1, do: " (#{seq})", else: ""}",
       status: "running",
       started_at: timestamp(event),
       ended_at: nil,
       duration_ms: nil,
       cycle: cycle,
       turn: nil,
       prompt: carried_prompt,
       events: [event],
       error: nil,
       detail: %{agent_kind: str_field(event, "agent_kind")}
     }}
  end

  defp handle_event("review_passed", event, steps, %{kind: "review"} = current) do
    {steps, finish_step(current, event, "passed")}
  end

  defp handle_event("review_failed", event, steps, %{kind: "review"} = current) do
    {steps, finish_step(current, event, "failed", str_field(event, "reason"))}
  end

  defp handle_event("review_error", event, steps, %{kind: "review"} = current) do
    {steps, finish_step(current, event, "error", str_field(event, "reason"))}
  end

  # --- Testing ---

  defp handle_event("testing_started", event, steps, current) do
    carried_prompt =
      if current && current.kind == "prompt_captured", do: current.prompt, else: nil

    steps = close_step(steps, current, event)
    cycle = int_field(event, "cycle")
    seq = Enum.count(steps, fn s -> s.kind == "testing" end) + 1

    {steps,
     %{
       kind: "testing",
       label: "Testing#{if seq > 1, do: " (#{seq})", else: ""}",
       status: "running",
       started_at: timestamp(event),
       ended_at: nil,
       duration_ms: nil,
       cycle: cycle,
       turn: nil,
       prompt: carried_prompt,
       events: [event],
       error: nil,
       detail: %{
         agent_kind: str_field(event, "agent_kind"),
         runtime_profile: str_field(event, "runtime_profile")
       }
     }}
  end

  defp handle_event("testing_passed", event, steps, %{kind: "testing"} = current) do
    {steps, finish_step(current, event, "passed")}
  end

  defp handle_event("testing_failed", event, steps, %{kind: "testing"} = current) do
    {steps, finish_step(current, event, "failed", str_field(event, "reason"))}
  end

  defp handle_event("testing_error", event, steps, %{kind: "testing"} = current) do
    {steps, finish_step(current, event, "error", str_field(event, "reason"))}
  end

  # --- Runtime operations ---
  #
  # Runtime start/stop are top-level pipeline steps emitted by the agent runner
  # before testing and after the full pipeline respectively.

  defp handle_event("runtime_starting", event, steps, current) do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "runtime",
       label: "Runtime Start (#{str_field(event, "command") || "docker"})",
       status: "running",
       started_at: timestamp(event),
       ended_at: nil,
       duration_ms: nil,
       cycle: nil,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{
         command: str_field(event, "command"),
         runtime_profile: str_field(event, "runtime_profile"),
         workspace_path: str_field(event, "workspace_path")
       }
     }}
  end

  defp handle_event(type, event, steps, %{kind: "runtime"} = current)
       when type in [
              "runtime_started",
              "runtime_healthcheck_started",
              "runtime_healthcheck_passed",
              "runtime_healthcheck_failed",
              "runtime_start_failed",
              "runtime_stopping",
              "runtime_stopped"
            ] do
    current = %{current | events: current.events ++ [event]}

    case type do
      "runtime_healthcheck_passed" ->
        {steps ++ [finish_step(current, event, "ok")], nil}

      "runtime_healthcheck_failed" ->
        {steps ++ [finish_step(current, event, "failed", str_field(event, "reason"))], nil}

      "runtime_start_failed" ->
        {steps ++ [finish_step(current, event, "failed", str_field(event, "reason"))], nil}

      "runtime_stopped" ->
        {steps ++ [finish_step(current, event, if(current.error, do: "failed", else: "ok"))], nil}

      _ ->
        {steps, current}
    end
  end

  defp handle_event("runtime_stopping", event, steps, current)
       when is_nil(current) or current.kind != "runtime" do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "runtime",
       label: "Runtime Stop",
       status: "running",
       started_at: timestamp(event),
       ended_at: nil,
       duration_ms: nil,
       cycle: nil,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{command: str_field(event, "command")}
     }}
  end

  # --- Run lifecycle ---

  defp handle_event("run_started", event, steps, current) do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "run_started",
       label: "Run Started",
       status: "ok",
       started_at: timestamp(event),
       ended_at: timestamp(event),
       duration_ms: 0,
       cycle: nil,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{
         retry_mode: str_field(event, "retry_mode"),
         mode: str_field(event, "mode")
       }
     }}
  end

  defp handle_event("workspace_ready", event, steps, current) do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "workspace_ready",
       label: "Workspace Ready",
       status: "ok",
       started_at: timestamp(event),
       ended_at: timestamp(event),
       duration_ms: 0,
       cycle: nil,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{workspace_path: str_field(event, "workspace_path")}
     }}
  end

  defp handle_event("run_finished", event, steps, current) do
    steps = close_step(steps, current, event)
    status = str_field(event, "status") || "finished"
    reason = str_field(event, "reason")
    guidance = recovery_guidance_from_event(event) || RecoveryGuidance.parse(reason)

    detail =
      if guidance do
        %{recovery_guidance: guidance}
      else
        %{}
      end

    step = %{
      kind: "run_finished",
      label: "Run Finished",
      status: to_string(status),
      started_at: timestamp(event),
      ended_at: timestamp(event),
      duration_ms: 0,
      cycle: nil,
      turn: nil,
      prompt: nil,
      events: [event],
      error: reason,
      detail: detail
    }

    {steps ++ [step], nil}
  end

  # --- Quality cycle markers ---

  defp handle_event("quality_cycle_started", event, steps, current) do
    steps = close_step(steps, current, event)
    cycle = int_field(event, "cycle")

    {steps,
     %{
       kind: "quality_cycle",
       label: "Quality Cycle #{cycle || "?"}",
       status: "ok",
       started_at: timestamp(event),
       ended_at: timestamp(event),
       duration_ms: 0,
       cycle: cycle,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{
         max_cycles: int_field(event, "max_cycles"),
         checks_max_cycles: int_field(event, "checks_max_cycles"),
         review_max_cycles: int_field(event, "review_max_cycles")
       }
     }}
  end

  defp handle_event("quality_cycle_retrying", event, steps, current) do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "quality_retry",
       label: "Quality Cycle Retry",
       status: "ok",
       started_at: timestamp(event),
       ended_at: timestamp(event),
       duration_ms: 0,
       cycle: int_field(event, "cycle"),
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{retry_reason: str_field(event, "retry_reason")}
     }}
  end

  defp handle_event("quality_cycle_passed", event, steps, current) do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "quality_passed",
       label: "Quality Passed",
       status: "passed",
       started_at: timestamp(event),
       ended_at: timestamp(event),
       duration_ms: 0,
       cycle: int_field(event, "cycle"),
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{}
     }}
  end

  # --- Session lifecycle (fold into current step) ---

  defp handle_event(type, event, steps, current)
       when type in [
              "execution_session_started",
              "execution_session_completed",
              "execution_session_stopped",
              "execution_session_stop_failed",
              "session_started",
              "session_stopped",
              "session_stop_failed"
            ] do
    if current do
      {steps, %{current | events: current.events ++ [event]}}
    else
      {steps, current}
    end
  end

  # --- Publish ---

  defp handle_event("publish_started", event, steps, current) do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "publish",
       label: "Publish",
       status: "running",
       started_at: timestamp(event),
       ended_at: nil,
       duration_ms: nil,
       cycle: nil,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{branch: str_field(event, "branch"), mode: str_field(event, "mode")}
     }}
  end

  defp handle_event("publish_succeeded", event, steps, %{kind: "publish"} = current) do
    finished = finish_step(current, event, "ok")

    if Map.get(current.detail, :pending_merge) do
      branch = Map.get(current.detail, :branch)

      pending = %{
        kind: "pending_merge",
        label: "Pending Merge",
        status: "ok",
        started_at: timestamp(event),
        ended_at: timestamp(event),
        duration_ms: 0,
        cycle: nil,
        turn: nil,
        prompt: nil,
        events: [],
        error: nil,
        detail: %{branch: branch}
      }

      {steps ++ [finished], pending}
    else
      {steps, finished}
    end
  end

  defp handle_event("publish_failed", event, steps, %{kind: "publish"} = current) do
    {steps, finish_step(current, event, "failed", str_field(event, "reason"))}
  end

  defp handle_event("publish_skipped", event, steps, current) do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "publish",
       label: "Publish (skipped)",
       status: "skipped",
       started_at: timestamp(event),
       ended_at: timestamp(event),
       duration_ms: 0,
       cycle: nil,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{reason: str_field(event, "reason")}
     }}
  end

  # --- Pending merge / preview ---

  defp handle_event("publish_pending_merge", event, steps, %{kind: "publish"} = current) do
    detail = Map.put(current.detail, :pending_merge, true)
    {steps, %{current | detail: detail, events: current.events ++ [event]}}
  end

  defp handle_event("publish_pending_merge", event, steps, current) do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "pending_merge",
       label: "Pending Merge",
       status: "ok",
       started_at: timestamp(event),
       ended_at: timestamp(event),
       duration_ms: 0,
       cycle: nil,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{
         branch: str_field(event, "branch"),
         reason: str_field(event, "reason")
       }
     }}
  end

  defp handle_event("preview_runtime_handoff", event, steps, current) do
    steps = close_step(steps, current, event)

    {steps,
     %{
       kind: "preview",
       label: "Preview",
       status: "ok",
       started_at: timestamp(event),
       ended_at: timestamp(event),
       duration_ms: 0,
       cycle: nil,
       turn: nil,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{
         story_id: str_field(event, "story_id"),
         runtime_kind: str_field(event, "runtime_kind")
       }
     }}
  end

  # --- Catch-all: fold unknown events into current step ---

  defp handle_event(_type, event, steps, nil), do: {steps, nil |> maybe_wrap_orphan(event)}

  defp handle_event(_type, event, steps, current) do
    {steps, %{current | events: current.events ++ [event]}}
  end

  defp maybe_wrap_orphan(nil, _event), do: nil

  # --- Helpers ---

  defp finalize(steps, nil, _run_in_progress), do: steps

  defp finalize(steps, current, run_in_progress) do
    step =
      if current.status == "running" and not run_in_progress,
        do: %{current | status: "interrupted"},
        else: current

    steps ++ [step]
  end

  defp close_step(steps, step_or_nil, event \\ nil)
  defp close_step(steps, nil, _event), do: steps

  defp close_step(steps, step, event) do
    step =
      if step.status == "running" do
        ended_at = if event, do: timestamp(event), else: step.started_at

        duration_ms =
          case {step.started_at, ended_at} do
            {s, e} when is_binary(s) and is_binary(e) -> duration_between(s, e)
            _ -> nil
          end

        %{step | status: "interrupted", ended_at: ended_at, duration_ms: duration_ms}
      else
        step
      end

    steps ++ [step]
  end

  defp finish_step(step, event, status, error \\ nil) do
    ended_at = timestamp(event)
    final_error = error || step.error

    recovery_guidance =
      recovery_guidance_from_event(event) ||
        recovery_guidance_from_step(step) ||
        RecoveryGuidance.parse(final_error)

    detail =
      if recovery_guidance do
        (step.detail || %{})
        |> Map.put(:recovery_guidance, recovery_guidance)
      else
        step.detail || %{}
      end

    duration_ms =
      case {step.started_at, ended_at} do
        {s, e} when is_binary(s) and is_binary(e) -> duration_between(s, e)
        _ -> nil
      end

    %{
      step
      | status: status,
        ended_at: ended_at,
        duration_ms: duration_ms,
        error: final_error,
        detail: detail,
        events: step.events ++ [event]
    }
  end

  defp recovery_guidance_from_step(step) when is_map(step) do
    step
    |> Map.get(:detail, %{})
    |> map_field(:recovery_guidance)
    |> RecoveryGuidance.normalize()
  end

  defp recovery_guidance_from_step(_step), do: nil

  defp recovery_guidance_from_event(event) when is_map(event) do
    RecoveryGuidance.normalize(map_field(event, :recovery_guidance)) ||
      RecoveryGuidance.parse(map_field(event, :reason)) ||
      RecoveryGuidance.parse(map_field(event, :error))
  end

  defp recovery_guidance_from_event(_event), do: nil

  defp update_last_check(detail, event, status) do
    checks =
      case detail.checks do
        [] ->
          []

        checks ->
          {last, rest} = List.pop_at(checks, -1)

          rest ++
            [
              %{
                last
                | status: status,
                  duration_ms: int_field(event, "duration_ms")
              }
            ]
      end

    %{detail | checks: checks}
  end

  defp event_type(event) do
    to_string(Map.get(event, "type") || Map.get(event, :type) || "")
  end

  defp map_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_field(_map, _key), do: nil

  defp prompt_step(event) do
    %{
      kind: "prompt_captured",
      label: "Prompt (#{str_field(event, "phase") || "agent"})",
      status: "ok",
      started_at: timestamp(event),
      ended_at: timestamp(event),
      duration_ms: 0,
      cycle: nil,
      turn: nil,
      prompt: str_field(event, "prompt"),
      events: [event],
      error: nil,
      detail: %{phase: str_field(event, "phase")}
    }
  end

  defp timestamp(event) do
    to_string(Map.get(event, "timestamp") || Map.get(event, :timestamp) || "")
  end

  defp str_field(event, key) do
    val = Map.get(event, key) || Map.get(event, String.to_existing_atom(key))
    if is_binary(val) and val != "", do: val, else: nil
  rescue
    ArgumentError -> nil
  end

  defp int_field(event, key) do
    val = Map.get(event, key) || Map.get(event, String.to_existing_atom(key))

    case val do
      n when is_integer(n) -> n
      s when is_binary(s) -> String.to_integer(s)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp duration_between(start_iso, end_iso) do
    with {:ok, s, _} <- DateTime.from_iso8601(start_iso),
         {:ok, e, _} <- DateTime.from_iso8601(end_iso) do
      DateTime.diff(e, s, :millisecond)
    else
      _ -> nil
    end
  end
end

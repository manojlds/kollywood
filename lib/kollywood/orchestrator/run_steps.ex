defmodule Kollywood.Orchestrator.RunSteps do
  @moduledoc """
  Parses a run's events.jsonl into a sequence of discrete pipeline steps.

  Each step represents a logical unit: an agent turn, a checks pass,
  a review cycle, a testing phase, or a runtime operation. Steps carry
  their own slice of events, timing, status, prompt, and phase metadata.
  """

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

  @doc "Parse events into an ordered list of pipeline steps."
  @spec from_events([map()]) :: [step()]
  def from_events(events) when is_list(events) do
    events
    |> scan_steps()
    |> Enum.with_index()
    |> Enum.map(fn {step, idx} -> Map.put(step, :idx, idx) end)
  end

  def from_events(_), do: []

  defp scan_steps(events) do
    {steps, current} =
      Enum.reduce(events, {[], nil}, fn event, {steps, current} ->
        type = event_type(event)
        handle_event(type, event, steps, current)
      end)

    finalize(steps, current)
  end

  # --- Agent turn (coding or remediation) ---

  defp handle_event("turn_started", event, steps, current) do
    steps = close_step(steps, current)
    turn = int_field(event, "turn")
    cycle = int_field(event, "checks_cycle")
    remediation = str_field(event, "remediation") == "true"

    label =
      cond do
        remediation and cycle -> "Remediation (Cycle #{cycle})"
        remediation -> "Remediation"
        true -> "Agent Turn #{turn || "?"}"
      end

    {steps,
     %{
       kind: if(remediation, do: "remediation", else: "agent_turn"),
       label: label,
       status: "running",
       started_at: timestamp(event),
       ended_at: nil,
       duration_ms: nil,
       cycle: cycle,
       turn: turn,
       prompt: nil,
       events: [event],
       error: nil,
       detail: %{}
     }}
  end

  defp handle_event("prompt_captured", event, steps, nil) do
    steps = close_step(steps, nil)

    {steps,
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
     }}
  end

  defp handle_event("prompt_captured", event, steps, current) do
    {steps, %{current | prompt: str_field(event, "prompt"), events: current.events ++ [event]}}
  end

  defp handle_event("turn_succeeded", event, steps, %{kind: kind} = current)
       when kind in ["agent_turn", "remediation"] do
    {steps, finish_step(current, event, "ok")}
  end

  defp handle_event("turn_failed", event, steps, %{kind: kind} = current)
       when kind in ["agent_turn", "remediation"] do
    {steps, finish_step(current, event, "failed", str_field(event, "reason"))}
  end

  # --- Checks ---

  defp handle_event("checks_started", event, steps, current) do
    steps = close_step(steps, current)

    cycle =
      int_field(event, "cycle") ||
        Enum.count(steps, fn s -> s.kind == "checks" end) + 1

    {steps,
     %{
       kind: "checks",
       label: "Checks (Cycle #{cycle})",
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
    steps = close_step(steps, current)
    cycle = int_field(event, "cycle")

    {steps,
     %{
       kind: "review",
       label: "Review (Cycle #{cycle || "?"})",
       status: "running",
       started_at: timestamp(event),
       ended_at: nil,
       duration_ms: nil,
       cycle: cycle,
       turn: nil,
       prompt: nil,
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
    steps = close_step(steps, current)
    cycle = int_field(event, "cycle")

    {steps,
     %{
       kind: "testing",
       label: "Testing (Cycle #{cycle || "?"})",
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
    steps = close_step(steps, current)

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
    steps = close_step(steps, current)

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
    steps = close_step(steps, current)

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
    steps = close_step(steps, current)

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
    steps = close_step(steps, current)
    status = str_field(event, "status") || "finished"
    reason = str_field(event, "reason")

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
      detail: %{}
    }

    {steps ++ [step], nil}
  end

  # --- Quality cycle markers ---

  defp handle_event("quality_cycle_started", event, steps, current) do
    steps = close_step(steps, current)
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
    steps = close_step(steps, current)

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
    steps = close_step(steps, current)

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
       when type in ["session_started", "session_stopped", "session_stop_failed"] do
    if current do
      {steps, %{current | events: current.events ++ [event]}}
    else
      {steps, current}
    end
  end

  # --- Publish ---

  defp handle_event("publish_started", event, steps, current) do
    steps = close_step(steps, current)

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
    steps = close_step(steps, current)

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
    steps = close_step(steps, current)

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
    steps = close_step(steps, current)

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

  defp finalize(steps, nil), do: steps
  defp finalize(steps, current), do: close_step(steps, current)

  defp close_step(steps, nil), do: steps

  defp close_step(steps, step) do
    step = if step.status == "running", do: %{step | status: "interrupted"}, else: step
    steps ++ [step]
  end

  defp finish_step(step, event, status, error \\ nil) do
    ended_at = timestamp(event)

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
        error: error || step.error,
        events: step.events ++ [event]
    }
  end

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

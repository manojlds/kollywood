defmodule Kollywood.Orchestrator.RunPhase do
  @moduledoc """
  Derives a user-facing run phase from runner events.

  The phase reducer is tolerant of sparse/unknown events: if an event cannot be
  mapped, the reducer keeps the last known phase.
  """

  @type phase_kind :: String.t()

  @type t :: %{
          required(:kind) => phase_kind(),
          required(:label) => String.t(),
          optional(:turn) => pos_integer(),
          optional(:check_index) => pos_integer(),
          optional(:check_count) => pos_integer(),
          optional(:review_cycle) => pos_integer(),
          optional(:event_type) => String.t(),
          optional(:timestamp) => DateTime.t() | String.t()
        }

  @spec unknown() :: t()
  def unknown, do: %{kind: "unknown", label: "Unknown phase"}

  @spec from_event(map(), t() | nil) :: t() | nil
  def from_event(event, last_phase \\ nil)

  def from_event(event, last_phase) when is_map(event) do
    event_type = event_type(event)

    phase =
      case event_type do
        "turn_started" ->
          turn = positive_integer_field(event, [:turn])
          agent_phase(turn, event_type)

        "turn_succeeded" ->
          turn = positive_integer_field(event, [:turn])
          agent_phase(turn, event_type)

        "session_started" ->
          %{kind: "agent", label: "Agent session started", event_type: event_type}

        "workspace_ready" ->
          %{kind: "agent", label: "Workspace ready", event_type: event_type}

        "run_started" ->
          %{kind: "agent", label: "Run started", event_type: event_type}

        "checks_started" ->
          check_count = positive_integer_field(event, [:check_count])

          label =
            if check_count do
              "Checks 0/#{check_count}"
            else
              "Checks"
            end

          phase(%{kind: "checks", label: label, check_count: check_count, event_type: event_type})

        "check_started" ->
          check_index = positive_integer_field(event, [:check_index])

          check_count =
            positive_integer_field(event, [:check_count]) || map_get(last_phase, :check_count)

          checks_phase(check_index, check_count, event_type)

        "check_passed" ->
          check_index = positive_integer_field(event, [:check_index])

          check_count =
            positive_integer_field(event, [:check_count]) || map_get(last_phase, :check_count)

          checks_phase(check_index, check_count, event_type)

        "check_failed" ->
          check_index = positive_integer_field(event, [:check_index])

          check_count =
            positive_integer_field(event, [:check_count]) || map_get(last_phase, :check_count)

          checks_phase(check_index, check_count, event_type)

        "checks_passed" ->
          check_count =
            positive_integer_field(event, [:check_count]) || map_get(last_phase, :check_count)

          label =
            if check_count,
              do: "Checks complete (#{check_count}/#{check_count})",
              else: "Checks complete"

          phase(%{kind: "checks", label: label, check_count: check_count, event_type: event_type})

        "checks_failed" ->
          failed_phase("Checks failed", event_type)

        "review_started" ->
          cycle = positive_integer_field(event, [:cycle])
          review_phase(cycle, "Review", event_type)

        "review_passed" ->
          cycle = positive_integer_field(event, [:cycle])
          review_phase(cycle, "Review passed", event_type)

        "review_failed" ->
          cycle = positive_integer_field(event, [:cycle])
          failed_phase(cycle_label("Review failed", cycle), event_type, cycle)

        "review_error" ->
          cycle = positive_integer_field(event, [:cycle])
          failed_phase(cycle_label("Review error", cycle), event_type, cycle)

        "publish_started" ->
          %{kind: "publish", label: "Publishing", event_type: event_type}

        "publish_push_succeeded" ->
          %{kind: "publish", label: "Publishing (push complete)", event_type: event_type}

        "publish_pr_created" ->
          %{kind: "publish", label: "Publishing (PR created)", event_type: event_type}

        "publish_merged" ->
          %{kind: "publish", label: "Publishing (merged)", event_type: event_type}

        "publish_succeeded" ->
          %{kind: "publish", label: "Publishing complete", event_type: event_type}

        "publish_skipped" ->
          %{kind: "publish", label: "Publish skipped", event_type: event_type}

        "publish_failed" ->
          failed_phase("Publishing failed", event_type)

        "publish_merge_failed" ->
          failed_phase("Publishing merge failed", event_type)

        "runtime_starting" ->
          %{kind: "runtime", label: "Runtime starting", event_type: event_type}

        "runtime_started" ->
          %{kind: "runtime", label: "Runtime running", event_type: event_type}

        "runtime_stopping" ->
          %{kind: "runtime", label: "Runtime stopping", event_type: event_type}

        "runtime_stopped" ->
          %{kind: "runtime", label: "Runtime stopped", event_type: event_type}

        "runtime_start_failed" ->
          failed_phase("Runtime failed to start", event_type)

        "runtime_stop_failed" ->
          failed_phase("Runtime failed to stop", event_type)

        "turn_failed" ->
          failed_phase("Agent turn failed", event_type)

        "run_finished" ->
          status = map_get(event, :status)

          case normalize_status(status) do
            "failed" -> failed_phase("Run failed", event_type)
            _other -> %{kind: "finished", label: "Run finished", event_type: event_type}
          end

        _other ->
          nil
      end

    phase
    |> maybe_put_timestamp(map_get(event, :timestamp))
    |> choose_phase(last_phase)
  end

  def from_event(_event, last_phase), do: last_phase

  @spec from_events([map()], keyword()) :: t()
  def from_events(events, opts \\ []) when is_list(events) do
    initial_phase = Keyword.get(opts, :initial_phase)

    phase =
      Enum.reduce(events, initial_phase, fn event, acc ->
        from_event(event, acc)
      end)

    case phase do
      nil -> unknown()
      phase_map -> phase_map
    end
  end

  @spec from_status(String.t() | atom() | nil, t() | nil) :: t()
  def from_status(status, last_phase \\ nil) do
    case normalize_status(status) do
      "finished" -> %{kind: "finished", label: "Run finished"}
      "ok" -> %{kind: "finished", label: "Run finished"}
      "failed" -> %{kind: "failed", label: "Run failed"}
      "error" -> %{kind: "failed", label: "Run failed"}
      "stopped" -> %{kind: "failed", label: "Run stopped"}
      "running" -> last_phase || %{kind: "unknown", label: "Run in progress"}
      _other -> last_phase || unknown()
    end
  end

  @spec label(t() | nil) :: String.t()
  def label(%{label: label}) when is_binary(label), do: label
  def label(_phase), do: unknown().label

  defp agent_phase(turn, event_type) do
    label = if turn, do: "Agent turn #{turn}", else: "Agent turn"
    phase(%{kind: "agent", label: label, turn: turn, event_type: event_type})
  end

  defp checks_phase(check_index, check_count, event_type) do
    label =
      cond do
        check_index && check_count -> "Checks #{check_index}/#{check_count}"
        check_index -> "Check #{check_index}"
        check_count -> "Checks ?/#{check_count}"
        true -> "Checks"
      end

    phase(%{
      kind: "checks",
      label: label,
      check_index: check_index,
      check_count: check_count,
      event_type: event_type
    })
  end

  defp review_phase(cycle, prefix, event_type) do
    label = cycle_label(prefix, cycle)
    phase(%{kind: "review", label: label, review_cycle: cycle, event_type: event_type})
  end

  defp failed_phase(label, event_type, review_cycle \\ nil) do
    phase(%{kind: "failed", label: label, review_cycle: review_cycle, event_type: event_type})
  end

  defp cycle_label(prefix, cycle) when is_integer(cycle), do: "#{prefix} cycle #{cycle}"
  defp cycle_label(prefix, _cycle), do: prefix

  defp maybe_put_timestamp(nil, _timestamp), do: nil
  defp maybe_put_timestamp(phase, nil), do: phase

  defp maybe_put_timestamp(phase, timestamp) do
    Map.put(phase, :timestamp, timestamp)
  end

  defp choose_phase(nil, last_phase), do: last_phase
  defp choose_phase(phase, nil), do: phase

  defp choose_phase(phase, last_phase) do
    if stale_phase?(phase, last_phase) do
      last_phase
    else
      phase
    end
  end

  defp stale_phase?(phase, last_phase) do
    case {timestamp_datetime(phase), timestamp_datetime(last_phase)} do
      {%DateTime{} = phase_timestamp, %DateTime{} = last_timestamp} ->
        DateTime.compare(phase_timestamp, last_timestamp) == :lt

      _other ->
        false
    end
  end

  defp timestamp_datetime(%{} = phase) do
    phase
    |> map_get(:timestamp)
    |> normalize_timestamp()
  end

  defp timestamp_datetime(_phase), do: nil

  defp normalize_timestamp(%DateTime{} = timestamp), do: timestamp

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(String.trim(timestamp)) do
      {:ok, parsed, _offset} -> parsed
      _other -> nil
    end
  end

  defp normalize_timestamp(_timestamp), do: nil

  defp normalize_status(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_status(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_status()

  defp normalize_status(_value), do: ""

  defp phase(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp event_type(event) do
    value = map_get(event, :type)

    cond do
      is_binary(value) -> value
      is_atom(value) -> Atom.to_string(value)
      true -> ""
    end
  end

  defp positive_integer_field(event, keys) when is_list(keys) do
    keys
    |> Enum.find_value(fn key ->
      case map_get(event, key) do
        value when is_integer(value) and value > 0 -> value
        value when is_binary(value) -> parse_positive_integer(value)
        _other -> nil
      end
    end)
  end

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp map_get(map, key) when is_atom(key) do
    if is_map(map) do
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> Map.get(map, Atom.to_string(key))
      end
    else
      nil
    end
  end

  defp map_get(map, key) when is_binary(key) do
    if is_map(map) do
      case Map.fetch(map, key) do
        {:ok, value} ->
          value

        :error ->
          case maybe_existing_atom(key) do
            nil -> nil
            atom_key -> Map.get(map, atom_key)
          end
      end
    else
      nil
    end
  end

  defp maybe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end

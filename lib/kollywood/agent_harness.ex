defmodule Kollywood.AgentHarness do
  @moduledoc false

  alias Kollywood.Config

  @default_timeout_ms 7_200_000
  @default_max_turns 20
  @valid_agent_kinds ~w(claude codex cursor opencode pi)a

  @type phase :: :agent | :review | :testing
  @type profile :: %{
          phase: phase(),
          role: map(),
          harness: map(),
          session_agent: map(),
          session_config: Config.t()
        }

  @spec resolve(Config.t(), phase(), keyword()) :: profile()
  def resolve(%Config{} = config, phase, opts \\ []) when phase in [:agent, :review, :testing] do
    base_agent = map_or_empty(Map.get(config, :agent))
    base_kind = resolve_agent_kind(Map.get(base_agent, :kind), :opencode)
    base_harness = base_harness(base_agent)
    base_role = base_role(base_agent, base_kind)

    {role, harness} =
      case phase do
        :agent ->
          {base_role, base_harness}

        :review ->
          review_profile(config, base_role, base_harness)

        :testing ->
          testing_profile(config, base_role, base_harness, opts)
      end

    session_agent =
      base_agent
      |> Map.put(:kind, Map.get(role, :kind, base_kind))
      |> Map.put(:max_turns, Map.get(role, :max_turns, 1))
      |> Map.put(:command, Map.get(harness, :command))
      |> Map.put(:model, Map.get(harness, :model))
      |> Map.put(:args, Map.get(harness, :args, []))
      |> Map.put(:env, Map.get(harness, :env, %{}))
      |> Map.put(:timeout_ms, Map.get(harness, :timeout_ms, @default_timeout_ms))

    %{
      phase: phase,
      role: role,
      harness: harness,
      session_agent: session_agent,
      session_config: %Config{config | agent: session_agent}
    }
  end

  defp base_role(base_agent, kind) do
    %{
      kind: kind,
      max_turns: positive_integer(Map.get(base_agent, :max_turns), @default_max_turns),
      completion_signals: string_list(Map.get(base_agent, :completion_signals, [])),
      idle_timeout_ms: positive_integer(Map.get(base_agent, :idle_timeout_ms), nil)
    }
  end

  defp base_harness(base_agent) do
    %{
      command: optional_string(Map.get(base_agent, :command)),
      model: optional_string(Map.get(base_agent, :model)),
      args: string_list(Map.get(base_agent, :args, [])),
      env: string_map(Map.get(base_agent, :env, %{})),
      timeout_ms: positive_integer(Map.get(base_agent, :timeout_ms), @default_timeout_ms)
    }
  end

  defp review_profile(%Config{} = config, base_role, base_harness) do
    review = map_or_empty(Map.get(config, :review))
    review_agent = review |> Map.get(:agent) |> map_or_empty()
    explicit = truthy?(Map.get(review_agent, :explicit, false))

    quality_limit = quality_max_cycles(config)

    role = %{
      enabled: truthy?(Map.get(review, :enabled, false)),
      kind:
        if(explicit,
          do: resolve_agent_kind(Map.get(review_agent, :kind), Map.get(base_role, :kind)),
          else: Map.get(base_role, :kind)
        ),
      max_turns: 1,
      max_cycles:
        positive_integer(Map.get(review, :max_cycles), quality_limit) |> min(quality_limit),
      prompt_template: optional_string(Map.get(review, :prompt_template)),
      explicit: explicit
    }

    harness =
      merge_harness(base_harness, review_agent, explicit,
        timeout_fallback: Map.get(base_harness, :timeout_ms, @default_timeout_ms)
      )

    {role, harness}
  end

  defp testing_profile(%Config{} = config, base_role, base_harness, opts) do
    testing = map_or_empty(Map.get(config, :testing))
    testing_agent = testing |> Map.get(:agent) |> map_or_empty()
    explicit = truthy?(Map.get(testing_agent, :explicit, false))

    quality_limit = quality_max_cycles(config)
    phase_timeout_ms = positive_integer(Map.get(testing, :timeout_ms), @default_timeout_ms)
    runtime_env = opts |> Keyword.get(:runtime_env, %{}) |> string_map()

    role = %{
      enabled: truthy?(Map.get(testing, :enabled, false)),
      kind:
        if(explicit,
          do: resolve_agent_kind(Map.get(testing_agent, :kind), Map.get(base_role, :kind)),
          else: Map.get(base_role, :kind)
        ),
      max_turns: 1,
      max_cycles:
        positive_integer(Map.get(testing, :max_cycles), quality_limit) |> min(quality_limit),
      timeout_ms: phase_timeout_ms,
      prompt_template: optional_string(Map.get(testing, :prompt_template)),
      explicit: explicit
    }

    harness =
      merge_harness(base_harness, testing_agent, explicit,
        timeout_fallback: phase_timeout_ms,
        env_overrides: runtime_env
      )

    {role, harness}
  end

  defp merge_harness(base_harness, phase_agent, explicit, opts) do
    timeout_fallback = positive_integer(Keyword.get(opts, :timeout_fallback), @default_timeout_ms)
    env_overrides = string_map(Keyword.get(opts, :env_overrides, %{}))

    command =
      if explicit do
        optional_string(Map.get(phase_agent, :command)) || Map.get(base_harness, :command)
      else
        Map.get(base_harness, :command)
      end

    model =
      if explicit do
        optional_string(Map.get(phase_agent, :model)) || Map.get(base_harness, :model)
      else
        Map.get(base_harness, :model)
      end

    args =
      if explicit do
        case string_list(Map.get(phase_agent, :args, [])) do
          [] -> Map.get(base_harness, :args, [])
          value -> value
        end
      else
        Map.get(base_harness, :args, [])
      end

    env =
      base_harness
      |> Map.get(:env, %{})
      |> Map.merge(if(explicit, do: string_map(Map.get(phase_agent, :env, %{})), else: %{}))
      |> Map.merge(env_overrides)

    timeout_ms =
      if explicit do
        positive_integer(
          Map.get(
            phase_agent,
            :timeout_ms,
            Map.get(base_harness, :timeout_ms, timeout_fallback)
          ),
          timeout_fallback
        )
      else
        positive_integer(Map.get(base_harness, :timeout_ms), timeout_fallback)
      end

    %{
      command: command,
      model: model,
      args: args,
      env: env,
      timeout_ms: timeout_ms
    }
  end

  defp quality_max_cycles(%Config{} = config) do
    config
    |> Map.get(:quality)
    |> map_or_empty()
    |> Map.get(:max_cycles)
    |> positive_integer(1)
  end

  defp resolve_agent_kind(value, _fallback) when value in @valid_agent_kinds, do: value
  defp resolve_agent_kind(_value, fallback), do: fallback

  defp optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp optional_string(_value), do: nil

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp string_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_value), do: []

  defp string_map(value) when is_map(value) do
    Map.new(value, fn {key, val} ->
      {to_string(key), to_string(val)}
    end)
  end

  defp string_map(_value), do: %{}

  defp truthy?(value) when is_boolean(value), do: value

  defp truthy?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "true" -> true
      "1" -> true
      "yes" -> true
      "on" -> true
      _other -> false
    end
  end

  defp truthy?(_value), do: false

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback
end

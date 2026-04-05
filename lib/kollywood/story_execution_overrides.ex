defmodule Kollywood.StoryExecutionOverrides do
  @moduledoc """
  Resolves and validates story-level execution overrides.

  Supported story settings:

    * `settings.execution.agent_kind`
    * `settings.execution.review_agent_kind`
    * `settings.execution.review_max_cycles`
    * `settings.execution.testing_enabled`
    * `settings.execution.preview_enabled`
    * `settings.execution.testing_agent_kind`
    * `settings.execution.testing_max_cycles`
  """

  alias Kollywood.Config

  @valid_agent_kinds ~w(amp claude codex cursor opencode pi)a
  @valid_agent_kind_strings Enum.map(@valid_agent_kinds, &Atom.to_string/1)

  @execution_keys ~w(
    agent_kind
    review_agent_kind
    review_max_cycles
    testing_enabled
    preview_enabled
    testing_agent_kind
    testing_max_cycles
    agentKind
    reviewAgentKind
    reviewMaxCycles
    testingEnabled
    previewEnabled
    testingAgentKind
    testingMaxCycles
  )

  @type overrides :: %{
          optional(:agent_kind) => Config.agent_kind(),
          optional(:review_agent_kind) => Config.agent_kind(),
          optional(:review_max_cycles) => pos_integer(),
          optional(:testing_enabled) => boolean(),
          optional(:preview_enabled) => boolean(),
          optional(:testing_agent_kind) => Config.agent_kind(),
          optional(:testing_max_cycles) => pos_integer()
        }

  @type resolved :: %{
          config: Config.t(),
          overrides: overrides(),
          settings_snapshot: map()
        }

  @spec valid_agent_kind_strings() :: [String.t()]
  def valid_agent_kind_strings, do: @valid_agent_kind_strings

  @doc """
  Validates and normalizes a story `settings` map for persistence.

  Returns `%{}` when no supported execution override keys are present.
  """
  @spec normalize_settings(map() | nil) :: {:ok, map()} | {:error, String.t()}
  def normalize_settings(nil), do: {:ok, %{}}

  def normalize_settings(settings) when is_map(settings) do
    with {:ok, overrides} <- parse_execution_overrides(settings) do
      execution = overrides_to_settings_execution(overrides)
      {:ok, if(execution == %{}, do: %{}, else: %{"execution" => execution})}
    end
  end

  def normalize_settings(_settings), do: {:error, "story settings must be an object"}

  @doc """
  Resolves effective runtime config by applying validated story overrides.
  """
  @spec resolve(Config.t(), map()) :: {:ok, resolved()} | {:error, String.t()}
  def resolve(%Config{} = config, issue) when is_map(issue) do
    with {:ok, overrides} <- parse_issue_overrides(issue) do
      resolved = apply_overrides(config, overrides)
      {:ok, resolved}
    end
  end

  def resolve(_config, _issue),
    do: {:error, "story overrides require a valid config and issue map"}

  @doc """
  Builds a run-settings snapshot from a resolved config.
  """
  @spec snapshot(Config.t(), overrides()) :: map()
  def snapshot(%Config{} = config, overrides \\ %{}) do
    agent_kind =
      config
      |> Map.get(:agent, %{})
      |> map_or_empty()
      |> Map.get(:kind)
      |> resolve_existing_agent_kind(:amp)

    review = map_or_empty(Map.get(config, :review))
    review_agent = map_or_empty(Map.get(review, :agent))
    review_explicit = Map.get(review_agent, :explicit, false) == true

    review_kind =
      if review_explicit do
        resolve_existing_agent_kind(Map.get(review_agent, :kind), agent_kind)
      else
        agent_kind
      end

    quality_max = quality_max_cycles(config)
    review_max = positive_integer(Map.get(review, :max_cycles), quality_max) |> min(quality_max)
    testing = map_or_empty(Map.get(config, :testing))
    testing_agent = map_or_empty(Map.get(testing, :agent))
    testing_explicit = Map.get(testing_agent, :explicit, false) == true

    testing_kind =
      if testing_explicit do
        resolve_existing_agent_kind(Map.get(testing_agent, :kind), agent_kind)
      else
        agent_kind
      end

    testing_max = positive_integer(Map.get(testing, :max_cycles), quality_max) |> min(quality_max)
    preview = map_or_empty(Map.get(config, :preview))

    %{
      "agent_kind" => Atom.to_string(agent_kind),
      "review_agent_kind" => Atom.to_string(review_kind),
      "review_max_cycles" => review_max,
      "testing_enabled" => truthy?(Map.get(testing, :enabled, false)),
      "testing_agent_kind" => Atom.to_string(testing_kind),
      "testing_max_cycles" => testing_max,
      "preview_enabled" => truthy?(Map.get(preview, :enabled, false)),
      "story_overrides" => overrides_to_snapshot(overrides)
    }
  end

  defp parse_issue_overrides(issue) do
    case field(issue, :settings) do
      nil ->
        {:ok, %{}}

      settings when is_map(settings) ->
        parse_execution_overrides(settings)

      _other ->
        {:error, "story settings must be an object"}
    end
  end

  defp parse_execution_overrides(settings) when is_map(settings) do
    with {:ok, execution} <- extract_execution_map(settings),
         :ok <- validate_execution_keys(execution),
         {:ok, agent_kind} <-
           parse_optional_agent_kind(
             fetch_input(execution, [:agent_kind, :agentKind]),
             "story settings.execution.agent_kind"
           ),
         {:ok, review_agent_kind} <-
           parse_optional_agent_kind(
             fetch_input(execution, [:review_agent_kind, :reviewAgentKind]),
             "story settings.execution.review_agent_kind"
           ),
         {:ok, review_max_cycles} <-
           parse_optional_positive_integer(
             fetch_input(execution, [:review_max_cycles, :reviewMaxCycles]),
             "story settings.execution.review_max_cycles"
           ),
         {:ok, testing_enabled} <-
           parse_optional_boolean(
             fetch_input(execution, [:testing_enabled, :testingEnabled]),
             "story settings.execution.testing_enabled"
           ),
         {:ok, preview_enabled} <-
           parse_optional_boolean(
             fetch_input(execution, [:preview_enabled, :previewEnabled]),
             "story settings.execution.preview_enabled"
           ),
         {:ok, testing_agent_kind} <-
           parse_optional_agent_kind(
             fetch_input(execution, [:testing_agent_kind, :testingAgentKind]),
             "story settings.execution.testing_agent_kind"
           ),
         {:ok, testing_max_cycles} <-
           parse_optional_positive_integer(
             fetch_input(execution, [:testing_max_cycles, :testingMaxCycles]),
             "story settings.execution.testing_max_cycles"
           ) do
      overrides =
        %{}
        |> maybe_put(:agent_kind, agent_kind)
        |> maybe_put(:review_agent_kind, review_agent_kind)
        |> maybe_put(:review_max_cycles, review_max_cycles)
        |> maybe_put(:testing_enabled, testing_enabled)
        |> maybe_put(:preview_enabled, preview_enabled)
        |> maybe_put(:testing_agent_kind, testing_agent_kind)
        |> maybe_put(:testing_max_cycles, testing_max_cycles)

      {:ok, overrides}
    end
  end

  defp parse_execution_overrides(_settings), do: {:error, "story settings must be an object"}

  defp extract_execution_map(settings) do
    execution_present? = has_field?(settings, :execution)
    execution = fetch_input(settings, [:execution])

    cond do
      execution_present? and is_map(execution) ->
        {:ok, execution}

      execution_present? and execution in [nil, ""] ->
        {:ok, %{}}

      execution_present? ->
        {:error, "story settings.execution must be an object"}

      execution_key_present?(settings) ->
        {:ok, settings}

      true ->
        {:ok, %{}}
    end
  end

  defp execution_key_present?(map) when is_map(map) do
    keys = map |> Map.keys() |> Enum.map(&to_string/1)
    Enum.any?(@execution_keys, &(&1 in keys))
  end

  defp execution_key_present?(_), do: false

  defp validate_execution_keys(execution) when is_map(execution) do
    keys = execution |> Map.keys() |> Enum.map(&to_string/1)
    unknown = keys -- @execution_keys

    if unknown == [] do
      :ok
    else
      {:error,
       "story settings.execution includes unsupported fields: #{Enum.join(unknown, ", ")}. Allowed: agent_kind, review_agent_kind, review_max_cycles, testing_enabled, preview_enabled, testing_agent_kind, testing_max_cycles"}
    end
  end

  defp validate_execution_keys(_execution),
    do: {:error, "story settings.execution must be an object"}

  defp parse_optional_agent_kind(value, _label) when value in [nil, ""], do: {:ok, nil}

  defp parse_optional_agent_kind(value, label) do
    case parse_agent_kind(value) do
      {:ok, kind} ->
        {:ok, kind}

      {:error, _reason} ->
        {:error, "#{label} must be one of: #{Enum.join(@valid_agent_kind_strings, ", ")}"}
    end
  end

  defp parse_agent_kind(value) when is_atom(value) do
    if value in @valid_agent_kinds do
      {:ok, value}
    else
      {:error, "invalid"}
    end
  end

  defp parse_agent_kind(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    case Enum.find(@valid_agent_kinds, &(Atom.to_string(&1) == normalized)) do
      nil -> {:error, "invalid"}
      kind -> {:ok, kind}
    end
  end

  defp parse_agent_kind(_value), do: {:error, "invalid"}

  defp parse_optional_positive_integer(nil, _label), do: {:ok, nil}

  defp parse_optional_positive_integer(value, _label) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_optional_positive_integer(value, label) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:ok, nil}
    else
      case Integer.parse(trimmed) do
        {parsed, ""} when parsed > 0 -> {:ok, parsed}
        _other -> {:error, "#{label} must be a positive integer"}
      end
    end
  end

  defp parse_optional_positive_integer(_value, label),
    do: {:error, "#{label} must be a positive integer"}

  defp parse_optional_boolean(nil, _label), do: {:ok, nil}

  defp parse_optional_boolean(value, _label) when is_boolean(value), do: {:ok, value}

  defp parse_optional_boolean(value, label) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      normalized ->
        case String.downcase(normalized) do
          "true" -> {:ok, true}
          "false" -> {:ok, false}
          _other -> {:error, "#{label} must be a boolean"}
        end
    end
  end

  defp parse_optional_boolean(_value, label), do: {:error, "#{label} must be a boolean"}

  defp apply_overrides(%Config{} = config, overrides) do
    agent = map_or_empty(Map.get(config, :agent))
    review = map_or_empty(Map.get(config, :review))
    review_agent = map_or_empty(Map.get(review, :agent))
    testing = map_or_empty(Map.get(config, :testing))
    testing_agent = map_or_empty(Map.get(testing, :agent))
    preview = map_or_empty(Map.get(config, :preview))

    quality = map_or_empty(Map.get(config, :quality))
    quality_review = map_or_empty(Map.get(quality, :review))
    quality_review_agent = map_or_empty(Map.get(quality_review, :agent))
    quality_testing = map_or_empty(Map.get(quality, :testing))
    quality_testing_agent = map_or_empty(Map.get(quality_testing, :agent))

    current_agent_kind = resolve_existing_agent_kind(Map.get(agent, :kind), :amp)
    review_explicit = Map.get(review_agent, :explicit, false) == true
    testing_explicit = Map.get(testing_agent, :explicit, false) == true

    agent_kind = Map.get(overrides, :agent_kind, current_agent_kind)
    review_kind_override = Map.get(overrides, :review_agent_kind)
    has_review_kind_override = review_kind_override in @valid_agent_kinds
    testing_kind_override = Map.get(overrides, :testing_agent_kind)
    has_testing_kind_override = testing_kind_override in @valid_agent_kinds

    review_kind =
      cond do
        has_review_kind_override ->
          review_kind_override

        review_explicit ->
          resolve_existing_agent_kind(Map.get(review_agent, :kind), agent_kind)

        true ->
          agent_kind
      end

    testing_kind =
      cond do
        has_testing_kind_override ->
          testing_kind_override

        testing_explicit ->
          resolve_existing_agent_kind(Map.get(testing_agent, :kind), agent_kind)

        true ->
          agent_kind
      end

    review_explicit = review_explicit or has_review_kind_override
    testing_explicit = testing_explicit or has_testing_kind_override

    quality_max = quality_max_cycles(config)
    default_review_max = positive_integer(Map.get(review, :max_cycles), quality_max)
    requested_review_max = Map.get(overrides, :review_max_cycles, default_review_max)
    default_testing_max = positive_integer(Map.get(testing, :max_cycles), quality_max)
    requested_testing_max = Map.get(overrides, :testing_max_cycles, default_testing_max)

    review_max_cycles =
      requested_review_max |> positive_integer(default_review_max) |> min(quality_max)

    testing_max_cycles =
      requested_testing_max |> positive_integer(default_testing_max) |> min(quality_max)

    testing_enabled =
      case Map.fetch(overrides, :testing_enabled) do
        {:ok, value} when is_boolean(value) -> value
        _other -> false
      end

    preview_enabled =
      case Map.fetch(overrides, :preview_enabled) do
        {:ok, value} when is_boolean(value) -> value
        _other -> truthy?(Map.get(preview, :enabled, false))
      end

    resolved_agent = Map.put(agent, :kind, agent_kind)

    resolved_review_agent =
      review_agent
      |> Map.put(:kind, review_kind)
      |> Map.put(:explicit, review_explicit)

    resolved_review =
      review
      |> Map.put(:agent, resolved_review_agent)
      |> Map.put(:max_cycles, review_max_cycles)

    resolved_testing_agent =
      testing_agent
      |> Map.put(:kind, testing_kind)
      |> Map.put(:explicit, testing_explicit)

    resolved_testing =
      testing
      |> Map.put(:agent, resolved_testing_agent)
      |> Map.put(:max_cycles, testing_max_cycles)
      |> Map.put(:enabled, testing_enabled)

    resolved_quality_review_agent =
      quality_review_agent
      |> Map.put(:kind, review_kind)
      |> Map.put(:explicit, review_explicit)

    resolved_quality_review =
      quality_review
      |> Map.put(:agent, resolved_quality_review_agent)
      |> Map.put(:max_cycles, review_max_cycles)

    resolved_quality_testing_agent =
      quality_testing_agent
      |> Map.put(:kind, testing_kind)
      |> Map.put(:explicit, testing_explicit)

    resolved_quality_testing =
      quality_testing
      |> Map.put(:agent, resolved_quality_testing_agent)
      |> Map.put(:max_cycles, testing_max_cycles)
      |> Map.put(:enabled, testing_enabled)

    resolved_quality =
      quality
      |> Map.put(:review, resolved_quality_review)
      |> Map.put(:testing, resolved_quality_testing)

    resolved_preview =
      preview
      |> Map.put(:enabled, preview_enabled)

    resolved_config = %{
      config
      | agent: resolved_agent,
        review: resolved_review,
        testing: resolved_testing,
        quality: resolved_quality,
        preview: resolved_preview
    }

    %{
      config: resolved_config,
      overrides: overrides,
      settings_snapshot: snapshot(resolved_config, overrides)
    }
  end

  defp overrides_to_settings_execution(overrides) when map_size(overrides) == 0, do: %{}

  defp overrides_to_settings_execution(overrides) do
    overrides
    |> Enum.reduce(%{}, fn
      {:agent_kind, kind}, acc -> Map.put(acc, "agent_kind", Atom.to_string(kind))
      {:review_agent_kind, kind}, acc -> Map.put(acc, "review_agent_kind", Atom.to_string(kind))
      {:review_max_cycles, value}, acc -> Map.put(acc, "review_max_cycles", value)
      {:testing_enabled, value}, acc -> Map.put(acc, "testing_enabled", value)
      {:preview_enabled, value}, acc -> Map.put(acc, "preview_enabled", value)
      {:testing_agent_kind, kind}, acc -> Map.put(acc, "testing_agent_kind", Atom.to_string(kind))
      {:testing_max_cycles, value}, acc -> Map.put(acc, "testing_max_cycles", value)
    end)
  end

  defp overrides_to_snapshot(overrides) when map_size(overrides) == 0, do: %{}
  defp overrides_to_snapshot(overrides), do: overrides_to_settings_execution(overrides)

  defp quality_max_cycles(config) do
    quality = config |> Map.get(:quality, %{}) |> map_or_empty()

    case Map.get(quality, :max_cycles) do
      value when not is_nil(value) ->
        positive_integer(value, 1)

      _other ->
        config
        |> Map.get(:review, %{})
        |> map_or_empty()
        |> Map.get(:max_cycles, 1)
        |> positive_integer(1)
    end
  end

  defp resolve_existing_agent_kind(value, fallback) do
    case parse_agent_kind(value) do
      {:ok, kind} -> kind
      {:error, _reason} -> fallback
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

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

  defp fetch_input(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, nil, fn key ->
      cond do
        Map.has_key?(map, key) ->
          Map.get(map, key)

        is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
          Map.get(map, Atom.to_string(key))

        true ->
          nil
      end
    end)
  end

  defp fetch_input(_map, _keys), do: nil

  defp has_field?(map, key) when is_map(map) and is_atom(key) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp has_field?(_map, _key), do: false

  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_map, _key), do: nil
end

defmodule Kollywood.Orchestrator.RunSettingsSnapshot do
  @moduledoc """
  Builds immutable run settings snapshots stored in run-attempt metadata.

  Snapshots capture:

  - workflow identity/fingerprint at run start
  - resolved execution settings used by runner/review/check/publish/runtime phases
  - lightweight source markers indicating where values came from
  """

  alias Kollywood.Config
  alias Kollywood.WorkflowStore

  @default_timeout_ms 7_200_000

  @spec build(Config.t(), keyword()) :: map()
  def build(%Config{} = config, opts \\ []) do
    workflow_identity =
      opts
      |> Keyword.get(:workflow_identity)
      |> normalize_workflow_identity(config)

    %{
      "schema_version" => 1,
      "captured_at" => now_iso8601(),
      "workflow" => workflow_identity,
      "resolved" => %{
        "agent" => stringify_map(config.agent || %{}),
        "review" => stringify_map(resolved_review_settings(config)),
        "testing" => stringify_map(resolved_testing_settings(config)),
        "checks" => stringify_map(resolved_checks_settings(config)),
        "publish" => stringify_map(resolved_publish_settings(config)),
        "runtime" => stringify_map(resolved_runtime_settings(config)),
        "preview" => stringify_map(resolved_preview_settings(config))
      },
      "sources" => %{
        "agent" => agent_source_markers(config),
        "review" => review_source_markers(config),
        "testing" => testing_source_markers(config),
        "checks" => checks_source_markers(config),
        "publish" => publish_source_markers(config),
        "runtime" => runtime_source_markers(config),
        "preview" => preview_source_markers(config)
      }
    }
  end

  @spec workflow_identity(any(), Config.t()) :: map()
  def workflow_identity(workflow_store, %Config{} = config) do
    workflow_store
    |> workflow_store_identity()
    |> normalize_workflow_identity(config)
  end

  @spec workflow_identity_from_file(String.t(), String.t()) :: map()
  def workflow_identity_from_file(path, content) when is_binary(path) and is_binary(content) do
    %{
      "path" => Path.expand(path),
      "sha256" => sha256_hex(content),
      "identity_source" => "workflow_file"
    }
  end

  def workflow_identity_from_file(_path, _content), do: %{}

  defp workflow_store_identity(%Config{}), do: %{}

  defp workflow_store_identity(workflow_store) do
    case WorkflowStore.get_workflow_identity(workflow_store) do
      identity when is_map(identity) -> identity
      _other -> %{}
    end
  rescue
    _error ->
      %{}
  catch
    :exit, _reason ->
      %{}
  end

  defp normalize_workflow_identity(identity, %Config{} = config) when is_map(identity) do
    identity = stringify_map(identity)
    file_stamp = map_or_empty(Map.get(identity, "file_stamp"))

    path = optional_string(Map.get(identity, "path"))

    sha256 =
      optional_string(Map.get(identity, "sha256")) ||
        optional_string(Map.get(identity, "hash")) ||
        config_sha256(config)

    source =
      optional_string(Map.get(identity, "identity_source")) ||
        if(path, do: "workflow_file", else: "config_hash")

    %{
      "path" => path,
      "sha256" => sha256,
      "identity_source" => source
    }
    |> maybe_put("file_stamp", if(file_stamp == %{}, do: nil, else: file_stamp))
    |> maybe_put("version", optional_string(Map.get(identity, "version")))
  end

  defp normalize_workflow_identity(_identity, %Config{} = config) do
    %{
      "path" => nil,
      "sha256" => config_sha256(config),
      "identity_source" => "config_hash"
    }
  end

  defp resolved_review_settings(%Config{} = config) do
    review = review_config(config)
    review_agent = map_or_empty(Map.get(review, :agent))
    review_agent_explicit = truthy?(Map.get(review_agent, :explicit, false))
    quality_limit = quality_max_cycles(config)

    %{
      enabled: truthy?(Map.get(review, :enabled, false)),
      max_cycles: positive_integer(Map.get(review, :max_cycles), quality_limit),
      prompt_template: optional_string(Map.get(review, :prompt_template)),
      agent_explicit: review_agent_explicit,
      agent: resolved_review_agent(config, review_agent, review_agent_explicit)
    }
  end

  defp resolved_review_agent(%Config{} = config, review_agent, true) do
    base_agent = map_or_empty(Map.get(config, :agent))

    base_agent
    |> Map.put(:kind, Map.get(review_agent, :kind, Map.get(base_agent, :kind)))
    |> Map.put(:max_turns, 1)
    |> maybe_put(:command, Map.get(review_agent, :command))
    |> maybe_put_list(:args, Map.get(review_agent, :args))
    |> Map.put(
      :env,
      Map.merge(
        map_or_empty(Map.get(base_agent, :env)),
        map_or_empty(Map.get(review_agent, :env))
      )
    )
    |> Map.put(
      :timeout_ms,
      positive_integer(
        Map.get(review_agent, :timeout_ms, Map.get(base_agent, :timeout_ms, @default_timeout_ms)),
        @default_timeout_ms
      )
    )
  end

  defp resolved_review_agent(%Config{} = config, _review_agent, false) do
    config
    |> Map.get(:agent)
    |> map_or_empty()
    |> Map.put(:max_turns, 1)
  end

  defp resolved_checks_settings(%Config{} = config) do
    checks = checks_config(config)
    quality_limit = quality_max_cycles(config)

    %{
      required: string_list(Map.get(checks, :required, [])),
      timeout_ms: positive_integer(Map.get(checks, :timeout_ms), @default_timeout_ms),
      fail_fast: truthy?(Map.get(checks, :fail_fast, true)),
      max_cycles: positive_integer(Map.get(checks, :max_cycles), quality_limit)
    }
  end

  defp resolved_testing_settings(%Config{} = config) do
    testing = testing_config(config)
    testing_agent = map_or_empty(Map.get(testing, :agent))
    testing_agent_explicit = truthy?(Map.get(testing_agent, :explicit, false))
    quality_limit = quality_max_cycles(config)

    %{
      enabled: truthy?(Map.get(testing, :enabled, false)),
      max_cycles: positive_integer(Map.get(testing, :max_cycles), quality_limit),
      timeout_ms: positive_integer(Map.get(testing, :timeout_ms), @default_timeout_ms),
      prompt_template: optional_string(Map.get(testing, :prompt_template)),
      agent_explicit: testing_agent_explicit,
      agent: resolved_testing_agent(config, testing_agent, testing_agent_explicit)
    }
  end

  defp resolved_testing_agent(%Config{} = config, testing_agent, true) do
    base_agent = map_or_empty(Map.get(config, :agent))

    base_agent
    |> Map.put(:kind, Map.get(testing_agent, :kind, Map.get(base_agent, :kind)))
    |> Map.put(:max_turns, 1)
    |> maybe_put(:command, Map.get(testing_agent, :command))
    |> maybe_put_list(:args, Map.get(testing_agent, :args))
    |> Map.put(
      :env,
      Map.merge(
        map_or_empty(Map.get(base_agent, :env)),
        map_or_empty(Map.get(testing_agent, :env))
      )
    )
    |> Map.put(
      :timeout_ms,
      positive_integer(
        Map.get(
          testing_agent,
          :timeout_ms,
          Map.get(base_agent, :timeout_ms, @default_timeout_ms)
        ),
        @default_timeout_ms
      )
    )
  end

  defp resolved_testing_agent(%Config{} = config, _testing_agent, false) do
    config
    |> Map.get(:agent)
    |> map_or_empty()
    |> Map.put(:max_turns, 1)
  end

  defp resolved_publish_settings(%Config{} = config) do
    publish = map_or_empty(Map.get(config, :publish))
    git = map_or_empty(Map.get(config, :git))

    %{
      provider: Config.effective_publish_provider(config),
      mode: Config.effective_publish_mode(config),
      auto_push: Map.get(publish, :auto_push),
      auto_merge: Map.get(publish, :auto_merge),
      auto_create_pr: Map.get(publish, :auto_create_pr),
      base_branch: optional_string(Map.get(git, :base_branch)) || "main"
    }
  end

  defp resolved_preview_settings(%Config{} = config) do
    preview = map_or_empty(Map.get(config, :preview))

    %{
      enabled: truthy?(Map.get(preview, :enabled, false)),
      ttl_minutes: positive_integer(Map.get(preview, :ttl_minutes), 120),
      reuse_testing_runtime: truthy?(Map.get(preview, :reuse_testing_runtime, true)),
      allow_on_demand_from_pending_merge:
        truthy?(Map.get(preview, :allow_on_demand_from_pending_merge, true)),
      start_timeout_ms: positive_integer(Map.get(preview, :start_timeout_ms), 120_000),
      stop_timeout_ms: positive_integer(Map.get(preview, :stop_timeout_ms), 60_000)
    }
  end

  defp resolved_runtime_settings(%Config{} = config) do
    runtime = map_or_empty(Map.get(config, :runtime))

    kind =
      case Map.get(runtime, :kind) do
        :docker -> :docker
        "docker" -> :docker
        _ -> :host
      end

    %{
      kind: kind,
      image: optional_string(Map.get(runtime, :image)),
      processes: string_list(Map.get(runtime, :processes, [])),
      env: string_map(Map.get(runtime, :env, %{})),
      ports: ports_map(Map.get(runtime, :ports, %{})),
      port_offset_mod: positive_integer(Map.get(runtime, :port_offset_mod), 1000),
      start_timeout_ms: positive_integer(Map.get(runtime, :start_timeout_ms), 120_000),
      stop_timeout_ms: positive_integer(Map.get(runtime, :stop_timeout_ms), 60_000)
    }
  end

  defp agent_source_markers(%Config{} = config) do
    raw = map_or_empty(Map.get(config, :raw))

    %{
      "kind" => source_marker(raw, ["agent", "kind"]),
      "command" => source_marker(raw, ["agent", "command"]),
      "args" => source_marker(raw, ["agent", "args"]),
      "completion_signals" => source_marker(raw, ["agent", "completion_signals"]),
      "idle_timeout_ms" => source_marker(raw, ["agent", "idle_timeout_ms"]),
      "env" => source_marker(raw, ["agent", "env"]),
      "timeout_ms" => source_marker(raw, ["agent", "timeout_ms"]),
      "max_turns" => source_marker(raw, ["agent", "max_turns"]),
      "max_concurrent_agents" => source_marker(raw, ["agent", "max_concurrent_agents"]),
      "max_attempts" => source_marker(raw, ["agent", "max_attempts"]),
      "retries_enabled" => source_marker(raw, ["agent", "retries_enabled"]),
      "max_retry_backoff_ms" => source_marker(raw, ["agent", "max_retry_backoff_ms"])
    }
  end

  defp review_source_markers(%Config{} = config) do
    raw = map_or_empty(Map.get(config, :raw))
    review_agent_path = ["quality", "review", "agent"]
    review_agent_explicit = path_present?(raw, review_agent_path)

    %{
      "enabled" => source_marker(raw, ["quality", "review", "enabled"]),
      "max_cycles" => source_marker(raw, ["quality", "review", "max_cycles"]),
      "prompt_template" => source_marker(raw, ["quality", "review", "prompt_template"]),
      "agent_explicit" => if(review_agent_explicit, do: "workflow", else: "derived"),
      "agent" => %{
        "kind" =>
          review_agent_source_marker(raw, "kind",
            explicit: review_agent_explicit,
            fallback_path: ["agent", "kind"]
          ),
        "command" =>
          review_agent_source_marker(raw, "command",
            explicit: review_agent_explicit,
            fallback_path: ["agent", "command"]
          ),
        "args" =>
          review_agent_source_marker(raw, "args",
            explicit: review_agent_explicit,
            fallback_path: ["agent", "args"]
          ),
        "env" =>
          review_agent_source_marker(raw, "env",
            explicit: review_agent_explicit,
            fallback_path: ["agent", "env"]
          ),
        "timeout_ms" =>
          review_agent_source_marker(raw, "timeout_ms",
            explicit: review_agent_explicit,
            fallback_path: ["agent", "timeout_ms"]
          )
      }
    }
  end

  defp checks_source_markers(%Config{} = config) do
    raw = map_or_empty(Map.get(config, :raw))

    %{
      "required" => source_marker(raw, ["quality", "checks", "required"]),
      "timeout_ms" => source_marker(raw, ["quality", "checks", "timeout_ms"]),
      "fail_fast" => source_marker(raw, ["quality", "checks", "fail_fast"]),
      "max_cycles" => source_marker(raw, ["quality", "checks", "max_cycles"])
    }
  end

  defp testing_source_markers(%Config{} = config) do
    raw = map_or_empty(Map.get(config, :raw))
    testing_agent_path = ["quality", "testing", "agent"]
    testing_agent_explicit = path_present?(raw, testing_agent_path)

    %{
      "enabled" => source_marker(raw, ["quality", "testing", "enabled"]),
      "max_cycles" => source_marker(raw, ["quality", "testing", "max_cycles"]),
      "timeout_ms" => source_marker(raw, ["quality", "testing", "timeout_ms"]),
      "prompt_template" => source_marker(raw, ["quality", "testing", "prompt_template"]),
      "agent_explicit" => if(testing_agent_explicit, do: "workflow", else: "derived"),
      "agent" => %{
        "kind" =>
          testing_agent_source_marker(raw, "kind",
            explicit: testing_agent_explicit,
            fallback_path: ["agent", "kind"]
          ),
        "command" =>
          testing_agent_source_marker(raw, "command",
            explicit: testing_agent_explicit,
            fallback_path: ["agent", "command"]
          ),
        "args" =>
          testing_agent_source_marker(raw, "args",
            explicit: testing_agent_explicit,
            fallback_path: ["agent", "args"]
          ),
        "env" =>
          testing_agent_source_marker(raw, "env",
            explicit: testing_agent_explicit,
            fallback_path: ["agent", "env"]
          ),
        "timeout_ms" =>
          testing_agent_source_marker(raw, "timeout_ms",
            explicit: testing_agent_explicit,
            fallback_path: ["agent", "timeout_ms"]
          )
      }
    }
  end

  defp publish_source_markers(%Config{} = config) do
    raw = map_or_empty(Map.get(config, :raw))

    provider_source =
      cond do
        path_present?(raw, ["publish", "provider"]) ->
          "workflow"

        config.project_provider in [:github, :gitlab, :local] ->
          "project_provider"

        true ->
          "default"
      end

    mode_source =
      cond do
        path_present?(raw, ["publish", "mode"]) ->
          "workflow"

        Enum.any?(["auto_push", "auto_merge", "auto_create_pr"], fn field ->
          path_present?(raw, ["publish", field])
        end) ->
          "legacy_publish_fields"

        true ->
          "provider_default"
      end

    %{
      "provider" => provider_source,
      "mode" => mode_source,
      "auto_push" => source_marker(raw, ["publish", "auto_push"]),
      "auto_merge" => source_marker(raw, ["publish", "auto_merge"]),
      "auto_create_pr" => source_marker(raw, ["publish", "auto_create_pr"]),
      "base_branch" => source_marker(raw, ["git", "base_branch"])
    }
  end

  defp preview_source_markers(%Config{} = config) do
    raw = map_or_empty(Map.get(config, :raw))

    %{
      "enabled" => source_marker(raw, ["preview", "enabled"]),
      "ttl_minutes" => source_marker(raw, ["preview", "ttl_minutes"]),
      "reuse_testing_runtime" => source_marker(raw, ["preview", "reuse_testing_runtime"]),
      "allow_on_demand_from_pending_merge" =>
        source_marker(raw, ["preview", "allow_on_demand_from_pending_merge"]),
      "start_timeout_ms" => source_marker(raw, ["preview", "start_timeout_ms"]),
      "stop_timeout_ms" => source_marker(raw, ["preview", "stop_timeout_ms"])
    }
  end

  defp runtime_source_markers(%Config{} = config) do
    raw = map_or_empty(Map.get(config, :raw))

    %{
      "kind" => source_marker(raw, ["runtime", "kind"]),
      "image" => source_marker(raw, ["runtime", "image"]),
      "processes" => source_marker(raw, ["runtime", "processes"]),
      "env" => source_marker(raw, ["runtime", "env"]),
      "ports" => source_marker(raw, ["runtime", "ports"]),
      "port_offset_mod" => source_marker(raw, ["runtime", "port_offset_mod"]),
      "start_timeout_ms" => source_marker(raw, ["runtime", "start_timeout_ms"]),
      "stop_timeout_ms" => source_marker(raw, ["runtime", "stop_timeout_ms"])
    }
  end

  defp review_agent_source_marker(raw, field, opts) when is_binary(field) do
    explicit = Keyword.get(opts, :explicit, false)
    fallback_path = Keyword.get(opts, :fallback_path, [])

    cond do
      path_present?(raw, ["quality", "review", "agent", field]) ->
        "workflow.review_agent"

      explicit ->
        "workflow.review_agent_inherited"

      fallback_path != [] and path_present?(raw, fallback_path) ->
        "workflow.agent"

      true ->
        "default"
    end
  end

  defp testing_agent_source_marker(raw, field, opts) when is_binary(field) do
    explicit = Keyword.get(opts, :explicit, false)
    fallback_path = Keyword.get(opts, :fallback_path, [])

    cond do
      path_present?(raw, ["quality", "testing", "agent", field]) ->
        "workflow.testing_agent"

      explicit ->
        "workflow.testing_agent_inherited"

      fallback_path != [] and path_present?(raw, fallback_path) ->
        "workflow.agent"

      true ->
        "default"
    end
  end

  defp checks_config(%Config{} = config) do
    case Map.get(config, :checks) do
      checks when is_map(checks) ->
        checks

      _other ->
        config
        |> quality_config()
        |> Map.get(:checks)
        |> map_or_empty()
    end
  end

  defp review_config(%Config{} = config) do
    case Map.get(config, :review) do
      review when is_map(review) ->
        review

      _other ->
        config
        |> quality_config()
        |> Map.get(:review)
        |> map_or_empty()
    end
  end

  defp testing_config(%Config{} = config) do
    case Map.get(config, :testing) do
      testing when is_map(testing) ->
        testing

      _other ->
        config
        |> quality_config()
        |> Map.get(:testing)
        |> map_or_empty()
    end
  end

  defp quality_config(%Config{} = config) do
    config
    |> Map.get(:quality)
    |> map_or_empty()
  end

  defp quality_max_cycles(%Config{} = config) do
    config
    |> quality_config()
    |> Map.get(:max_cycles)
    |> positive_integer(1)
  end

  defp source_marker(raw, path) do
    if path_present?(raw, path), do: "workflow", else: "default"
  end

  defp path_present?(map, path) when is_map(map) and is_list(path) do
    case path do
      [] ->
        true

      [key] ->
        Map.has_key?(map, key)

      [key | rest] ->
        case Map.get(map, key) do
          value when is_map(value) -> path_present?(value, rest)
          _other -> false
        end
    end
  end

  defp path_present?(_map, _path), do: false

  defp config_sha256(%Config{} = config) do
    config
    |> Map.get(:raw)
    |> case do
      raw when is_map(raw) -> :erlang.term_to_binary(raw)
      _other -> :erlang.term_to_binary(config)
    end
    |> sha256_hex()
  end

  defp sha256_hex(payload) when is_binary(payload) do
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_list(map, key, value) when is_list(value) and value != [],
    do: Map.put(map, key, value)

  defp maybe_put_list(map, _key, _value), do: map

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp optional_string(_value), do: nil

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
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

  defp ports_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, val}, acc ->
      case positive_integer(val, nil) do
        parsed when is_integer(parsed) and parsed > 0 -> Map.put(acc, to_string(key), parsed)
        _other -> acc
      end
    end)
  end

  defp ports_map(_value), do: %{}

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_value(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_value(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end

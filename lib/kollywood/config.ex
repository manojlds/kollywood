defmodule Kollywood.Config do
  @moduledoc """
  Parses and validates the YAML front matter from WORKFLOW.md.

  Supports multiple agent kinds: amp, claude, cursor, opencode, pi.
  """

  require Logger

  @type agent_kind :: :amp | :claude | :cursor | :opencode | :pi
  @type publish_provider :: :github | :gitlab
  @type publish_mode :: :push | :pr | :auto_merge
  @type auto_push_policy :: :never | :on_pass
  @type auto_merge_policy :: :never | :on_pass
  @type auto_create_pr_policy :: :never | :draft | :ready

  @valid_agent_kinds ~w(amp claude cursor opencode pi)a
  @valid_publish_providers ~w(github gitlab)a
  @valid_publish_modes ~w(push pr auto_merge)a
  @valid_auto_push_policies ~w(never on_pass)a
  @valid_auto_merge_policies ~w(never on_pass)a
  @valid_auto_create_pr_policies ~w(never draft ready)a
  @default_timeout_ms 7_200_000

  @type t :: %__MODULE__{
          tracker: map(),
          polling: map(),
          workspace: map(),
          hooks: map(),
          quality: map(),
          checks: map(),
          runtime: map(),
          review: map(),
          agent: map(),
          publish: map(),
          git: map(),
          project_provider: publish_provider() | :local | nil,
          raw: map()
        }

  defstruct [
    :tracker,
    :polling,
    :workspace,
    :hooks,
    :quality,
    :checks,
    :runtime,
    :review,
    :agent,
    :publish,
    :git,
    :raw,
    project_provider: nil
  ]

  @doc """
  Returns the effective publish provider — `publish.provider` from WORKFLOW.md if explicitly set,
  otherwise the project-level provider injected at runtime.
  """
  @spec effective_publish_provider(t()) :: publish_provider() | :local | nil
  def effective_publish_provider(%__MODULE__{} = config) do
    get_in(config, [Access.key(:publish, %{}), Access.key(:provider)]) ||
      config.project_provider
  end

  @doc """
  Returns the effective publish mode.

  Resolution order:
  - `publish.mode` from WORKFLOW.md (including legacy-derived mode)
  - provider default (`:auto_merge` for local, `:pr` for github/gitlab, `:push` fallback)
  """
  @spec effective_publish_mode(t()) :: publish_mode()
  def effective_publish_mode(%__MODULE__{} = config) do
    get_in(config, [Access.key(:publish, %{}), Access.key(:mode)]) ||
      default_publish_mode(effective_publish_provider(config))
  end

  @doc """
  Parses WORKFLOW.md content into a `%Config{}` struct.

  Returns `{:ok, config, prompt_template}` or `{:error, reason}`.
  The prompt_template is the markdown body after the YAML front matter.
  """
  @spec parse(String.t()) :: {:ok, t(), String.t()} | {:error, String.t()}
  def parse(content) do
    with {:ok, raw_yaml, prompt_template} <- extract_front_matter(content),
         {:ok, config} <- build_config(raw_yaml) do
      {:ok, config, prompt_template}
    end
  end

  defp extract_front_matter(content) do
    case String.split(content, "---", parts: 3) do
      ["", yaml_str, rest] ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, yaml} -> {:ok, yaml, String.trim(rest)}
          {:error, reason} -> {:error, "Failed to parse YAML: #{inspect(reason)}"}
        end

      _ ->
        {:error, "WORKFLOW.md must start with YAML front matter between --- delimiters"}
    end
  end

  defp build_config(raw) do
    with :ok <- validate_required_sections(raw),
         {:ok, agent_kind} <- parse_agent_kind(raw),
         {:ok, review_agent_kind} <- parse_review_agent_kind(raw, agent_kind),
         {:ok, quality} <- parse_quality(raw, review_agent_kind),
         {:ok, runtime} <- parse_runtime(raw),
         {:ok, publish} <- parse_publish(raw),
         {:ok, git_policy} <- parse_git(raw) do
      config = %__MODULE__{
        tracker: parse_tracker(raw),
        polling: parse_polling(raw),
        workspace: parse_workspace(raw),
        hooks: parse_hooks(raw),
        quality: quality,
        checks: quality.checks,
        runtime: runtime,
        review: quality.review,
        agent: parse_agent(raw, agent_kind),
        publish: publish,
        git: git_policy,
        raw: raw
      }

      {:ok, config}
    end
  end

  defp validate_required_sections(raw) do
    missing =
      ~w(agent workspace)
      |> Enum.reject(&Map.has_key?(raw, &1))

    case missing do
      [] -> :ok
      keys -> {:error, "Missing required sections: #{Enum.join(keys, ", ")}"}
    end
  end

  defp parse_agent_kind(raw) do
    kind_str = get_in(raw, ["agent", "kind"])

    cond do
      is_nil(kind_str) ->
        {:error, "agent.kind is required (amp, claude, cursor, opencode, or pi)"}

      true ->
        parse_agent_kind_value(kind_str)
    end
  end

  defp parse_review_agent_kind(raw, fallback_kind) do
    kind =
      raw
      |> Map.get("quality", %{})
      |> map_or_empty()
      |> Map.get("review", %{})
      |> map_or_empty()
      |> Map.get("agent", %{})
      |> map_or_empty()
      |> Map.get("kind")

    case kind do
      nil -> {:ok, fallback_kind}
      kind -> parse_agent_kind_value(kind)
    end
  end

  defp parse_agent_kind_value(kind) when is_binary(kind) do
    case String.trim(kind) do
      "amp" ->
        {:ok, :amp}

      "claude" ->
        {:ok, :claude}

      "cursor" ->
        {:ok, :cursor}

      "opencode" ->
        {:ok, :opencode}

      "pi" ->
        {:ok, :pi}

      other ->
        {:error,
         "Invalid agent.kind: #{other}. Must be one of: #{Enum.join(@valid_agent_kinds, ", ")}"}
    end
  end

  defp parse_agent_kind_value(kind) do
    {:error,
     "Invalid agent.kind: #{inspect(kind)}. Must be one of: #{Enum.join(@valid_agent_kinds, ", ")}"}
  end

  defp parse_tracker(raw) do
    tracker = Map.get(raw, "tracker", %{})
    kind = tracker_kind(Map.get(tracker, "kind", "linear"))

    {default_active_states, default_terminal_states} = tracker_default_states(kind)

    %{
      kind: kind,
      path: optional_string(Map.get(tracker, "path")) || tracker_default_path(kind),
      project_slug: Map.get(tracker, "project_slug"),
      active_states: string_list(Map.get(tracker, "active_states", default_active_states)),
      terminal_states: string_list(Map.get(tracker, "terminal_states", default_terminal_states))
    }
  end

  defp tracker_kind(kind) when is_binary(kind), do: String.trim(kind)
  defp tracker_kind(kind), do: to_string(kind)

  defp tracker_default_states(kind) do
    case String.downcase(kind) do
      "prd_json" ->
        {["open", "in_progress", "pending_merge", "merged"],
         ["done", "merged", "failed", "cancelled"]}

      "prd-json" ->
        {["open", "in_progress", "pending_merge", "merged"],
         ["done", "merged", "failed", "cancelled"]}

      "prd" ->
        {["open", "in_progress", "pending_merge", "merged"],
         ["done", "merged", "failed", "cancelled"]}

      "local" ->
        {["open", "in_progress", "pending_merge", "merged"],
         ["done", "merged", "failed", "cancelled"]}

      _other ->
        {["Todo", "In Progress"], ["Done", "Cancelled"]}
    end
  end

  defp tracker_default_path(kind) do
    case String.downcase(kind) do
      "prd_json" -> "prd.json"
      "prd-json" -> "prd.json"
      "prd" -> "prd.json"
      "local" -> "prd.json"
      _other -> nil
    end
  end

  defp parse_polling(raw) do
    polling = Map.get(raw, "polling", %{})

    %{
      interval_ms: positive_integer(Map.get(polling, "interval_ms", 5000), 5000),
      stale_threshold_multiplier:
        positive_integer(Map.get(polling, "stale_threshold_multiplier", 3), 3),
      watchdog_check_interval_ms:
        positive_integer(
          Map.get(polling, "watchdog_check_interval_ms", Map.get(polling, "interval_ms", 5000)),
          positive_integer(Map.get(polling, "interval_ms", 5000), 5000)
        )
    }
  end

  defp parse_workspace(raw) do
    workspace = Map.get(raw, "workspace", %{})
    strategy = Map.get(workspace, "strategy", "clone")

    # root and source are intentionally nil when absent — WorkflowStore injects
    # them from ServiceConfig + project context at runtime.
    base = %{
      root: optional_string(Map.get(workspace, "root")),
      strategy: workspace_strategy(strategy)
    }

    case strategy do
      "worktree" ->
        Map.merge(base, %{
          source: optional_string(Map.get(workspace, "source")),
          branch_prefix: Map.get(workspace, "branch_prefix", "kollywood/")
        })

      _ ->
        base
    end
  end

  defp workspace_strategy("worktree"), do: :worktree
  defp workspace_strategy("clone"), do: :clone
  defp workspace_strategy(_strategy), do: :clone

  defp parse_hooks(raw) do
    hooks = Map.get(raw, "hooks", %{})

    %{
      after_create: Map.get(hooks, "after_create"),
      before_run: Map.get(hooks, "before_run"),
      after_run: Map.get(hooks, "after_run"),
      before_remove: Map.get(hooks, "before_remove")
    }
  end

  defp parse_quality(raw, review_agent_kind) do
    quality = map_or_empty(Map.get(raw, "quality", %{}))
    quality_max_cycles = positive_integer(Map.get(quality, "max_cycles", 1), 1)

    checks = parse_quality_checks(quality, quality_max_cycles)
    review = parse_quality_review(quality, review_agent_kind, quality_max_cycles)

    {:ok,
     %{
       max_cycles: quality_max_cycles,
       checks: checks,
       review: review
     }}
  end

  defp parse_quality_checks(quality, quality_max_cycles) do
    checks = map_or_empty(Map.get(quality, "checks", %{}))

    %{
      required: command_list(Map.get(checks, "required", [])),
      timeout_ms:
        positive_integer(Map.get(checks, "timeout_ms", @default_timeout_ms), @default_timeout_ms),
      fail_fast: boolean(Map.get(checks, "fail_fast", true), true),
      max_cycles:
        positive_integer(Map.get(checks, "max_cycles", quality_max_cycles), quality_max_cycles)
    }
  end

  defp parse_quality_review(quality, review_agent_kind, quality_max_cycles) do
    review = quality |> get_in(["review"]) |> map_or_empty()
    review_agent_raw = Map.get(review, "agent")
    review_agent_explicit = is_map(review_agent_raw)
    review_agent = review_agent_raw || %{}

    %{
      enabled: boolean(Map.get(review, "enabled", false), false),
      max_cycles:
        positive_integer(Map.get(review, "max_cycles", quality_max_cycles), quality_max_cycles),
      pass_token: optional_string(Map.get(review, "pass_token")) || "REVIEW_PASS",
      fail_token: optional_string(Map.get(review, "fail_token")) || "REVIEW_FAIL",
      prompt_template: optional_string(Map.get(review, "prompt_template")),
      agent: %{
        explicit: review_agent_explicit,
        kind: review_agent_kind,
        command: optional_string(Map.get(review_agent, "command")),
        args: string_list(Map.get(review_agent, "args", [])),
        env: string_map(Map.get(review_agent, "env", %{})),
        timeout_ms:
          positive_integer(
            Map.get(review_agent, "timeout_ms", @default_timeout_ms),
            @default_timeout_ms
          )
      }
    }
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp parse_runtime(raw) do
    case Map.get(raw, "runtime", %{}) do
      runtime when is_map(runtime) ->
        with {:ok, kind} <- parse_runtime_kind(Map.get(runtime, "kind", "host")),
             {:ok, profile} <- parse_runtime_profile(Map.get(runtime, "profile", "checks_only")),
             {:ok, full_stack} <- parse_runtime_full_stack(Map.get(runtime, "full_stack", %{})) do
          {:ok,
           %{
             kind: kind,
             profile: profile,
             full_stack: full_stack
           }}
        end

      other ->
        {:error, "runtime must be a map (got: #{inspect(other)})"}
    end
  end

  defp parse_runtime_kind(nil), do: {:ok, :host}

  defp parse_runtime_kind(value) when is_binary(value) do
    case String.trim(value) do
      "host" -> {:ok, :host}
      "docker" -> {:ok, :docker}
      other -> {:error, "runtime.kind must be one of: host, docker (got: #{other})"}
    end
  end

  defp parse_runtime_kind(value) when value in [:host, :docker], do: {:ok, value}

  defp parse_runtime_kind(value) do
    {:error, "runtime.kind must be one of: host, docker (got: #{inspect(value)})"}
  end

  defp parse_runtime_profile(nil), do: {:ok, :checks_only}

  defp parse_runtime_profile(value) when is_binary(value) do
    case String.trim(value) do
      "checks_only" -> {:ok, :checks_only}
      "full_stack" -> {:ok, :full_stack}
      other -> {:error, "runtime.profile must be one of: checks_only, full_stack (got: #{other})"}
    end
  end

  defp parse_runtime_profile(value) when value in [:checks_only, :full_stack], do: {:ok, value}

  defp parse_runtime_profile(value) do
    {:error, "runtime.profile must be one of: checks_only, full_stack (got: #{inspect(value)})"}
  end

  defp parse_runtime_full_stack(full_stack) when is_map(full_stack) do
    with {:ok, ports} <- parse_runtime_ports(Map.get(full_stack, "ports", %{})) do
      {:ok,
       %{
         command: optional_string(Map.get(full_stack, "command")) || "devenv",
         processes: command_list(Map.get(full_stack, "processes", [])),
         env: string_map(Map.get(full_stack, "env", %{})),
         ports: ports,
         port_offset_mod: positive_integer(Map.get(full_stack, "port_offset_mod", 1000), 1000),
         start_timeout_ms:
           positive_integer(Map.get(full_stack, "start_timeout_ms", 120_000), 120_000),
         stop_timeout_ms: positive_integer(Map.get(full_stack, "stop_timeout_ms", 60_000), 60_000)
       }}
    end
  end

  defp parse_runtime_full_stack(value) do
    {:error, "runtime.full_stack must be a map (got: #{inspect(value)})"}
  end

  defp parse_runtime_ports(values) when is_map(values) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case positive_integer(value, nil) do
        port when is_integer(port) and port > 0 ->
          {:cont, {:ok, Map.put(acc, to_string(key), port)}}

        _other ->
          {:halt,
           {:error,
            "runtime.full_stack.ports.#{to_string(key)} must be a positive integer (got: #{inspect(value)})"}}
      end
    end)
  end

  defp parse_runtime_ports(values) do
    {:error, "runtime.full_stack.ports must be a map (got: #{inspect(values)})"}
  end

  defp parse_agent(raw, kind) do
    agent = Map.get(raw, "agent", %{})

    %{
      kind: kind,
      max_concurrent_agents: positive_integer(Map.get(agent, "max_concurrent_agents", 1), 1),
      project_max_concurrent_agents:
        parse_project_max_concurrent_agents(Map.get(agent, "project_max_concurrent_agents", %{})),
      max_turns: positive_integer(Map.get(agent, "max_turns", 20), 20),
      retries_enabled: boolean(Map.get(agent, "retries_enabled", true), true),
      max_attempts: positive_integer(Map.get(agent, "max_attempts", 1), 1),
      max_retry_backoff_ms:
        positive_integer(Map.get(agent, "max_retry_backoff_ms", 300_000), 300_000),
      command: optional_string(Map.get(agent, "command")),
      args: string_list(Map.get(agent, "args", [])),
      env: string_map(Map.get(agent, "env", %{})),
      timeout_ms:
        positive_integer(Map.get(agent, "timeout_ms", @default_timeout_ms), @default_timeout_ms)
    }
  end

  defp parse_project_max_concurrent_agents(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {project_key, project_limit}, acc ->
      normalized_key = optional_string(project_key)
      normalized_limit = positive_integer(project_limit, nil)

      cond do
        is_nil(normalized_key) ->
          acc

        is_nil(normalized_limit) ->
          Logger.warning(
            "Ignoring invalid agent.project_max_concurrent_agents entry for #{inspect(project_key)} (got: #{inspect(project_limit)})"
          )

          acc

        true ->
          Map.put(acc, normalized_key, normalized_limit)
      end
    end)
  end

  defp parse_project_max_concurrent_agents(value) when is_list(value) do
    value
    |> Enum.reduce(%{}, fn entry, acc ->
      case entry do
        {project_key, project_limit} -> Map.put(acc, project_key, project_limit)
        _other -> acc
      end
    end)
    |> parse_project_max_concurrent_agents()
  end

  defp parse_project_max_concurrent_agents(nil), do: %{}

  defp parse_project_max_concurrent_agents(value) do
    Logger.warning(
      "Ignoring invalid agent.project_max_concurrent_agents value (expected map, got: #{inspect(value)})"
    )

    %{}
  end

  defp parse_publish(raw) do
    publish = Map.get(raw, "publish", %{})

    legacy_fields_present? =
      Enum.any?(["auto_push", "auto_merge", "auto_create_pr"], &Map.has_key?(publish, &1))

    with {:ok, provider} <- parse_optional_publish_provider(Map.get(publish, "provider")),
         {:ok, mode} <-
           parse_optional_enum_value(
             Map.get(publish, "mode"),
             @valid_publish_modes,
             "publish.mode"
           ),
         {:ok, auto_push} <-
           parse_enum_value(
             Map.get(publish, "auto_push", "never"),
             @valid_auto_push_policies,
             "publish.auto_push"
           ),
         {:ok, auto_merge} <-
           parse_enum_value(
             Map.get(publish, "auto_merge", "never"),
             @valid_auto_merge_policies,
             "publish.auto_merge"
           ),
         {:ok, auto_create_pr} <-
           parse_enum_value(
             Map.get(publish, "auto_create_pr", "never"),
             @valid_auto_create_pr_policies,
             "publish.auto_create_pr"
           ),
         resolved_mode <-
           resolve_publish_mode(
             mode,
             legacy_fields_present?,
             auto_push,
             auto_create_pr,
             auto_merge
           ) do
      maybe_warn_legacy_publish_fields(legacy_fields_present?)

      {:ok,
       %{
         provider: provider,
         mode: resolved_mode,
         auto_push: auto_push,
         auto_merge: auto_merge,
         auto_create_pr: auto_create_pr
       }}
    end
  end

  # nil means "not set in WORKFLOW.md — derive from project_provider at runtime"
  defp parse_optional_publish_provider(nil), do: {:ok, nil}
  defp parse_optional_publish_provider(""), do: {:ok, nil}

  defp parse_optional_publish_provider(value),
    do: parse_enum_value(value, @valid_publish_providers, "publish.provider")

  defp parse_optional_enum_value(nil, _valid_values, _path), do: {:ok, nil}
  defp parse_optional_enum_value("", _valid_values, _path), do: {:ok, nil}

  defp parse_optional_enum_value(value, valid_values, path),
    do: parse_enum_value(value, valid_values, path)

  defp derive_publish_mode_from_legacy(_auto_push, _auto_create_pr, :on_pass), do: :auto_merge

  defp derive_publish_mode_from_legacy(:on_pass, auto_create_pr, _auto_merge)
       when auto_create_pr in [:draft, :ready],
       do: :pr

  defp derive_publish_mode_from_legacy(:on_pass, _auto_create_pr, _auto_merge), do: :push
  defp derive_publish_mode_from_legacy(_auto_push, _auto_create_pr, _auto_merge), do: :push

  defp resolve_publish_mode(
         mode,
         _legacy_fields_present?,
         _auto_push,
         _auto_create_pr,
         _auto_merge
       )
       when mode in @valid_publish_modes,
       do: mode

  defp resolve_publish_mode(nil, true, auto_push, auto_create_pr, auto_merge),
    do: derive_publish_mode_from_legacy(auto_push, auto_create_pr, auto_merge)

  defp resolve_publish_mode(nil, false, _auto_push, _auto_create_pr, _auto_merge), do: nil

  defp maybe_warn_legacy_publish_fields(true) do
    Logger.warning(
      "publish.auto_push / publish.auto_create_pr / publish.auto_merge are deprecated; use publish.mode (push, pr, auto_merge)"
    )
  end

  defp maybe_warn_legacy_publish_fields(false), do: :ok

  defp default_publish_mode(:local), do: :auto_merge
  defp default_publish_mode(provider) when provider in [:github, :gitlab], do: :pr
  defp default_publish_mode(_provider), do: :push

  defp parse_git(raw) do
    git = Map.get(raw, "git", %{})
    base_branch = git |> Map.get("base_branch", "main") |> to_string() |> String.trim()
    {:ok, %{base_branch: base_branch}}
  end

  defp parse_enum_value(value, valid_values, path) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    case Enum.find(valid_values, &(Atom.to_string(&1) == normalized)) do
      nil ->
        {:error,
         "Invalid #{path}: #{inspect(value)}. Must be one of: #{Enum.join(valid_values, ", ")}"}

      parsed_value ->
        {:ok, parsed_value}
    end
  end

  defp parse_enum_value(value, valid_values, path) when is_atom(value) do
    if value in valid_values do
      {:ok, value}
    else
      {:error,
       "Invalid #{path}: #{inspect(value)}. Must be one of: #{Enum.join(valid_values, ", ")}"}
    end
  end

  defp parse_enum_value(value, valid_values, path) do
    {:error,
     "Invalid #{path}: #{inspect(value)}. Must be one of: #{Enum.join(valid_values, ", ")}"}
  end

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

  defp command_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp command_list(_values), do: []

  defp string_list(values) when is_list(values) do
    Enum.map(values, &to_string/1)
  end

  defp string_list(_values), do: []

  defp string_map(values) when is_map(values) do
    Map.new(values, fn {key, val} ->
      {to_string(key), to_string(val)}
    end)
  end

  defp string_map(_values), do: %{}

  defp boolean(value, _default) when is_boolean(value), do: value

  defp boolean(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp boolean(_value, default), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
end

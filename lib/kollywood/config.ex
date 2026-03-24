defmodule Kollywood.Config do
  @moduledoc """
  Parses and validates the YAML front matter from WORKFLOW.md.

  Supports multiple agent kinds: amp, claude, opencode, pi.
  """

  @type agent_kind :: :amp | :claude | :opencode | :pi
  @valid_agent_kinds ~w(amp claude opencode pi)a

  @type t :: %__MODULE__{
          tracker: map(),
          polling: map(),
          workspace: map(),
          hooks: map(),
          checks: map(),
          review: map(),
          agent: map(),
          raw: map()
        }

  defstruct [
    :tracker,
    :polling,
    :workspace,
    :hooks,
    :checks,
    :review,
    :agent,
    :raw
  ]

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
         {:ok, review_agent_kind} <- parse_review_agent_kind(raw, agent_kind) do
      config = %__MODULE__{
        tracker: parse_tracker(raw),
        polling: parse_polling(raw),
        workspace: parse_workspace(raw),
        hooks: parse_hooks(raw),
        checks: parse_checks(raw),
        review: parse_review(raw, review_agent_kind),
        agent: parse_agent(raw, agent_kind),
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
        {:error, "agent.kind is required (amp, claude, opencode, or pi)"}

      true ->
        parse_agent_kind_value(kind_str)
    end
  end

  defp parse_review_agent_kind(raw, fallback_kind) do
    case get_in(raw, ["review", "agent", "kind"]) do
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
      "prd_json" -> {["open", "in_progress"], ["done"]}
      "prd-json" -> {["open", "in_progress"], ["done"]}
      "prd" -> {["open", "in_progress"], ["done"]}
      "local" -> {["open", "in_progress"], ["done"]}
      _other -> {["Todo", "In Progress"], ["Done", "Cancelled"]}
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
      interval_ms: positive_integer(Map.get(polling, "interval_ms", 5000), 5000)
    }
  end

  defp parse_workspace(raw) do
    workspace = Map.get(raw, "workspace", %{})
    strategy = Map.get(workspace, "strategy", "clone")

    base = %{
      root: Map.get(workspace, "root", "~/kollywood-workspaces"),
      strategy: workspace_strategy(strategy)
    }

    case strategy do
      "worktree" ->
        Map.merge(base, %{
          source: Map.get(workspace, "source"),
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

  defp parse_checks(raw) do
    checks = Map.get(raw, "checks", %{})

    %{
      required: command_list(Map.get(checks, "required", [])),
      timeout_ms: positive_integer(Map.get(checks, "timeout_ms", 300_000), 300_000),
      fail_fast: boolean(Map.get(checks, "fail_fast", true), true)
    }
  end

  defp parse_review(raw, review_agent_kind) do
    review = Map.get(raw, "review", %{})
    review_agent = Map.get(review, "agent", %{})

    %{
      enabled: boolean(Map.get(review, "enabled", false), false),
      pass_token: optional_string(Map.get(review, "pass_token")) || "REVIEW_PASS",
      fail_token: optional_string(Map.get(review, "fail_token")) || "REVIEW_FAIL",
      prompt_template: optional_string(Map.get(review, "prompt_template")),
      agent: %{
        kind: review_agent_kind,
        command: optional_string(Map.get(review_agent, "command")),
        args: string_list(Map.get(review_agent, "args", [])),
        env: string_map(Map.get(review_agent, "env", %{})),
        timeout_ms: positive_integer(Map.get(review_agent, "timeout_ms", 300_000), 300_000)
      }
    }
  end

  defp parse_agent(raw, kind) do
    agent = Map.get(raw, "agent", %{})

    %{
      kind: kind,
      max_concurrent_agents: positive_integer(Map.get(agent, "max_concurrent_agents", 5), 5),
      max_turns: positive_integer(Map.get(agent, "max_turns", 20), 20),
      max_retry_backoff_ms:
        positive_integer(Map.get(agent, "max_retry_backoff_ms", 300_000), 300_000),
      command: optional_string(Map.get(agent, "command")),
      args: string_list(Map.get(agent, "args", [])),
      env: string_map(Map.get(agent, "env", %{})),
      timeout_ms: positive_integer(Map.get(agent, "timeout_ms", 300_000), 300_000)
    }
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

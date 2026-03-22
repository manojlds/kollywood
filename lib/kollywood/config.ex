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
          agent: map(),
          raw: map()
        }

  defstruct [
    :tracker,
    :polling,
    :workspace,
    :hooks,
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
         {:ok, agent_kind} <- parse_agent_kind(raw) do
      config = %__MODULE__{
        tracker: parse_tracker(raw),
        polling: parse_polling(raw),
        workspace: parse_workspace(raw),
        hooks: parse_hooks(raw),
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

      String.to_existing_atom(kind_str) in @valid_agent_kinds ->
        {:ok, String.to_existing_atom(kind_str)}

      true ->
        {:error,
         "Invalid agent.kind: #{kind_str}. Must be one of: #{Enum.join(@valid_agent_kinds, ", ")}"}
    end
  rescue
    ArgumentError ->
      {:error,
       "Invalid agent.kind: #{get_in(raw, ["agent", "kind"])}. Must be one of: #{Enum.join(@valid_agent_kinds, ", ")}"}
  end

  defp parse_tracker(raw) do
    tracker = Map.get(raw, "tracker", %{})

    %{
      kind: Map.get(tracker, "kind", "linear"),
      project_slug: Map.get(tracker, "project_slug"),
      active_states: Map.get(tracker, "active_states", ["Todo", "In Progress"]),
      terminal_states: Map.get(tracker, "terminal_states", ["Done", "Cancelled"])
    }
  end

  defp parse_polling(raw) do
    polling = Map.get(raw, "polling", %{})

    %{
      interval_ms: Map.get(polling, "interval_ms", 5000)
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

  defp parse_agent(raw, kind) do
    agent = Map.get(raw, "agent", %{})

    %{
      kind: kind,
      max_concurrent_agents: Map.get(agent, "max_concurrent_agents", 5),
      max_turns: Map.get(agent, "max_turns", 20),
      command: optional_string(Map.get(agent, "command")),
      args: string_list(Map.get(agent, "args", [])),
      env: string_map(Map.get(agent, "env", %{})),
      timeout_ms: positive_integer(Map.get(agent, "timeout_ms", 300_000), 300_000)
    }
  end

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

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

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
end

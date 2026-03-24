defmodule Kollywood.Tracker.PrdJson do
  @moduledoc """
  Local tracker adapter backed by `prd.json`.

  This adapter follows the local PRD story format and exposes stories as
  orchestrator issues.
  """

  @behaviour Kollywood.Tracker

  alias Kollywood.Config

  @default_path "prd.json"
  @default_priority 99

  @impl true
  @spec list_active_issues(Config.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_active_issues(%Config{} = config) do
    with {:ok, prd} <- read_prd(config),
         {:ok, stories} <- user_stories(prd) do
      normalized_stories = Enum.map(stories, &normalize_story/1)
      stories_by_id = Map.new(normalized_stories, &{&1.id, &1})
      active_states = active_state_set(config)

      issues =
        normalized_stories
        |> Enum.filter(fn story ->
          non_empty_string?(story.id) and MapSet.member?(active_states, story.status)
        end)
        |> Enum.map(&story_to_issue(&1, stories_by_id))

      {:ok, issues}
    end
  end

  @impl true
  @spec claim_issue(Config.t(), String.t()) :: :ok | {:error, String.t()}
  def claim_issue(%Config{} = _config, _issue_id), do: :ok

  @impl true
  @spec mark_in_progress(Config.t(), String.t()) :: :ok | {:error, String.t()}
  def mark_in_progress(%Config{} = config, issue_id) when is_binary(issue_id) do
    update_story(config, issue_id, fn story ->
      story
      |> set_story_status("in_progress")
      |> Map.put_new("startedAt", now_iso8601())
    end)
  end

  @impl true
  @spec mark_done(Config.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def mark_done(%Config{} = config, issue_id, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    update_story(config, issue_id, fn story ->
      story
      |> set_story_status("done")
      |> Map.put("completedAt", now_iso8601())
      |> Map.put("lastError", nil)
      |> Map.put("lastRun", stringify_map(metadata))
    end)
  end

  @impl true
  @spec mark_failed(Config.t(), String.t(), String.t(), pos_integer()) ::
          :ok | {:error, String.t()}
  def mark_failed(%Config{} = config, issue_id, reason, attempt)
      when is_binary(issue_id) and is_binary(reason) and is_integer(attempt) and attempt > 0 do
    failed_status = if(retries_enabled?(config), do: "in_progress", else: "failed")

    update_story(config, issue_id, fn story ->
      story
      |> set_story_status(failed_status)
      |> Map.put("lastError", reason)
      |> Map.put("lastAttempt", attempt)
      |> append_note("attempt #{attempt}: #{reason}")
    end)
  end

  defp update_story(config, issue_id, update_fun) do
    with {:ok, prd} <- read_prd(config),
         {:ok, stories} <- user_stories(prd),
         {:ok, updated_stories} <- update_story_list(stories, issue_id, update_fun) do
      write_prd(config, Map.put(prd, "userStories", updated_stories))
    end
  end

  defp update_story_list(stories, issue_id, update_fun) do
    {updated_stories, found?} =
      Enum.map_reduce(stories, false, fn story, found ->
        if story_id(story) == issue_id do
          {update_fun.(story), true}
        else
          {story, found}
        end
      end)

    if found? do
      {:ok, updated_stories}
    else
      {:error, "issue not found in PRD: #{issue_id}"}
    end
  end

  defp read_prd(config) do
    path = tracker_path(config)

    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, "failed to read PRD #{path}: #{inspect(reason)}"}
    end
  end

  defp write_prd(config, prd) do
    path = tracker_path(config)
    temp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"
    encoded = Jason.encode_to_iodata!(prd, pretty: true)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp_path, [encoded, "\n"]),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, "failed to write PRD #{path}: #{inspect(reason)}"}
    end
  end

  defp user_stories(prd) when is_map(prd) do
    case Map.get(prd, "userStories") do
      stories when is_list(stories) -> {:ok, stories}
      _other -> {:error, "PRD is missing a valid userStories array"}
    end
  end

  defp user_stories(_prd), do: {:error, "PRD must be a JSON object"}

  defp story_to_issue(story, stories_by_id) do
    %{
      id: story.id,
      identifier: story.id,
      title: story.title,
      description: issue_description(story),
      state: story.status,
      priority: story.priority,
      blocked_by: blocker_list(story.depends_on, stories_by_id),
      created_at: nil
    }
  end

  defp blocker_list(depends_on, stories_by_id) do
    Enum.map(depends_on, fn dependency_id ->
      blocker = Map.get(stories_by_id, dependency_id)

      %{
        id: dependency_id,
        identifier: dependency_id,
        title: if(is_nil(blocker), do: dependency_id, else: blocker.title),
        state: if(is_nil(blocker), do: "open", else: blocker.status)
      }
    end)
  end

  defp issue_description(story) do
    criteria_section =
      case story.acceptance_criteria do
        [] ->
          nil

        criteria ->
          lines = Enum.map_join(criteria, "\n", fn criterion -> "- #{criterion}" end)
          "Acceptance Criteria:\n#{lines}"
      end

    notes_section =
      if non_empty_string?(story.notes) do
        "Notes:\n#{story.notes}"
      else
        nil
      end

    [story.description, criteria_section, notes_section]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> story.title
      sections -> Enum.join(sections, "\n\n")
    end
  end

  defp normalize_story(story) do
    id = story_id(story)

    %{
      id: id,
      title: optional_string(field(story, :title)) || id || "Untitled story",
      description: optional_string(field(story, :description)) || "",
      acceptance_criteria: string_list(field(story, :acceptanceCriteria)),
      priority: priority(field(story, :priority)),
      status: story_status(story),
      depends_on: string_list(field(story, :dependsOn)),
      notes: optional_string(field(story, :notes))
    }
  end

  defp story_status(story) do
    status =
      case optional_string(field(story, :status)) do
        nil -> if(field(story, :passes) == true, do: "done", else: "open")
        value -> normalize_state(value)
      end

    if status == "" do
      "open"
    else
      status
    end
  end

  defp set_story_status(story, status) do
    story
    |> Map.put("status", status)
    |> Map.put("passes", status == "done")
  end

  defp append_note(story, line) do
    prefix = "[#{now_iso8601()}]"
    next_line = "#{prefix} #{line}"

    notes =
      case optional_string(field(story, :notes)) do
        nil -> next_line
        existing -> "#{existing}\n#{next_line}"
      end

    Map.put(story, "notes", notes)
  end

  defp active_state_set(config) do
    config
    |> get_in([Access.key(:tracker, %{}), Access.key(:active_states, ["open", "in_progress"])])
    |> string_list()
    |> Enum.map(&normalize_state/1)
    |> MapSet.new()
  end

  defp retries_enabled?(config) do
    config
    |> get_in([Access.key(:agent, %{}), Access.key(:retries_enabled)])
    |> case do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(String.trim(value)) in ["true", "1", "yes"]
      _other -> true
    end
  end

  defp tracker_path(config) do
    path =
      config
      |> get_in([Access.key(:tracker, %{}), Access.key(:path)])
      |> optional_string()

    path
    |> Kernel.||(@default_path)
    |> Path.expand()
  end

  defp story_id(story) do
    story
    |> field(:id)
    |> optional_string()
  end

  defp priority(nil), do: @default_priority
  defp priority(value) when is_integer(value), do: value

  defp priority(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> @default_priority
    end
  end

  defp priority(_value), do: @default_priority

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_value(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_value(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify_value(value) when is_struct(value), do: inspect(value)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp normalize_state(state_name) do
    state_name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "_")
    |> String.replace("-", "_")
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp string_list(_values), do: []

  defp optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp optional_string(_value), do: nil

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp blank?(value), do: not non_empty_string?(value)

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end

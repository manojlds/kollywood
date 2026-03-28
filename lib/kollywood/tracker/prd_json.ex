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

  @create_statuses ["draft", "open"]
  @manual_statuses ["draft", "open", "done", "failed", "cancelled"]

  @manual_transition_map %{
    "draft" => ["open", "cancelled"],
    "open" => ["draft", "done", "failed", "cancelled"],
    "in_progress" => ["open", "failed", "cancelled"],
    "failed" => ["open", "cancelled", "draft"],
    "done" => ["open", "failed", "cancelled"],
    "pending_merge" => ["open", "done", "failed", "cancelled"],
    "merged" => ["open", "done"],
    "cancelled" => ["open", "draft"]
  }

  @story_id_regex ~r/^[A-Za-z0-9][A-Za-z0-9\-_]*$/

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
  @spec list_pending_merge_issues(Config.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_pending_merge_issues(%Config{} = config) do
    with {:ok, prd} <- read_prd(config),
         {:ok, stories} <- user_stories(prd) do
      normalized_stories = Enum.map(stories, &normalize_story/1)
      stories_by_id = Map.new(normalized_stories, &{&1.id, &1})

      issues =
        normalized_stories
        |> Enum.filter(fn story ->
          non_empty_string?(story.id) and story.status == "pending_merge" and
            non_empty_string?(story.pr_url)
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
    update_story_record(config, issue_id, fn story ->
      story
      |> set_story_status("in_progress")
      |> Map.put_new("startedAt", now_iso8601())
      |> Map.put("lastError", nil)
    end)
  end

  @impl true
  @spec mark_resumable(Config.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def mark_resumable(%Config{} = config, issue_id, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    note = "[#{now_iso8601()}] continuation scheduled after max turns"

    update_story_record(config, issue_id, fn story ->
      story
      |> set_story_status("in_progress")
      |> Map.put("resumable", true)
      |> append_note(note)
      |> Map.put("lastRun", stringify_map(metadata))
    end)
  end

  @impl true
  @spec mark_done(Config.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def mark_done(%Config{} = config, issue_id, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    update_story_record(config, issue_id, fn story ->
      story
      |> set_story_status("done")
      |> Map.put("completedAt", now_iso8601())
      |> Map.put("lastError", nil)
      |> Map.put("resumable", false)
      |> Map.put("lastRun", stringify_map(metadata))
    end)
  end

  @impl true
  @spec mark_pending_merge(Config.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def mark_pending_merge(%Config{} = config, issue_id, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    pr_url = metadata |> field(:pr_url) |> optional_string()

    update_story_record(config, issue_id, fn story ->
      story
      |> set_story_status("pending_merge")
      |> put_story_field_if_present("pr_url", pr_url)
      |> append_note("pending merge: #{pr_url}")
    end)
  end

  @impl true
  @spec mark_merged(Config.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def mark_merged(%Config{} = config, issue_id, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    _ = metadata

    update_story_record(config, issue_id, fn story ->
      story
      |> set_story_status("merged")
      |> Map.put("mergedAt", now_iso8601())
      |> Map.put("resumable", false)
      |> Map.put("lastError", nil)
      |> append_note("merged to main")
    end)
  end

  @spec reset_story(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def reset_story(tracker_path, issue_id, opts \\ [])
      when is_binary(tracker_path) and is_binary(issue_id) do
    config = %Config{tracker: %{path: tracker_path}}
    clear_notes? = Keyword.get(opts, :clear_notes, false)

    update_story_record(config, issue_id, fn story ->
      story
      |> set_story_status("open")
      |> Map.delete("startedAt")
      |> Map.delete("completedAt")
      |> Map.delete("lastAttempt")
      |> Map.delete("lastRunAttempt")
      |> Map.delete("lastError")
      |> Map.delete("lastRun")
      |> reset_notes(clear_notes?)
    end)
  end

  @spec list_stories(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_stories(tracker_path) when is_binary(tracker_path) do
    config = tracker_config(tracker_path)

    with {:ok, prd} <- read_prd(config),
         {:ok, stories} <- user_stories(prd) do
      {:ok, stories}
    end
  end

  def list_stories(_tracker_path), do: {:error, "tracker path must be a string"}

  @spec create_story(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def create_story(tracker_path, attrs) when is_binary(tracker_path) and is_map(attrs) do
    config = tracker_config(tracker_path)

    with {:ok, prd} <- read_prd(config),
         {:ok, stories} <- user_stories(prd),
         {:ok, new_story} <- build_new_story(stories, attrs),
         :ok <- write_prd(config, Map.put(prd, "userStories", stories ++ [new_story])) do
      {:ok, new_story}
    end
  end

  def create_story(_tracker_path, _attrs), do: {:error, "invalid story payload"}

  @spec update_story(String.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def update_story(tracker_path, issue_id, attrs)
      when is_binary(tracker_path) and is_binary(issue_id) and is_map(attrs) do
    config = tracker_config(tracker_path)

    with {:ok, prd} <- read_prd(config),
         {:ok, stories} <- user_stories(prd),
         {:ok, {story, index}} <- fetch_story_with_index(stories, issue_id),
         {:ok, updated_story} <- apply_story_updates(story, attrs, stories),
         :ok <-
           write_prd(
             config,
             Map.put(prd, "userStories", List.replace_at(stories, index, updated_story))
           ) do
      {:ok, updated_story}
    end
  end

  def update_story(_tracker_path, _issue_id, _attrs), do: {:error, "invalid story update payload"}

  @spec delete_story(String.t(), String.t()) :: :ok | {:error, String.t()}
  def delete_story(tracker_path, issue_id)
      when is_binary(tracker_path) and is_binary(issue_id) do
    config = tracker_config(tracker_path)

    with {:ok, prd} <- read_prd(config),
         {:ok, stories} <- user_stories(prd),
         :ok <- ensure_story_is_not_dependency(stories, issue_id),
         {:ok, filtered_stories} <- remove_story(stories, issue_id),
         :ok <- write_prd(config, Map.put(prd, "userStories", filtered_stories)) do
      :ok
    end
  end

  def delete_story(_tracker_path, _issue_id), do: {:error, "invalid story id"}

  @spec set_manual_status(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def set_manual_status(tracker_path, issue_id, status)
      when is_binary(tracker_path) and is_binary(issue_id) and is_binary(status) do
    case update_story(tracker_path, issue_id, %{"status" => status}) do
      {:ok, _story} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def set_manual_status(_tracker_path, _issue_id, _status), do: {:error, "invalid status update"}

  @spec manual_transition_targets(String.t() | nil) :: [String.t()]
  def manual_transition_targets(status) do
    status
    |> normalize_state()
    |> then(&Map.get(@manual_transition_map, &1, []))
  end

  @impl true
  @spec mark_failed(Config.t(), String.t(), String.t(), pos_integer()) ::
          :ok | {:error, String.t()}
  def mark_failed(%Config{} = config, issue_id, reason, attempt)
      when is_binary(issue_id) and is_binary(reason) and is_integer(attempt) and attempt > 0 do
    failed_status = if(retries_enabled?(config), do: "in_progress", else: "failed")

    update_story_record(config, issue_id, fn story ->
      story
      |> set_story_status(failed_status)
      |> Map.put("lastError", reason)
      |> Map.put("lastRunAttempt", attempt)
      |> Map.delete("lastAttempt")
      |> append_note("attempt #{attempt}: #{reason}")
    end)
  end

  defp build_new_story(stories, attrs) when is_list(stories) and is_map(attrs) do
    next_priority = next_priority(stories)

    with {:ok, story_id} <- resolve_story_id(attrs, stories),
         :ok <- validate_story_id_format(story_id),
         {:ok, title} <- required_input_string(attrs, [:title]),
         {:ok, status} <- create_status(attrs),
         {:ok, priority} <- parse_priority_input(fetch_input(attrs, [:priority]), next_priority),
         {:ok, depends_on} <- parse_depends_on(fetch_input(attrs, [:depends_on, :dependsOn])),
         :ok <- validate_dependencies(depends_on, story_id, stories),
         acceptance_criteria <-
           parse_acceptance_criteria(
             fetch_input(attrs, [:acceptance_criteria, :acceptanceCriteria])
           ) do
      {:ok,
       %{
         "id" => story_id,
         "title" => title,
         "description" => optional_string_value(fetch_input(attrs, [:description]), ""),
         "acceptanceCriteria" => acceptance_criteria,
         "priority" => priority,
         "status" => status,
         "dependsOn" => depends_on,
         "notes" => optional_string_value(fetch_input(attrs, [:notes]), ""),
         "passes" => status in ["done", "merged"]
       }}
    end
  end

  defp apply_story_updates(story, attrs, stories)
       when is_map(story) and is_map(attrs) and is_list(stories) do
    with :ok <- ensure_story_id_is_not_changed(story, attrs),
         {:ok, story} <- maybe_update_story_title(story, attrs),
         {:ok, story} <- maybe_update_story_description(story, attrs),
         {:ok, story} <- maybe_update_story_notes(story, attrs),
         {:ok, story} <- maybe_update_story_priority(story, attrs),
         {:ok, story} <- maybe_update_story_status(story, attrs),
         {:ok, story} <- maybe_update_story_acceptance_criteria(story, attrs),
         {:ok, story} <- maybe_update_story_dependencies(story, attrs, stories) do
      {:ok, story}
    end
  end

  defp maybe_update_story_title(story, attrs) do
    case fetch_input(attrs, [:title]) do
      :error ->
        {:ok, story}

      value ->
        case optional_string(value) do
          nil -> {:error, "title is required"}
          title -> {:ok, Map.put(story, "title", title)}
        end
    end
  end

  defp maybe_update_story_description(story, attrs) do
    case fetch_input(attrs, [:description]) do
      :error -> {:ok, story}
      value -> {:ok, Map.put(story, "description", optional_string_value(value, ""))}
    end
  end

  defp maybe_update_story_notes(story, attrs) do
    case fetch_input(attrs, [:notes]) do
      :error -> {:ok, story}
      value -> {:ok, Map.put(story, "notes", optional_string_value(value, ""))}
    end
  end

  defp maybe_update_story_priority(story, attrs) do
    case fetch_input(attrs, [:priority]) do
      :error ->
        {:ok, story}

      value ->
        case parse_priority_input(value, field(story, :priority) || @default_priority) do
          {:ok, priority} -> {:ok, Map.put(story, "priority", priority)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_update_story_status(story, attrs) do
    case fetch_input(attrs, [:status]) do
      :error ->
        {:ok, story}

      value ->
        current_status = story_status(story)
        target_status = normalize_state(value)

        with :ok <- validate_manual_status_transition(current_status, target_status) do
          {:ok, set_story_status(story, target_status)}
        end
    end
  end

  defp maybe_update_story_acceptance_criteria(story, attrs) do
    case fetch_input(attrs, [:acceptance_criteria, :acceptanceCriteria]) do
      :error -> {:ok, story}
      value -> {:ok, Map.put(story, "acceptanceCriteria", parse_acceptance_criteria(value))}
    end
  end

  defp maybe_update_story_dependencies(story, attrs, stories) do
    case fetch_input(attrs, [:depends_on, :dependsOn]) do
      :error ->
        {:ok, story}

      value ->
        with {:ok, depends_on} <- parse_depends_on(value),
             :ok <- validate_dependencies(depends_on, story_id(story), stories) do
          {:ok, Map.put(story, "dependsOn", depends_on)}
        end
    end
  end

  defp ensure_story_id_is_not_changed(story, attrs) do
    case fetch_input(attrs, [:id]) do
      :error ->
        :ok

      value ->
        existing_id = story_id(story)

        if optional_string(value) in [nil, existing_id] do
          :ok
        else
          {:error, "story id cannot be changed"}
        end
    end
  end

  defp resolve_story_id(attrs, stories) do
    story_id =
      attrs
      |> fetch_input([:id])
      |> optional_string()
      |> Kernel.||(next_story_id(stories))

    if Enum.any?(stories, &(story_id(&1) == story_id)) do
      {:error, "story id already exists: #{story_id}"}
    else
      {:ok, story_id}
    end
  end

  defp validate_story_id_format(story_id) when is_binary(story_id) do
    cond do
      String.trim(story_id) == "" ->
        {:error, "story id is required"}

      not Regex.match?(@story_id_regex, story_id) ->
        {:error, "story id must be alphanumeric and may include '-' or '_'"}

      true ->
        :ok
    end
  end

  defp create_status(attrs) do
    status =
      attrs
      |> fetch_input([:status])
      |> optional_string()
      |> Kernel.||("draft")
      |> normalize_state()

    if status in @create_statuses do
      {:ok, status}
    else
      {:error, "new stories must start as draft or open"}
    end
  end

  defp required_input_string(attrs, keys) do
    case optional_string(fetch_input(attrs, keys)) do
      nil -> {:error, "title is required"}
      value -> {:ok, value}
    end
  end

  defp parse_priority_input(:error, fallback), do: {:ok, priority(fallback)}
  defp parse_priority_input(nil, fallback), do: {:ok, priority(fallback)}

  defp parse_priority_input(value, _fallback) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_priority_input(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:ok, priority(fallback)}
    else
      case Integer.parse(trimmed) do
        {parsed, ""} when parsed > 0 -> {:ok, parsed}
        _other -> {:error, "priority must be a positive integer"}
      end
    end
  end

  defp parse_priority_input(_value, _fallback),
    do: {:error, "priority must be a positive integer"}

  defp parse_depends_on(:error), do: {:ok, []}
  defp parse_depends_on(nil), do: {:ok, []}

  defp parse_depends_on(value) when is_binary(value) do
    value
    |> String.split(~r/[\n,]/, trim: true)
    |> normalize_dependency_ids()
    |> then(&{:ok, &1})
  end

  defp parse_depends_on(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> normalize_dependency_ids()
    |> then(&{:ok, &1})
  end

  defp parse_depends_on(_value),
    do: {:error, "dependsOn must be a list or comma-separated string"}

  defp normalize_dependency_ids(values) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp validate_dependencies(depends_on, story_id, stories)
       when is_list(depends_on) and is_binary(story_id) do
    existing_ids =
      stories
      |> Enum.map(&story_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    invalid_dependencies = Enum.reject(depends_on, &MapSet.member?(existing_ids, &1))

    cond do
      Enum.member?(depends_on, story_id) ->
        {:error, "story cannot depend on itself"}

      invalid_dependencies != [] ->
        joined = Enum.join(invalid_dependencies, ", ")
        {:error, "dependsOn references unknown stories: #{joined}"}

      true ->
        :ok
    end
  end

  defp validate_manual_status_transition(current_status, target_status) do
    current_status = normalize_state(current_status)
    target_status = normalize_state(target_status)

    cond do
      target_status == "" ->
        {:error, "status is required"}

      target_status == current_status ->
        :ok

      target_status not in @manual_statuses ->
        {:error, "status #{target_status} is managed by the orchestrator"}

      target_status in manual_transition_targets(current_status) ->
        :ok

      true ->
        allowed =
          manual_transition_targets(current_status) |> Enum.map_join(", ", &display_status_name/1)

        {:error,
         "invalid status transition: #{display_status_name(current_status)} -> #{display_status_name(target_status)}. Allowed: #{allowed}"}
    end
  end

  defp parse_acceptance_criteria(:error), do: []
  defp parse_acceptance_criteria(nil), do: []

  defp parse_acceptance_criteria(value) when is_binary(value) do
    value
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.trim_leading(&1, "-"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_acceptance_criteria(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_acceptance_criteria(_value), do: []

  defp optional_string_value(value, default) do
    case optional_string(value) do
      nil -> default
      normalized -> normalized
    end
  end

  defp fetch_input(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, :error, fn key ->
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

  defp fetch_input(_map, _keys), do: :error

  defp fetch_story_with_index(stories, issue_id) when is_list(stories) do
    case Enum.find_index(stories, &(story_id(&1) == issue_id)) do
      nil -> {:error, "issue not found in PRD: #{issue_id}"}
      index -> {:ok, {Enum.at(stories, index), index}}
    end
  end

  defp ensure_story_is_not_dependency(stories, issue_id) do
    dependents =
      stories
      |> Enum.filter(fn story -> issue_id in string_list(field(story, :dependsOn)) end)
      |> Enum.map(&story_id/1)
      |> Enum.reject(&is_nil/1)

    if dependents == [] do
      :ok
    else
      {:error, "cannot delete #{issue_id}; depended on by #{Enum.join(dependents, ", ")}"}
    end
  end

  defp remove_story(stories, issue_id) do
    {filtered, removed?} =
      Enum.reduce(stories, {[], false}, fn story, {acc, removed?} ->
        if story_id(story) == issue_id do
          {acc, true}
        else
          {[story | acc], removed?}
        end
      end)

    if removed? do
      {:ok, Enum.reverse(filtered)}
    else
      {:error, "issue not found in PRD: #{issue_id}"}
    end
  end

  defp next_story_id(stories) do
    next_number =
      stories
      |> Enum.map(&story_id/1)
      |> Enum.map(fn
        "US-" <> rest ->
          case Integer.parse(rest) do
            {num, ""} when num > 0 -> num
            _ -> nil
          end

        _other ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    "US-" <> String.pad_leading(Integer.to_string(next_number), 3, "0")
  end

  defp next_priority(stories) do
    stories
    |> Enum.map(&priority(field(&1, :priority)))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp display_status_name(status) do
    status
    |> normalize_state()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp tracker_config(tracker_path) do
    %Config{tracker: %{path: tracker_path}}
  end

  defp update_story_record(config, issue_id, update_fun) do
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
      resumable: story.resumable,
      pr_url: story.pr_url,
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
      notes: optional_string(field(story, :notes)),
      resumable: field(story, :resumable) == true,
      pr_url: optional_string(field(story, :pr_url))
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
    |> Map.put("passes", status in ["done", "merged"])
  end

  defp reset_notes(story, true), do: Map.put(story, "notes", "")
  defp reset_notes(story, false), do: append_note(story, "reset for rerun")

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

  defp put_story_field_if_present(story, _field_name, nil), do: story
  defp put_story_field_if_present(story, field_name, value), do: Map.put(story, field_name, value)

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
    slug =
      config
      |> get_in([Access.key(:tracker, %{}), Access.key(:project_slug)])
      |> optional_string()

    if slug do
      Kollywood.ServiceConfig.project_tracker_path(slug)
    else
      path =
        config
        |> get_in([Access.key(:tracker, %{}), Access.key(:path)])
        |> optional_string()
        |> Kernel.||(@default_path)

      source = get_in(config, [Access.key(:workspace, %{}), Access.key(:source)])

      if is_binary(source) do
        Path.expand(path, source)
      else
        Path.expand(path)
      end
    end
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

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

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

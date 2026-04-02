defmodule Kollywood.Tracker.PrdJsonArchive do
  @moduledoc """
  Companion archive file (`prd.archive.json`) for merged stories moved out of `prd.json`.

  Stories with `status` merged and a merge timestamp older than the configured age are
  moved into the archive file. Each JSON file is written via a temp file and atomic
  rename so a single file is never half-written.

  Because updates involve two files, a crash between writes can leave the same story id
  in both places. Before archiving, overlapping ids are removed from the archive so
  `prd.json` remains canonical; the next successful archival pass moves merged stories
  again. Restore writes `prd.json` first, then the archive, so a partial failure at most
  duplicates across files until reconciliation runs.
  """

  @default_min_age_seconds 24 * 60 * 60

  @doc """
  Path to the archive JSON next to the tracker file (e.g. `prd.json` → `prd.archive.json`).
  """
  @spec archive_path(String.t()) :: String.t()
  def archive_path(tracker_path) when is_binary(tracker_path) do
    dir = Path.dirname(tracker_path)
    base = Path.basename(tracker_path)
    root = Path.rootname(base)
    Path.join(dir, "#{root}.archive.json")
  end

  @doc """
  Returns archived `userStories` from the archive file, or an empty list if missing/invalid.
  """
  @spec list_archived(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_archived(tracker_path) when is_binary(tracker_path) do
    path = archive_path(tracker_path)

    case File.read(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"userStories" => stories}} when is_list(stories) ->
            {:ok, stories}

          {:ok, _} ->
            {:error, "archive file is missing a valid userStories array: #{path}"}

          {:error, reason} ->
            {:error, "failed to parse archive #{path}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "failed to read archive #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Moves merged stories older than `min_age_seconds` (default 24h) from the tracker into
  the archive file. Idempotent: safe to run repeatedly.

  Options:
    * `:now` — `DateTime` (UTC) for tests
    * `:min_age_seconds` — minimum age in seconds (default #{@default_min_age_seconds})
  """
  @spec archive_stale_merged(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def archive_stale_merged(tracker_path, opts \\ []) when is_binary(tracker_path) do
    min_age = Keyword.get(opts, :min_age_seconds, @default_min_age_seconds)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, prd} <- read_prd_map(tracker_path),
         :ok <- reconcile_archive_vs_active(tracker_path, prd),
         {:ok, stories} <- user_stories_list(prd),
         {:ok, {to_archive, keep}} <- partition_merged_stale(stories, now, min_age) do
      if to_archive == [] do
        {:ok, 0}
      else
        do_archive_move(tracker_path, prd, to_archive, keep, now)
      end
    end
  end

  @doc """
  Restores one story from the archive back into the active tracker file.

  The story is removed from the archive (deduped list) and appended to the tracker's
  `userStories` if the id is not already present in `prd.json`.
  """
  @spec restore_story(String.t(), String.t()) :: :ok | {:error, String.t()}
  def restore_story(tracker_path, story_id)
      when is_binary(tracker_path) and is_binary(story_id) do
    story_id = String.trim(story_id)

    if story_id == "" do
      {:error, "story id is required"}
    else
      do_restore(tracker_path, story_id)
    end
  end

  defp do_restore(tracker_path, story_id) do
    archive_file = archive_path(tracker_path)

    with {:ok, prd} <- read_prd_map(tracker_path),
         {:ok, active} <- user_stories_list(prd),
         :ok <- ensure_absent(active, story_id, tracker_path),
         {:ok, archive_doc} <- read_or_init_archive(archive_file, prd),
         {:ok, story, rest} <-
           pop_story_or_error(Map.get(archive_doc, "userStories", []), story_id) do
      restored = Map.drop(story, ["archivedAt"])
      new_prd = Map.put(prd, "userStories", active ++ [restored])
      new_archive = Map.put(archive_doc, "userStories", rest)

      with :ok <- write_json_atomic(tracker_path, new_prd),
           :ok <- write_json_atomic(archive_file, new_archive) do
        :ok
      end
    end
  end

  defp ensure_absent(stories, story_id, tracker_path) do
    if id_in_stories?(stories, story_id) do
      {:error, "story #{story_id} already exists in #{tracker_path}"}
    else
      :ok
    end
  end

  defp pop_story_or_error(stories, story_id) do
    case pop_story_by_id(stories, story_id) do
      {nil, _} -> {:error, "story not found in archive: #{story_id}"}
      {story, rest} -> {:ok, story, rest}
    end
  end

  defp pop_story_by_id(stories, story_id) do
    case Enum.split_with(stories, &(story_id(&1) != story_id)) do
      {_, []} ->
        {nil, stories}

      {kept, [one | dup]} ->
        {one, kept ++ dup}
    end
  end

  defp id_in_stories?(stories, story_id) do
    Enum.any?(stories, &(story_id(&1) == story_id))
  end

  defp do_archive_move(tracker_path, prd, to_archive, keep, now) do
    archive_file = archive_path(tracker_path)
    archived_payload = Enum.map(to_archive, &tag_archived_at(&1, now))

    # Append to archive first, then shrink prd.json. If the tracker write fails, the
    # story still exists in prd (no loss). reconcile_archive_vs_active/2 drops archive
    # rows that still appear in prd before the next pass.
    with {:ok, archive_doc} <- read_or_init_archive(archive_file, prd),
         merged_stories =
           dedupe_last_wins(Map.get(archive_doc, "userStories", []) ++ archived_payload),
         new_archive = Map.put(archive_doc, "userStories", merged_stories),
         new_prd = Map.put(prd, "userStories", keep),
         :ok <- write_json_atomic(archive_file, new_archive),
         :ok <- write_json_atomic(tracker_path, new_prd) do
      {:ok, length(to_archive)}
    end
  end

  # Drops archived entries whose id still appears in the active tracker. Active prd is
  # authoritative; this heals restore after a failed archive write and clears stale
  # archive copies when the tracker write failed after a successful archive append.
  defp reconcile_archive_vs_active(tracker_path, prd) when is_map(prd) do
    archive_file = archive_path(tracker_path)

    with {:ok, active} <- user_stories_list(prd),
         {:ok, pair} <- read_archive_for_reconcile(archive_file) do
      case pair do
        :missing ->
          :ok

        {archive_doc, archived} ->
          active_ids =
            active
            |> Enum.map(&story_id/1)
            |> Enum.filter(&is_binary/1)
            |> MapSet.new()

          new_archived =
            Enum.reject(archived, fn s ->
              id = story_id(s)
              id && MapSet.member?(active_ids, id)
            end)

          new_archived = dedupe_last_wins(new_archived)

          if length(new_archived) == length(archived) do
            :ok
          else
            new_doc = Map.put(archive_doc, "userStories", new_archived)
            write_json_atomic(archive_file, new_doc)
          end
      end
    end
  end

  defp read_archive_for_reconcile(archive_file) do
    case File.read(archive_file) do
      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, "failed to read archive #{archive_file}: #{inspect(reason)}"}

      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) ->
            {:ok, {map, Map.get(map, "userStories", [])}}

          {:error, reason} ->
            {:error, "failed to parse archive #{archive_file}: #{inspect(reason)}"}
        end
    end
  end

  defp tag_archived_at(story, %DateTime{} = now) do
    ts = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Map.put(story, "archivedAt", ts)
  end

  defp read_or_init_archive(archive_file, prd_template) do
    case File.read(archive_file) do
      {:error, :enoent} ->
        {:ok, archive_skeleton(prd_template)}

      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) ->
            {:ok, map}

          {:error, reason} ->
            {:error, "failed to parse archive #{archive_file}: #{inspect(reason)}"}
        end
    end
  end

  defp archive_skeleton(prd) when is_map(prd) do
    prd
    |> Map.drop(["userStories"])
    |> Map.put("userStories", [])
  end

  defp partition_merged_stale(stories, %DateTime{} = now, min_age_seconds)
       when is_list(stories) and is_integer(min_age_seconds) and min_age_seconds >= 0 do
    cutoff = DateTime.add(now, -min_age_seconds, :second)

    {to_take, keep} =
      Enum.split_with(stories, fn story ->
        merged_old_enough?(story, cutoff)
      end)

    {:ok, {to_take, keep}}
  end

  defp merged_old_enough?(story, %DateTime{} = cutoff) do
    case normalize_story_status(story) do
      "merged" ->
        case story_merged_at(story) do
          nil -> false
          %DateTime{} = at -> DateTime.compare(at, cutoff) != :gt
        end

      _ ->
        false
    end
  end

  defp normalize_story_status(story) do
    case Map.get(story, "status") do
      s when is_binary(s) ->
        s
        |> String.trim()
        |> String.downcase()
        |> String.replace(" ", "_")
        |> String.replace("-", "_")

      _ ->
        if Map.get(story, "passes") == true, do: "done", else: ""
    end
  end

  @doc false
  @spec story_merged_at(map()) :: DateTime.t() | nil
  def story_merged_at(story) when is_map(story) do
    [
      Map.get(story, "mergedAt"),
      get_in(story, ["internalMetadata", "merge", "recordedAt"]),
      merge_transition_time(story),
      last_transition_recorded_at(story),
      Map.get(story, "updatedAt")
    ]
    |> Enum.find_value(&parse_iso8601/1)
  end

  defp merge_transition_time(story) do
    case get_in(story, ["internalMetadata", "lastTransition"]) do
      %{"event" => ev, "recordedAt" => t} ->
        if transition_event_merged?(ev), do: t

      %{event: ev, recordedAt: t} ->
        if transition_event_merged?(ev), do: t

      _ ->
        nil
    end
  end

  defp last_transition_recorded_at(story) do
    case get_in(story, ["internalMetadata", "lastTransition"]) do
      %{"recordedAt" => t} -> t
      %{recordedAt: t} -> t
      _ -> nil
    end
  end

  defp transition_event_merged?(ev) when is_binary(ev) do
    ev |> String.trim() |> String.downcase() |> String.replace(" ", "_") == "merged"
  end

  defp transition_event_merged?(ev) when is_atom(ev), do: ev == :merged
  defp transition_event_merged?(_), do: false

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(s) when is_binary(s) do
    s = String.trim(s)
    if s == "", do: nil, else: do_parse_iso8601(s)
  end

  defp parse_iso8601(_), do: nil

  defp do_parse_iso8601(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        dt

      {:error, _} ->
        case NaiveDateTime.from_iso8601(s) do
          {:ok, naive} ->
            case DateTime.from_naive(naive, "Etc/UTC") do
              {:ok, dt} -> dt
              {:ambiguous, dt, _} -> dt
              {:gap, _, _} -> nil
            end

          {:error, _} ->
            nil
        end
    end
  end

  defp story_id(story) do
    case Map.get(story, "id") || Map.get(story, :id) do
      s when is_binary(s) -> String.trim(s)
      _ -> nil
    end
  end

  defp dedupe_last_wins(stories) when is_list(stories) do
    stories
    |> Enum.reverse()
    |> Enum.uniq_by(fn s -> story_id(s) || :unknown end)
    |> Enum.reverse()
  end

  defp read_prd_map(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:error, "PRD file not found: #{path}"}

      {:error, reason} ->
        {:error, "failed to read PRD #{path}: #{inspect(reason)}"}

      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:error, reason} -> {:error, "failed to parse PRD #{path}: #{inspect(reason)}"}
        end
    end
  end

  defp user_stories_list(prd) do
    case Map.get(prd, "userStories") do
      stories when is_list(stories) -> {:ok, stories}
      _ -> {:error, "PRD is missing userStories array"}
    end
  end

  @doc """
  Writes JSON to `path` via a temp file and atomic rename (same directory).
  """
  @spec write_json_atomic(String.t(), map()) :: :ok | {:error, String.t()}
  def write_json_atomic(path, data) when is_binary(path) and is_map(data) do
    temp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"
    encoded = Jason.encode_to_iodata!(data, pretty: true)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp_path, [encoded, "\n"]),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, "failed to write #{path}: #{inspect(reason)}"}
    end
  end
end

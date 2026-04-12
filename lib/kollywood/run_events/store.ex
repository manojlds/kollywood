defmodule Kollywood.RunEvents.Store do
  @moduledoc false

  import Ecto.Query

  alias Kollywood.Repo
  alias Kollywood.RunEvents.Entry

  @default_limit 2_000
  @max_limit 2_000
  @insert_retry_attempts 3

  @type stream :: %{project_slug: String.t(), story_id: String.t(), attempt: pos_integer()}

  @spec append(map(), map(), atom() | String.t()) :: :ok | {:error, term()}
  def append(context, event, category) when is_map(context) and is_map(event) do
    with {:ok, stream} <- stream_from_context(context, event),
         {:ok, event_type} <- event_type(event),
         {:ok, payload_json} <- encode_json(event),
         {:ok, run_state_json} <- encode_optional_json(field(event, :run_state)),
         {:ok, occurred_at} <- parse_occurred_at(field(event, :timestamp)) do
      base_attrs = %{
        project_slug: stream.project_slug,
        story_id: stream.story_id,
        attempt: stream.attempt,
        event_type: event_type,
        category: encode_category(category),
        occurred_at: occurred_at,
        turn: positive_integer_or_nil(field(event, :turn)),
        cycle: positive_integer_or_nil(field(event, :cycle)),
        run_state_json: run_state_json,
        payload_json: payload_json
      }

      case repo_operation(fn -> insert_with_retry(stream, base_attrs, @insert_retry_attempts) end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def append(_context, _event, _category), do: :ok

  @spec stream_exists?(String.t(), String.t(), pos_integer()) ::
          {:ok, boolean()} | {:error, term()}
  def stream_exists?(project_slug, story_id, attempt)
      when is_binary(project_slug) and is_binary(story_id) and is_integer(attempt) and attempt > 0 do
    query =
      from(entry in Entry,
        where:
          entry.project_slug == ^project_slug and entry.story_id == ^story_id and
            entry.attempt == ^attempt,
        select: entry.id,
        limit: 1
      )

    case repo_operation(fn -> Repo.one(query) != nil end) do
      {:ok, exists?} -> {:ok, exists?}
      {:error, reason} -> {:error, reason}
    end
  end

  def stream_exists?(_project_slug, _story_id, _attempt), do: {:error, :invalid_selector}

  @spec list_events(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()], non_neg_integer()} | {:error, term()}
  def list_events(project_slug, story_id, attempt, opts \\ [])

  def list_events(project_slug, story_id, attempt, opts)
      when is_binary(project_slug) and is_binary(story_id) and is_integer(attempt) and attempt > 0 and
             is_list(opts) do
    since = non_negative_integer(Keyword.get(opts, :since), 0)

    limit =
      opts
      |> Keyword.get(:limit)
      |> positive_integer(@default_limit)
      |> min(@max_limit)

    query =
      from(entry in Entry,
        where:
          entry.project_slug == ^project_slug and entry.story_id == ^story_id and
            entry.attempt == ^attempt and entry.seq > ^since,
        order_by: [asc: entry.seq],
        limit: ^limit
      )

    case repo_operation(fn -> Repo.all(query) end) do
      {:ok, rows} ->
        events =
          rows
          |> Enum.reduce([], fn row, acc ->
            case decode_payload(row) do
              {:ok, payload} -> [payload | acc]
              :error -> acc
            end
          end)
          |> Enum.reverse()

        next_cursor =
          case List.last(rows) do
            nil -> since
            row -> row.seq
          end

        {:ok, events, next_cursor}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_events(_project_slug, _story_id, _attempt, _opts), do: {:error, :invalid_selector}

  defp insert_with_retry(_stream, _attrs, attempts_left) when attempts_left <= 0,
    do: {:error, :sequence_conflict}

  defp insert_with_retry(stream, attrs, attempts_left) do
    seq = next_sequence(stream)
    changeset = Entry.changeset(%Entry{}, Map.put(attrs, :seq, seq))

    case Repo.insert(changeset) do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        if unique_sequence_conflict?(changeset) and attempts_left > 1 do
          insert_with_retry(stream, attrs, attempts_left - 1)
        else
          {:error, changeset_error(changeset)}
        end
    end
  end

  defp next_sequence(stream) do
    max_seq =
      from(entry in Entry,
        where:
          entry.project_slug == ^stream.project_slug and entry.story_id == ^stream.story_id and
            entry.attempt == ^stream.attempt,
        select: max(entry.seq)
      )
      |> Repo.one()

    if is_integer(max_seq), do: max_seq + 1, else: 1
  end

  defp stream_from_context(context, event) do
    with {:ok, project_slug} <- project_slug_from_context(context),
         {:ok, story_id} <- story_id_from_context(context, event),
         {:ok, attempt} <- attempt_from_context(context, event) do
      {:ok, %{project_slug: project_slug, story_id: story_id, attempt: attempt}}
    end
  end

  defp project_slug_from_context(context) do
    explicit =
      context
      |> field(:project_slug)
      |> optional_string()

    from_root =
      context
      |> field(:project_root)
      |> optional_string()
      |> case do
        nil -> nil
        root -> root |> String.trim_trailing("/") |> Path.basename() |> optional_string()
      end

    from_events_path =
      context
      |> field(:files)
      |> infer_project_slug_from_files()

    case explicit || from_root || from_events_path do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_project_slug}
    end
  end

  defp infer_project_slug_from_files(files) when is_map(files) do
    files
    |> candidate_project_paths()
    |> Enum.find_value(&extract_project_slug_from_path/1)
  end

  defp infer_project_slug_from_files(_files), do: nil

  defp candidate_project_paths(files) when is_map(files) do
    [
      field(files, :metadata),
      field(files, :run),
      field(files, :worker),
      field(files, :reviewer),
      field(files, :tester),
      field(files, :checks),
      field(files, :runtime),
      field(files, :agent),
      field(files, :agent_stdout),
      field(files, :reviewer_stdout),
      field(files, :tester_stdout),
      field(files, :steps_dir),
      field(files, :step_events),
      field(files, :attempts_index)
    ]
    |> Enum.map(&optional_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp candidate_project_paths(_files), do: []

  defp extract_project_slug_from_path(path) when is_binary(path) do
    segments =
      path
      |> Path.expand()
      |> Path.split()

    case Enum.find_index(segments, &(&1 == "run_logs")) do
      idx when is_integer(idx) and idx > 0 ->
        segments
        |> Enum.at(idx - 1)
        |> optional_string()

      _other ->
        nil
    end
  end

  defp extract_project_slug_from_path(_path), do: nil

  defp story_id_from_context(context, event) do
    value =
      context
      |> field(:story_id)
      |> optional_string()
      |> Kernel.||(event |> field(:story_id) |> optional_string())

    case value do
      story_id when is_binary(story_id) and story_id != "" -> {:ok, story_id}
      _other -> {:error, :missing_story_id}
    end
  end

  defp attempt_from_context(context, event) do
    value =
      context
      |> field(:attempt)
      |> positive_integer_or_nil()
      |> Kernel.||(event |> field(:attempt) |> positive_integer_or_nil())

    case value do
      attempt when is_integer(attempt) and attempt > 0 -> {:ok, attempt}
      _other -> {:error, :missing_attempt}
    end
  end

  defp event_type(event) do
    value =
      event
      |> field(:type)
      |> optional_string()

    case value do
      type when is_binary(type) and type != "" -> {:ok, type}
      _other -> {:error, :missing_event_type}
    end
  end

  defp encode_category(category) when is_atom(category), do: Atom.to_string(category)

  defp encode_category(category) when is_binary(category) do
    case String.trim(category) do
      "" -> "worker"
      value -> value
    end
  end

  defp encode_category(_category), do: "worker"

  defp parse_occurred_at(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :microsecond)}

  defp parse_occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _other -> {:ok, now_datetime()}
    end
  end

  defp parse_occurred_at(_value), do: {:ok, now_datetime()}

  defp now_datetime do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
  end

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  defp encode_optional_json(nil), do: {:ok, nil}

  defp encode_optional_json(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :invalid_run_state}
    end
  end

  defp encode_optional_json(_value), do: {:ok, nil}

  defp decode_payload(%Entry{} = entry) do
    with {:ok, payload} <- Jason.decode(entry.payload_json),
         true <- is_map(payload) do
      {:ok,
       payload
       |> Map.put_new("type", entry.event_type)
       |> Map.put_new("timestamp", DateTime.to_iso8601(entry.occurred_at))}
    else
      _other ->
        :error
    end
  end

  defp unique_sequence_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_message, meta}} ->
      constraint_name = Keyword.get(meta, :constraint_name)

      field == :seq and
        constraint_name in [
          "run_event_entries_stream_seq_index",
          :run_event_entries_stream_seq_index
        ]
    end)
  end

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> inspect()
  end

  defp repo_operation(fun) when is_function(fun, 0) do
    if is_pid(Process.whereis(Repo)) do
      try do
        {:ok, fun.()}
      rescue
        error in DBConnection.OwnershipError ->
          {:error, {:ownership_error, Exception.message(error)}}

        error ->
          {:error, classify_repo_error(error)}
      catch
        :exit, reason ->
          {:error, {:repo_exit, reason}}
      end
    else
      {:error, :repo_unavailable}
    end
  end

  defp classify_repo_error(error) do
    message = Exception.message(error)

    cond do
      String.contains?(message, "no such table: run_event_entries") -> :table_missing
      String.contains?(message, "relation \"run_event_entries\" does not exist") -> :table_missing
      true -> {:repo_error, message}
    end
  end

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _other -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

  defp non_negative_integer(value, _fallback) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 -> int
      _other -> fallback
    end
  end

  defp non_negative_integer(_value, fallback), do: fallback

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: value

  defp positive_integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _other -> nil
    end
  end

  defp positive_integer_or_nil(_value), do: nil

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> optional_string()

  defp optional_string(value) when is_integer(value),
    do: value |> Integer.to_string() |> optional_string()

  defp optional_string(_value), do: nil

  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_map, _key), do: nil
end

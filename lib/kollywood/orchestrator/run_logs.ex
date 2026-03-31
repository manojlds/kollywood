defmodule Kollywood.Orchestrator.RunLogs do
  @moduledoc """
  Persists per-story run attempt metadata and append-only logs.

  Log layout:

      <project_data_root>/run_logs/<story_id>/
        attempts.jsonl
        attempt-0001/
          metadata.json
          events.jsonl
          run.log
          worker.log
          reviewer.log
          tester.log
          checks.log
          runtime.log
          testing_report.json
          testing_artifacts/

  `run.log` is a merged stream, while category files keep focused slices for
  worker/reviewer/check/runtime output.
  """

  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.ServiceConfig

  @base_log_dir ["run_logs"]

  @worker_events [
    "run_started",
    "workspace_ready",
    "session_started",
    "turn_started",
    "turn_succeeded",
    "turn_failed",
    "session_stopped",
    "session_stop_failed",
    "quality_cycle_started",
    "quality_cycle_passed",
    "quality_cycle_retrying",
    "run_finished"
  ]

  @review_events [
    "review_started",
    "review_passed",
    "review_failed",
    "review_error"
  ]

  @testing_events [
    "testing_started",
    "testing_checkpoint",
    "testing_passed",
    "testing_failed",
    "testing_error"
  ]

  @checks_events [
    "checks_started",
    "check_started",
    "check_passed",
    "check_failed",
    "checks_passed",
    "checks_failed"
  ]

  @runtime_events [
    "runtime_starting",
    "runtime_started",
    "runtime_start_failed",
    "runtime_healthcheck_started",
    "runtime_healthcheck_passed",
    "runtime_healthcheck_failed",
    "runtime_stopping",
    "runtime_stopped",
    "runtime_stop_failed"
  ]

  @agent_log_events [
    "turn_succeeded",
    "review_passed",
    "review_failed",
    "testing_passed",
    "testing_failed"
  ]

  @typedoc "Run-log context returned by `prepare_attempt/3`"
  @type context :: %{
          project_root: String.t(),
          story_id: String.t(),
          issue_id: String.t() | nil,
          identifier: String.t() | nil,
          attempt: pos_integer(),
          runner_attempt: non_neg_integer() | nil,
          attempt_dir: String.t(),
          files: map(),
          retry_mode: String.t(),
          retry_provenance: map()
        }

  @doc "Resolves the project data root used for run-log persistence."
  @spec project_root(Config.t()) :: String.t()
  def project_root(%Config{} = config) do
    slug = project_slug(config) || inferred_project_slug(config)
    ServiceConfig.project_data_dir(slug)
  end

  defp project_slug(%Config{} = config) do
    config
    |> get_in([Access.key(:tracker, %{}), Access.key(:project_slug)])
    |> optional_string()
  end

  defp inferred_project_slug(%Config{} = config) do
    basis = inferred_project_slug_basis(config)

    hash =
      :sha256
      |> :crypto.hash(basis)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "adhoc-#{hash}"
  end

  defp inferred_project_slug_basis(%Config{} = config) do
    source =
      config
      |> get_in([Access.key(:workspace, %{}), Access.key(:source)])
      |> optional_string()

    tracker_path =
      config
      |> get_in([Access.key(:tracker, %{}), Access.key(:path)])
      |> optional_string()

    workspace_root =
      config
      |> get_in([Access.key(:workspace, %{}), Access.key(:root)])
      |> optional_string()

    cond do
      source -> "source:" <> expand_path(source)
      tracker_path -> "tracker:" <> expand_path(tracker_path)
      workspace_root -> "workspace:" <> expand_path(workspace_root)
      true -> "cwd:" <> File.cwd!()
    end
  end

  @doc "Creates a new per-attempt run-log directory and metadata file."
  @spec prepare_attempt(Config.t(), map(), non_neg_integer() | nil) ::
          {:ok, context()} | {:error, String.t()}
  def prepare_attempt(%Config{} = config, issue, runner_attempt) when is_map(issue) do
    prepare_attempt(config, issue, runner_attempt, [])
  end

  def prepare_attempt(_config, _issue, _runner_attempt) do
    {:error, "failed to initialize run logs: invalid inputs"}
  end

  @spec prepare_attempt(Config.t(), map(), non_neg_integer() | nil, keyword() | map()) ::
          {:ok, context()} | {:error, String.t()}
  def prepare_attempt(%Config{} = config, issue, runner_attempt, opts)
      when is_map(issue) do
    {retry_mode, retry_provenance, metadata_overrides} = parse_prepare_attempt_opts(opts)

    identifier = field(issue, :identifier)
    issue_id = field(issue, :id)

    story_id =
      identifier
      |> optional_string()
      |> Kernel.||(optional_string(issue_id))
      |> Kernel.||("unknown-story")

    project_root = project_root(config)
    story_dir = story_dir(project_root, story_id)

    with :ok <- File.mkdir_p(story_dir),
         attempt <- next_attempt_number(story_dir),
         attempt_dir <- attempt_dir(story_dir, attempt),
         :ok <- File.mkdir_p(attempt_dir) do
      files = build_attempt_files(story_dir, attempt_dir)

      metadata =
        initial_metadata(
          story_id,
          issue_id,
          identifier,
          attempt,
          runner_attempt,
          project_root,
          attempt_dir,
          files,
          retry_mode,
          retry_provenance,
          metadata_overrides
        )

      with :ok <- ensure_append_files(files),
           :ok <- write_json(files.metadata, metadata),
           :ok <-
             append_jsonl(files.attempts_index, %{
               "event" => "attempt_started",
               "story_id" => story_id,
               "attempt" => attempt,
               "runner_attempt" => runner_attempt,
               "timestamp" => now_iso8601(),
               "attempt_dir" => attempt_dir,
               "parent_attempt" => Map.get(metadata, "parent_attempt"),
               "retry_step" => Map.get(metadata, "retry_step"),
               "retry_mode" => retry_mode,
               "retry_provenance" => retry_provenance
             }) do
        {:ok,
         %{
           project_root: project_root,
           story_id: story_id,
           issue_id: optional_string(issue_id),
           identifier: optional_string(identifier),
           attempt: attempt,
           runner_attempt: runner_attempt,
           attempt_dir: attempt_dir,
           files: files,
           retry_mode: retry_mode,
           retry_provenance: retry_provenance
         }}
      end
    else
      {:error, reason} -> {:error, "failed to initialize run logs: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "failed to initialize run logs: #{Exception.message(error)}"}
  end

  def prepare_attempt(_config, _issue, _runner_attempt, _opts) do
    {:error, "failed to initialize run logs: invalid inputs"}
  end

  @doc "Appends one structured event and a human-readable line to run logs."
  @spec append_event(context(), map()) :: :ok | {:error, String.t()}
  def append_event(%{files: files} = context, event) when is_map(event) do
    normalized_event = normalize_event(event, context)
    category = category_for_event(Map.get(normalized_event, "type"))
    human_line = format_human_line(normalized_event, category)

    with :ok <- append_jsonl(files.events, normalized_event),
         :ok <- append_text(files.run, human_line),
         :ok <- append_text(category_path(files, category), human_line),
         :ok <- maybe_append_agent_log(files, normalized_event) do
      :ok
    else
      {:error, reason} -> {:error, "failed to append run log event: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "failed to append run log event: #{Exception.message(error)}"}
  end

  def append_event(_context, _event), do: :ok

  @doc "Completes a run attempt with final metadata from `%Result{}`."
  @spec complete_attempt(context(), Result.t()) :: :ok | {:error, String.t()}
  def complete_attempt(context, %Result{} = result) do
    base_update = %{
      status: result.status,
      ended_at: result.ended_at,
      turn_count: result.turn_count,
      workspace_path: result.workspace_path,
      error: result.error
    }

    update =
      case derive_last_successful_turn(result.events) do
        turn when is_integer(turn) and turn > 0 ->
          Map.put(base_update, :last_successful_turn, turn)

        _other ->
          base_update
      end

    complete_attempt(context, update)
  end

  @spec complete_attempt(context(), map()) :: :ok | {:error, String.t()}
  def complete_attempt(%{files: files} = context, attrs) when is_map(attrs) do
    update =
      attrs
      |> stringify_map()
      |> Map.put_new("ended_at", now_iso8601())
      |> Map.update("status", "finished", &normalize_status_value/1)

    metadata =
      files.metadata
      |> read_json_file()
      |> Map.merge(update)
      |> Map.merge(testing_report_metadata(files))

    with :ok <- write_json(files.metadata, metadata),
         :ok <-
           append_jsonl(files.attempts_index, %{
             "event" => "attempt_finished",
             "story_id" => context.story_id,
             "attempt" => context.attempt,
             "runner_attempt" => context.runner_attempt,
             "timestamp" => now_iso8601(),
             "status" => Map.get(metadata, "status"),
             "error" => Map.get(metadata, "error"),
             "retry_mode" => Map.get(metadata, "retry_mode", "full_rerun"),
             "retry_provenance" => Map.get(metadata, "retry_provenance", %{})
           }) do
      :ok
    else
      {:error, reason} -> {:error, "failed to complete run log metadata: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "failed to complete run log metadata: #{Exception.message(error)}"}
  end

  def complete_attempt(_context, _attrs), do: :ok

  @doc "Returns run-log metadata for tracker/UI surfaces."
  @spec tracker_metadata(context()) :: map()
  def tracker_metadata(%{attempt: attempt, attempt_dir: attempt_dir, files: files} = context) do
    retry_mode = normalize_retry_mode(Map.get(context, :retry_mode, "full_rerun"))
    retry_provenance = normalize_retry_provenance(Map.get(context, :retry_provenance, %{}))

    %{
      retry_mode: retry_mode,
      retry_provenance: retry_provenance,
      run_logs: %{
        attempt: attempt,
        dir: attempt_dir,
        retry_mode: retry_mode,
        retry_provenance: retry_provenance,
        files: %{
          run: files.run,
          worker: files.worker,
          reviewer: files.reviewer,
          tester: files.tester,
          checks: files.checks,
          runtime: files.runtime,
          events: files.events,
          metadata: files.metadata,
          agent: files.agent,
          agent_stdout: files.agent_stdout,
          reviewer_stdout: files.reviewer_stdout,
          tester_stdout: files.tester_stdout,
          review_json: files.review_json,
          review_cycles_dir: files.review_cycles_dir,
          testing_json: files.testing_json,
          testing_cycles_dir: files.testing_cycles_dir,
          testing_report: files.testing_report,
          testing_artifacts_dir: files.testing_artifacts_dir
        }
      }
    }
  end

  @doc """
  Extracts the immutable settings snapshot from attempt metadata.

  Returns `nil` for legacy attempts that predate settings snapshots.
  """
  @spec settings_snapshot(map()) :: map() | nil
  def settings_snapshot(%{metadata: metadata}) when is_map(metadata),
    do: settings_snapshot(metadata)

  def settings_snapshot(metadata) when is_map(metadata) do
    case Map.get(metadata, "settings_snapshot") do
      snapshot when is_map(snapshot) -> snapshot
      _other -> nil
    end
  end

  def settings_snapshot(_metadata), do: nil

  @doc "Lists available persisted attempts for a story."
  @spec list_attempts(String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_attempts(project_root, story_id)
      when is_binary(project_root) and is_binary(story_id) do
    story_dir = story_dir(project_root, story_id)

    case File.ls(story_dir) do
      {:ok, entries} ->
        attempts =
          entries
          |> Enum.map(&parse_attempt_entry/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()
          |> Enum.map(fn attempt ->
            dir = attempt_dir(story_dir, attempt)
            files = build_attempt_files(story_dir, dir)

            %{
              attempt: attempt,
              dir: dir,
              files: files,
              metadata: read_json_file(files.metadata)
            }
            |> then(fn attempt_entry ->
              Map.put(attempt_entry, :settings_snapshot, settings_snapshot(attempt_entry))
            end)
          end)

        {:ok, attempts}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "failed to list run logs at #{story_dir}: #{inspect(reason)}"}
    end
  end

  @doc "Resolves one persisted attempt (`:latest` or explicit attempt number)."
  @spec resolve_attempt(String.t(), String.t(), :latest | pos_integer()) ::
          {:ok, map()} | {:error, String.t()}
  def resolve_attempt(project_root, story_id, :latest) do
    with {:ok, attempts} <- list_attempts(project_root, story_id),
         false <- attempts == [] do
      {:ok, List.last(attempts)}
    else
      true -> {:error, "no run logs found for #{story_id}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_attempt(project_root, story_id, attempt)
      when is_integer(attempt) and attempt > 0 do
    with {:ok, attempts} <- list_attempts(project_root, story_id) do
      case Enum.find(attempts, &(&1.attempt == attempt)) do
        nil -> {:error, "attempt #{attempt} not found for #{story_id}"}
        found -> {:ok, found}
      end
    end
  end

  def resolve_attempt(_project_root, _story_id, attempt) do
    {:error, "invalid attempt selector: #{inspect(attempt)}"}
  end

  defp story_dir(project_root, story_id) do
    Path.join([project_root | @base_log_dir] ++ [sanitize_story_id(story_id)])
  end

  defp attempt_dir(story_dir, attempt) do
    Path.join(
      story_dir,
      "attempt-#{attempt |> Integer.to_string() |> String.pad_leading(4, "0")}"
    )
  end

  defp build_attempt_files(story_dir, attempt_dir) do
    %{
      attempts_index: Path.join(story_dir, "attempts.jsonl"),
      metadata: Path.join(attempt_dir, "metadata.json"),
      events: Path.join(attempt_dir, "events.jsonl"),
      run: Path.join(attempt_dir, "run.log"),
      worker: Path.join(attempt_dir, "worker.log"),
      reviewer: Path.join(attempt_dir, "reviewer.log"),
      tester: Path.join(attempt_dir, "tester.log"),
      checks: Path.join(attempt_dir, "checks.log"),
      runtime: Path.join(attempt_dir, "runtime.log"),
      agent: Path.join(attempt_dir, "agent.log"),
      agent_stdout: Path.join(attempt_dir, "agent_stdout.log"),
      reviewer_stdout: Path.join(attempt_dir, "reviewer_stdout.log"),
      tester_stdout: Path.join(attempt_dir, "tester_stdout.log"),
      review_json: Path.join(attempt_dir, "review.json"),
      review_cycles_dir: Path.join(attempt_dir, "review_cycles"),
      testing_json: Path.join(attempt_dir, "testing.json"),
      testing_cycles_dir: Path.join(attempt_dir, "testing_cycles"),
      testing_report: Path.join(attempt_dir, "testing_report.json"),
      testing_artifacts_dir: Path.join(attempt_dir, "testing_artifacts")
    }
  end

  defp ensure_append_files(files) do
    [
      files.attempts_index,
      files.events,
      files.run,
      files.worker,
      files.reviewer,
      files.tester,
      files.checks,
      files.runtime,
      files.agent,
      files.agent_stdout,
      files.reviewer_stdout,
      files.tester_stdout
    ]
    |> Enum.reduce_while(:ok, fn path, _acc ->
      case File.write(path, "", [:append]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp next_attempt_number(story_dir) do
    case File.ls(story_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&parse_attempt_entry/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> 0 end)
        |> Kernel.+(1)

      {:error, :enoent} ->
        1

      {:error, _reason} ->
        1
    end
  end

  defp parse_attempt_entry("attempt-" <> rest) do
    case Integer.parse(rest) do
      {attempt, ""} when attempt > 0 -> attempt
      _other -> nil
    end
  end

  defp parse_attempt_entry(_entry), do: nil

  defp initial_metadata(
         story_id,
         issue_id,
         identifier,
         attempt,
         runner_attempt,
         project_root,
         attempt_dir,
         files,
         retry_mode,
         retry_provenance,
         metadata_overrides
       ) do
    extra_metadata =
      metadata_overrides
      |> stringify_map()
      |> Map.drop([
        "story_id",
        "issue_id",
        "identifier",
        "attempt",
        "runner_attempt",
        "status",
        "started_at",
        "ended_at",
        "project_root",
        "attempt_dir",
        "files",
        "retry_mode",
        "retry_provenance"
      ])

    %{
      "story_id" => story_id,
      "issue_id" => optional_string(issue_id),
      "identifier" => optional_string(identifier),
      "attempt" => attempt,
      "runner_attempt" => runner_attempt,
      "retry_mode" => normalize_retry_mode(retry_mode),
      "retry_provenance" => normalize_retry_provenance(retry_provenance),
      "status" => "running",
      "started_at" => now_iso8601(),
      "ended_at" => nil,
      "project_root" => project_root,
      "attempt_dir" => attempt_dir,
      "files" => %{
        "run" => files.run,
        "worker" => files.worker,
        "reviewer" => files.reviewer,
        "tester" => files.tester,
        "checks" => files.checks,
        "runtime" => files.runtime,
        "events" => files.events,
        "agent" => files.agent,
        "agent_stdout" => files.agent_stdout,
        "reviewer_stdout" => files.reviewer_stdout,
        "tester_stdout" => files.tester_stdout,
        "review_json" => files.review_json,
        "review_cycles_dir" => files.review_cycles_dir,
        "testing_json" => files.testing_json,
        "testing_cycles_dir" => files.testing_cycles_dir,
        "testing_report" => files.testing_report,
        "testing_artifacts_dir" => files.testing_artifacts_dir
      }
    }
    |> Map.merge(extra_metadata)
  end

  defp testing_report_metadata(files) when is_map(files) do
    report =
      files
      |> testing_report_file_path()
      |> read_json_file()

    if map_size(report) > 0 do
      %{
        "testing_report" => report,
        "testing_artifacts" => Map.get(report, "artifacts", [])
      }
    else
      %{}
    end
  end

  defp testing_report_metadata(_files), do: %{}

  defp testing_report_file_path(files) when is_map(files) do
    explicit = Map.get(files, :testing_report) || Map.get(files, "testing_report")

    cond do
      is_binary(explicit) and File.exists?(explicit) ->
        explicit

      true ->
        fallback = Map.get(files, :testing_json) || Map.get(files, "testing_json")
        if is_binary(fallback) and File.exists?(fallback), do: fallback, else: nil
    end
  end

  defp testing_report_file_path(_files), do: nil

  defp parse_prepare_attempt_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      retry_mode = normalize_retry_mode(Keyword.get(opts, :retry_mode, :full_rerun))
      retry_provenance = normalize_retry_provenance(Keyword.get(opts, :retry_provenance, %{}))

      metadata_overrides =
        normalize_metadata_overrides(Keyword.get(opts, :metadata_overrides, %{}))

      {retry_mode, retry_provenance, metadata_overrides}
    else
      {"full_rerun", %{}, %{}}
    end
  end

  defp parse_prepare_attempt_opts(opts) when is_map(opts) do
    retry_mode =
      opts
      |> field(:retry_mode)
      |> normalize_retry_mode()

    retry_provenance =
      opts
      |> field(:retry_provenance)
      |> normalize_retry_provenance()

    metadata_overrides = normalize_metadata_overrides(opts)

    {retry_mode, retry_provenance, metadata_overrides}
  end

  defp parse_prepare_attempt_opts(_opts), do: {"full_rerun", %{}, %{}}

  defp normalize_metadata_overrides(overrides) when is_map(overrides), do: overrides
  defp normalize_metadata_overrides(_overrides), do: %{}

  defp normalize_event(event, context) do
    normalized = stringify_map(event)

    type =
      normalized
      |> Map.get("type")
      |> to_string()

    timestamp =
      normalized
      |> Map.get("timestamp")
      |> normalize_timestamp()

    normalized
    |> Map.put("type", type)
    |> Map.put("timestamp", timestamp)
    |> Map.put_new("issue_id", context.issue_id)
    |> Map.put_new("identifier", context.identifier)
    |> Map.put_new("story_id", context.story_id)
    |> Map.put_new("attempt", context.attempt)
  end

  defp normalize_timestamp(nil), do: now_iso8601()

  defp normalize_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _other -> value
    end
  end

  defp normalize_timestamp(value), do: to_string(value)

  defp category_for_event(type) do
    cond do
      type in @review_events -> :reviewer
      type in @testing_events -> :tester
      type in @checks_events -> :checks
      type in @runtime_events -> :runtime
      type in @worker_events -> :worker
      true -> :worker
    end
  end

  defp category_path(files, :worker), do: files.worker
  defp category_path(files, :reviewer), do: files.reviewer
  defp category_path(files, :tester), do: files.tester
  defp category_path(files, :checks), do: files.checks
  defp category_path(files, :runtime), do: files.runtime

  defp maybe_append_agent_log(files, event) do
    if Map.get(event, "type") in @agent_log_events do
      output = optional_string(Map.get(event, "output"))

      if output do
        turn = Map.get(event, "turn") || Map.get(event, "cycle") || "?"
        separator = "\n--- Turn #{turn} ---\n"
        append_text(files.agent, separator <> output <> "\n")
      else
        :ok
      end
    else
      :ok
    end
  end

  defp format_human_line(event, category) do
    timestamp = Map.get(event, "timestamp", now_iso8601())
    type = Map.get(event, "type", "unknown")

    detail_fields =
      event
      |> Map.drop([
        "type",
        "timestamp",
        "issue_id",
        "identifier",
        "story_id",
        "attempt",
        "args",
        "output",
        "raw_output",
        "output_preview",
        "prompt"
      ])
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{format_detail_value(value)}" end)

    header =
      "[#{timestamp}] [#{category}] #{type}" <>
        if(detail_fields == "", do: "", else: " #{detail_fields}")

    output_block = output_block(event, category)

    if output_block == "" do
      header <> "\n"
    else
      header <> "\n" <> output_block <> "\n"
    end
  end

  # Keep worker logs focused on orchestrator lifecycle signals. Agent transcript
  # output belongs in agent-specific logs, not worker.log / run.log worker entries.
  defp output_block(_event, :worker), do: ""

  defp output_block(event, _category) do
    output = optional_string(Map.get(event, "output"))
    raw_output = optional_string(Map.get(event, "raw_output"))
    output_preview = optional_string(Map.get(event, "output_preview"))

    [
      format_output_section("output", output),
      format_output_section("raw_output", raw_output),
      format_output_section("output_preview", output_preview)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_output_section(_label, nil), do: ""

  defp format_output_section(label, value) do
    "#{label}:\n#{value}"
  end

  defp format_detail_value(value) when is_binary(value) do
    if String.contains?(value, [" ", "\n", "\t"]) do
      inspect(value)
    else
      value
    end
  end

  defp format_detail_value(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      _other -> inspect(value)
    end
  end

  defp format_detail_value(value), do: to_string(value)

  defp append_jsonl(path, map) do
    line = Jason.encode_to_iodata!(map)
    File.write(path, [line, "\n"], [:append])
  end

  defp append_text(path, text) do
    File.write(path, text, [:append])
  end

  defp write_json(path, map) do
    payload = Jason.encode_to_iodata!(map, pretty: true)
    File.write(path, [payload, "\n"])
  end

  defp read_json_file(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      decoded
    else
      _other -> %{}
    end
  end

  defp read_json_file(_path), do: %{}

  defp normalize_status_value(value) when is_binary(value), do: value
  defp normalize_status_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_status_value(value), do: to_string(value)

  defp derive_last_successful_turn(events) when is_list(events) do
    events
    |> Enum.filter(fn event -> run_event_type(event) == "turn_succeeded" end)
    |> Enum.map(fn event -> positive_integer(field(event, :turn), nil) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp derive_last_successful_turn(_events), do: nil

  defp run_event_type(event) when is_map(event) do
    case field(event, :type) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp run_event_type(_event), do: nil

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _other -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp normalize_retry_mode(mode) when mode in [:full_rerun, :agent_continuation] do
    Atom.to_string(mode)
  end

  defp normalize_retry_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "agent_continuation" -> "agent_continuation"
      "agent-continuation" -> "agent_continuation"
      _other -> "full_rerun"
    end
  end

  defp normalize_retry_mode(_mode), do: "full_rerun"

  defp normalize_retry_provenance(value) when is_map(value), do: stringify_map(value)
  defp normalize_retry_provenance(_value), do: %{}

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_value(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_value(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp sanitize_story_id(story_id) do
    story_id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  defp expand_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> case do
      "~" -> System.user_home!()
      <<"~/", rest::binary>> -> Path.join(System.user_home!(), rest)
      other -> Path.expand(other)
    end
  end

  defp expand_path(_path), do: File.cwd!()

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_map, _key), do: nil

  defp optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp optional_string(_value), do: nil

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end

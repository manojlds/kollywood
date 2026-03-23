defmodule Mix.Tasks.Kollywood.Prd do
  @shortdoc "Manage local prd.json stories"

  @moduledoc """
  Manage the local PRD tracker file used for Kollywood dogfooding.

  ## Commands

      mix kollywood.prd list [--path PATH] [--all]

      mix kollywood.prd add --title "Story title" [--path PATH]
      mix kollywood.prd add --title "Story title" --description "..." --priority 2
      mix kollywood.prd add --title "Story title" --depends-on US-001,US-002
      mix kollywood.prd add --title "Story title" --acceptance "Criterion A" --acceptance "Criterion B"

      mix kollywood.prd set-status STORY_ID STATUS [--path PATH]

  ## Status values

  Supported statuses are `open`, `in_progress`, and `done`.
  """

  use Mix.Task

  @default_path "prd.json"
  @valid_statuses ["open", "in_progress", "done"]

  @impl Mix.Task
  def run(args) do
    case args do
      ["list" | rest] -> list_command(rest)
      ["add" | rest] -> add_command(rest)
      ["set-status", story_id, status | rest] -> set_status_command(story_id, status, rest)
      _other -> raise_usage_error()
    end
  end

  defp list_command(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [path: :string, all: :boolean],
        aliases: [p: :path, a: :all]
      )

    ensure_no_invalid_options!(invalid)
    ensure_no_positional_args!(positional)

    path = resolved_path(Keyword.get(opts, :path))

    with {:ok, prd} <- read_prd(path),
         {:ok, stories} <- user_stories(prd) do
      all? = Keyword.get(opts, :all, false)

      filtered_stories =
        stories
        |> Enum.map(&normalize_story/1)
        |> Enum.filter(fn story -> all? or story.status != "done" end)
        |> Enum.sort_by(fn story -> {story.priority, story.id || ""} end)

      print_stories(path, filtered_stories, all?)
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp add_command(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          path: :string,
          id: :string,
          title: :string,
          description: :string,
          priority: :integer,
          status: :string,
          depends_on: :string,
          acceptance: :keep,
          notes: :string
        ],
        aliases: [p: :path, t: :title, d: :description, s: :status]
      )

    ensure_no_invalid_options!(invalid)
    ensure_no_positional_args!(positional)

    title =
      case opts[:title] do
        nil -> Mix.raise("Missing required option: --title")
        value -> String.trim(value)
      end

    if title == "" do
      Mix.raise("--title cannot be empty")
    end

    path = resolved_path(Keyword.get(opts, :path))

    with {:ok, status} <- normalize_status(opts[:status] || "open"),
         {:ok, prd} <- read_or_initialize_prd(path),
         {:ok, stories} <- user_stories(prd) do
      story_id = String.trim(opts[:id] || next_story_id(stories))

      if story_id == "" do
        Mix.raise("Story ID cannot be empty")
      end

      if Enum.any?(stories, fn story -> story_id(story) == story_id end) do
        Mix.raise("Story ID already exists: #{story_id}")
      end

      depends_on = parse_depends_on(opts[:depends_on])
      acceptance = parse_acceptance(opts)

      priority =
        case opts[:priority] do
          value when is_integer(value) -> value
          _other -> next_priority(stories)
        end

      story = %{
        "id" => story_id,
        "title" => title,
        "description" => optional_string(opts[:description]) || "",
        "acceptanceCriteria" => acceptance,
        "priority" => priority,
        "status" => status,
        "dependsOn" => depends_on,
        "notes" => optional_string(opts[:notes]) || "",
        "passes" => status == "done"
      }

      updated_prd = Map.put(prd, "userStories", stories ++ [story])

      case write_prd(path, updated_prd) do
        :ok ->
          Mix.shell().info(
            "Added story #{story_id} (status=#{status}, priority=#{priority}) to #{path}"
          )

        {:error, reason} ->
          Mix.raise(reason)
      end
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp set_status_command(story_id, status_arg, args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [path: :string],
        aliases: [p: :path]
      )

    ensure_no_invalid_options!(invalid)
    ensure_no_positional_args!(positional)

    path = resolved_path(Keyword.get(opts, :path))

    with {:ok, status} <- normalize_status(status_arg),
         {:ok, prd} <- read_prd(path),
         {:ok, stories} <- user_stories(prd),
         {:ok, updated_stories} <- set_story_status(stories, story_id, status) do
      updated_prd = Map.put(prd, "userStories", updated_stories)

      case write_prd(path, updated_prd) do
        :ok -> Mix.shell().info("Updated #{story_id} to status=#{status} in #{path}")
        {:error, reason} -> Mix.raise(reason)
      end
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp set_story_status(stories, target_story_id, status) do
    {updated_stories, found?} =
      Enum.map_reduce(stories, false, fn story, found ->
        if story_id(story) == target_story_id do
          updated_story =
            story
            |> put_story_field(:status, status)
            |> put_story_field(:passes, status == "done")

          {updated_story, true}
        else
          {story, found}
        end
      end)

    if found? do
      {:ok, updated_stories}
    else
      {:error, "Story not found: #{target_story_id}"}
    end
  end

  defp print_stories(path, stories, all?) do
    mode_label = if all?, do: "all", else: "active"

    Mix.shell().info("Stories (#{mode_label}) from #{path}")

    if stories == [] do
      Mix.shell().info("- none")
    else
      Enum.each(stories, fn story ->
        depends_on = if story.depends_on == [], do: "-", else: Enum.join(story.depends_on, ",")

        Mix.shell().info(
          "- #{story.id} | #{story.status} | p#{story.priority} | depends=#{depends_on} | #{story.title}"
        )
      end)
    end
  end

  defp parse_acceptance(opts) do
    opts
    |> Keyword.get_values(:acceptance)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_depends_on(nil), do: []

  defp parse_depends_on(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_depends_on(_value), do: []

  defp normalize_story(story) do
    %{
      id: story_id(story),
      title: optional_string(field(story, :title)) || "Untitled story",
      status: story_status(story),
      priority: story_priority(story),
      depends_on: string_list(field(story, :dependsOn))
    }
  end

  defp story_status(story) do
    case optional_string(field(story, :status)) do
      nil ->
        if(field(story, :passes) == true, do: "done", else: "open")

      value ->
        value
        |> normalize_status_string()
        |> case do
          "" -> "open"
          normalized -> normalized
        end
    end
  end

  defp story_priority(story) do
    case field(story, :priority) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _other -> 99
        end

      _other ->
        99
    end
  end

  defp normalize_status(status) when is_binary(status) do
    normalized = normalize_status_string(status)

    if normalized in @valid_statuses do
      {:ok, normalized}
    else
      {:error,
       "Invalid status #{inspect(status)}. Expected one of: #{Enum.join(@valid_statuses, ", ")}"}
    end
  end

  defp normalize_status(_status) do
    {:error, "Status must be a string"}
  end

  defp normalize_status_string(status) do
    status
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "_")
    |> String.replace("-", "_")
  end

  defp next_story_id(stories) do
    next_number =
      stories
      |> Enum.map(&story_id/1)
      |> Enum.map(&extract_id_number/1)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    "US-" <> String.pad_leading(Integer.to_string(next_number), 3, "0")
  end

  defp extract_id_number(nil), do: 0

  defp extract_id_number(story_id) when is_binary(story_id) do
    with [prefix, number_part] <- String.split(story_id, "-", parts: 2),
         true <- String.upcase(prefix) == "US",
         {number, ""} <- Integer.parse(number_part) do
      number
    else
      _ -> 0
    end
  end

  defp next_priority(stories) do
    stories
    |> Enum.map(&story_priority/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp read_or_initialize_prd(path) do
    case read_prd(path) do
      {:ok, prd} ->
        {:ok, prd}

      {:error, reason} ->
        if String.contains?(reason, "not found") do
          {:ok,
           %{
             "project" => "kollywood",
             "branchName" => current_branch(),
             "description" => "Local PRD tracker stories for Kollywood dogfooding.",
             "userStories" => []
           }}
        else
          {:error, reason}
        end
    end
  end

  defp current_branch do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
      {branch, 0} ->
        branch
        |> String.trim()
        |> case do
          "" -> "main"
          value -> value
        end

      _other ->
        "main"
    end
  rescue
    _ -> "main"
  end

  defp read_prd(path) do
    with {:ok, content} <- read_prd_content(path),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, "PRD file must contain a JSON object: #{path}"}
      _other -> {:error, "Failed to parse PRD JSON: #{path}"}
    end
  end

  defp read_prd_content(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "PRD file not found: #{path}"}
      {:error, reason} -> {:error, "Failed to read PRD file #{path}: #{inspect(reason)}"}
    end
  end

  defp user_stories(prd) do
    case Map.get(prd, "userStories") do
      stories when is_list(stories) -> {:ok, stories}
      _other -> {:error, "PRD file is missing a valid userStories array"}
    end
  end

  defp write_prd(path, prd) do
    directory = Path.dirname(path)
    temp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    encoded = Jason.encode_to_iodata!(prd, pretty: true)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temp_path, [encoded, "\n"]),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, "Failed to write PRD file #{path}: #{inspect(reason)}"}
    end
  end

  defp resolved_path(nil), do: Path.expand(@default_path)
  defp resolved_path(path), do: Path.expand(path)

  defp story_id(story) do
    story
    |> field(:id)
    |> optional_string()
  end

  defp put_story_field(story, key, value) when is_map(story) do
    atom_key = key
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(story, string_key) -> Map.put(story, string_key, value)
      Map.has_key?(story, atom_key) -> Map.put(story, atom_key, value)
      true -> Map.put(story, string_key, value)
    end
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

  defp ensure_no_invalid_options!([]), do: :ok

  defp ensure_no_invalid_options!(invalid) do
    values =
      invalid
      |> Enum.map(fn {key, value} ->
        if is_nil(value) do
          "--#{key}"
        else
          "--#{key}=#{value}"
        end
      end)

    Mix.raise("Unknown options: #{Enum.join(values, ", ")}")
  end

  defp ensure_no_positional_args!([]), do: :ok

  defp ensure_no_positional_args!(args) do
    Mix.raise("Unexpected positional arguments: #{Enum.join(args, " ")}")
  end

  defp raise_usage_error do
    Mix.raise("""
    Usage:
      mix kollywood.prd list [--path PATH] [--all]
      mix kollywood.prd add --title \"Story title\" [--path PATH] [--id US-001] [--description TEXT]\
        [--priority N] [--status open|in_progress|done] [--depends-on US-001,US-002]\
        [--acceptance TEXT] [--notes TEXT]
      mix kollywood.prd set-status STORY_ID STATUS [--path PATH]
    """)
  end
end

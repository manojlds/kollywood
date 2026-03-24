defmodule Kollywood.AgentRunner.ResumeContext do
  @moduledoc """
  Tracks workspace state for resume capability after timeouts.
  """

  alias __MODULE__

  defstruct [
    :turn_start_snapshot,
    files_created: [],
    files_modified: [],
    last_output: nil
  ]

  @type file_snapshot :: %{
          path: String.t(),
          mtime: DateTime.t() | nil,
          size: integer()
        }

  @type snapshot :: %{
          files: [file_snapshot()],
          timestamp: DateTime.t()
        }

  @type t :: %ResumeContext{
          turn_start_snapshot: snapshot() | nil,
          files_created: [String.t()],
          files_modified: [String.t()],
          last_output: String.t() | nil
        }

  @doc """
  Takes a snapshot of the workspace before a turn starts.
  """
  @spec take_snapshot(String.t() | nil) :: snapshot()
  def take_snapshot(nil), do: %{files: [], timestamp: DateTime.utc_now()}

  def take_snapshot(workspace_path) do
    files =
      workspace_path
      |> list_files()
      |> Enum.map(&file_info(&1, workspace_path))

    %{
      files: files,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Compares current state with snapshot to detect changes.
  """
  @spec detect_changes(snapshot(), String.t() | nil) :: %{
          created: [String.t()],
          modified: [String.t()]
        }
  def detect_changes(_snapshot, nil), do: %{created: [], modified: []}

  def detect_changes(snapshot, workspace_path) do
    current_files = list_files(workspace_path)
    snapshot_paths = Enum.map(snapshot.files, & &1.path)

    created =
      current_files
      |> Enum.reject(fn path -> path in snapshot_paths end)
      |> Enum.sort()

    modified =
      current_files
      |> Enum.filter(fn path -> path in snapshot_paths end)
      |> Enum.filter(fn path -> file_modified?(path, workspace_path, snapshot) end)
      |> Enum.sort()

    %{created: created, modified: modified}
  end

  @doc """
  Builds a resume prompt based on detected changes.
  """
  @spec build_resume_prompt(%{created: [String.t()], modified: [String.t()]}, String.t() | nil) ::
          String.t()
  def build_resume_prompt(%{created: [], modified: []}, _last_output) do
    """
    Your previous attempt timed out. No files were created or modified.
    Start fresh and implement the requirements.
    """
  end

  def build_resume_prompt(%{created: created, modified: modified}, last_output) do
    created_section =
      if created != [] do
        files = Enum.join(created, "\n- ")
        "Files created:\n- #{files}\n\n"
      else
        ""
      end

    modified_section =
      if modified != [] do
        files = Enum.join(modified, "\n- ")
        "Files modified:\n- #{files}\n\n"
      else
        ""
      end

    output_section =
      if last_output && String.trim(last_output) != "" do
        trimmed = String.slice(last_output, 0, 500)
        "Last output before timeout:\n```\n#{trimmed}\n```\n\n"
      else
        ""
      end

    """
    Your previous attempt timed out after making progress. Continue from where you left off:

    #{created_section}#{modified_section}#{output_section}
    Resume the implementation by completing the remaining work. Don't start over - continue from this checkpoint.
    """
  end

  # Private functions

  defp list_files(workspace_path) do
    workspace_path
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, workspace_path))
  end

  defp file_info(relative_path, workspace_path) do
    full_path = Path.join(workspace_path, relative_path)
    stat = File.stat!(full_path, time: :posix)

    %{
      path: relative_path,
      mtime: DateTime.from_unix!(stat.mtime, :second),
      size: stat.size
    }
  rescue
    _ -> %{path: relative_path, mtime: nil, size: 0}
  end

  defp file_modified?(path, workspace_path, snapshot) do
    snapshot_file = Enum.find(snapshot.files, &(&1.path == path))

    if is_nil(snapshot_file) do
      false
    else
      full_path = Path.join(workspace_path, path)

      case File.stat(full_path, time: :posix) do
        {:ok, current_stat} ->
          current_mtime = DateTime.from_unix!(current_stat.mtime, :second)

          DateTime.compare(current_mtime, snapshot_file.mtime) == :gt or
            current_stat.size != snapshot_file.size

        {:error, _} ->
          false
      end
    end
  end
end

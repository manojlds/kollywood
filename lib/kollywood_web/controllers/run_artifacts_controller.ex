defmodule KollywoodWeb.RunArtifactsController do
  use KollywoodWeb, :controller

  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.ServiceConfig

  def show(
        conn,
        %{
          "project_slug" => project_slug,
          "story_id" => story_id,
          "attempt" => attempt_raw,
          "filename" => filename
        }
      ) do
    with {:ok, attempt} <- parse_attempt(attempt_raw),
         {:ok, artifact_path} <- resolve_artifact_path(project_slug, story_id, attempt, filename),
         true <- File.exists?(artifact_path),
         true <- File.regular?(artifact_path) do
      content_type = MIME.from_path(artifact_path)

      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header(
        "content-disposition",
        ~s(inline; filename="#{Path.basename(artifact_path)}")
      )
      |> send_file(200, artifact_path)
    else
      _other ->
        send_resp(conn, :not_found, "not found")
    end
  end

  defp parse_attempt(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {attempt, ""} when attempt > 0 -> {:ok, attempt}
      _other -> {:error, :invalid_attempt}
    end
  end

  defp parse_attempt(_value), do: {:error, :invalid_attempt}

  defp resolve_artifact_path(project_slug, story_id, attempt, filename)
       when is_binary(project_slug) and is_binary(story_id) and is_integer(attempt) and
              is_binary(filename) do
    sanitized = Path.basename(filename)
    project_root = ServiceConfig.project_data_dir(project_slug)

    with {:ok, %{files: files}} <- RunLogs.resolve_attempt(project_root, story_id, attempt),
         artifacts_dir when is_binary(artifacts_dir) <- Map.get(files, :testing_artifacts_dir),
         true <- sanitized != "" do
      expanded_dir = Path.expand(artifacts_dir)
      candidate = Path.expand(Path.join(expanded_dir, sanitized))

      if candidate == expanded_dir or String.starts_with?(candidate, expanded_dir <> "/") do
        {:ok, candidate}
      else
        {:error, :invalid_path}
      end
    else
      _other -> {:error, :invalid_path}
    end
  end

  defp resolve_artifact_path(_project_slug, _story_id, _attempt, _filename),
    do: {:error, :invalid_path}
end

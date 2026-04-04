defmodule Kollywood.RuntimeSessions do
  @moduledoc """
  Persistent runtime session registry.

  Stores active preview/testing runtime state so sessions can survive process
  restarts and be reused by preview controls without forcing a cold start.
  """

  import Ecto.Query
  require Logger

  alias Kollywood.Repo

  @valid_statuses ["running", "starting", "failed", "stopped"]
  @valid_session_types ["testing", "preview"]
  @valid_runtime_kinds ["host", "docker"]

  defmodule Entry do
    use Ecto.Schema
    import Ecto.Changeset

    @valid_statuses ["running", "starting", "failed", "stopped"]
    @valid_session_types ["testing", "preview"]
    @valid_runtime_kinds ["host", "docker"]

    @primary_key false
    schema "runtime_sessions" do
      field(:project_slug, :string)
      field(:story_id, :string)
      field(:status, :string, default: "running")
      field(:session_type, :string, default: "testing")
      field(:runtime_kind, :string)
      field(:runtime_state_term, :binary)
      field(:preview_url, :string)
      field(:resolved_ports_json, :string)
      field(:workspace_path, :string)
      field(:started_at, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
      field(:last_error, :string)

      timestamps(type: :utc_datetime_usec)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(entry, attrs) do
      entry
      |> cast(attrs, [
        :project_slug,
        :story_id,
        :status,
        :session_type,
        :runtime_kind,
        :runtime_state_term,
        :preview_url,
        :resolved_ports_json,
        :workspace_path,
        :started_at,
        :expires_at,
        :last_error
      ])
      |> validate_required([:project_slug, :story_id, :status, :session_type, :runtime_kind])
      |> validate_inclusion(:status, @valid_statuses)
      |> validate_inclusion(:session_type, @valid_session_types)
      |> validate_inclusion(:runtime_kind, @valid_runtime_kinds)
      |> validate_runtime_state_for_status()
    end

    defp validate_runtime_state_for_status(changeset) do
      if get_field(changeset, :status) in ["running", "starting"] and
           is_nil(get_field(changeset, :runtime_state_term)) do
        add_error(
          changeset,
          :runtime_state_term,
          "runtime_state_term is required for active sessions"
        )
      else
        changeset
      end
    end
  end

  @spec upsert(String.t(), String.t(), map(), keyword()) :: :ok | {:error, String.t()}
  def upsert(project_slug, story_id, runtime_state, opts \\ [])

  def upsert(project_slug, story_id, runtime_state, opts)
      when is_binary(project_slug) and is_binary(story_id) and is_map(runtime_state) do
    status = encode_status(Keyword.get(opts, :status, :running))
    session_type = encode_session_type(Keyword.get(opts, :session_type, :testing))

    attrs = %{
      project_slug: project_slug,
      story_id: story_id,
      status: status,
      session_type: session_type,
      runtime_kind: encode_runtime_kind(Map.get(runtime_state, :kind)),
      runtime_state_term: :erlang.term_to_binary(runtime_state, [:compressed]),
      preview_url: Keyword.get(opts, :preview_url) || build_preview_url(runtime_state),
      resolved_ports_json: encode_json(Map.get(runtime_state, :resolved_ports, %{})),
      workspace_path: Map.get(runtime_state, :workspace_path),
      started_at: Keyword.get(opts, :started_at),
      expires_at: Keyword.get(opts, :expires_at),
      last_error: Keyword.get(opts, :last_error)
    }

    changeset = Entry.changeset(%Entry{}, attrs)

    case Repo.insert(changeset,
           on_conflict: {
             :replace,
             [
               :status,
               :session_type,
               :runtime_kind,
               :runtime_state_term,
               :preview_url,
               :resolved_ports_json,
               :workspace_path,
               :started_at,
               :expires_at,
               :last_error,
               :updated_at
             ]
           },
           conflict_target: [:project_slug, :story_id]
         ) do
      {:ok, _entry} -> :ok
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def upsert(_project_slug, _story_id, _runtime_state, _opts),
    do: {:error, "invalid runtime session"}

  @spec delete(String.t(), String.t()) :: :ok | {:error, String.t()}
  def delete(project_slug, story_id) when is_binary(project_slug) and is_binary(story_id) do
    _ =
      Repo.delete_all(
        from(entry in Entry,
          where: entry.project_slug == ^project_slug and entry.story_id == ^story_id
        )
      )

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  def delete(_project_slug, _story_id), do: {:error, "project_slug and story_id must be strings"}

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()} | nil
  def get(project_slug, story_id) when is_binary(project_slug) and is_binary(story_id) do
    case Repo.get_by(Entry, project_slug: project_slug, story_id: story_id) do
      nil ->
        nil

      entry ->
        decode_entry(entry)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def get(_project_slug, _story_id), do: {:error, "project_slug and story_id must be strings"}

  @spec list(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def list(opts \\ []) do
    query =
      from(entry in Entry,
        order_by: [asc: entry.project_slug, asc: entry.story_id]
      )

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(entry in query, where: entry.status == ^encode_status(status))
      end

    query =
      case Keyword.get(opts, :session_type) do
        nil -> query
        type -> from(entry in query, where: entry.session_type == ^encode_session_type(type))
      end

    entries = Repo.all(query)

    sessions =
      Enum.reduce(entries, [], fn entry, acc ->
        case decode_entry(entry) do
          {:ok, decoded} ->
            [decoded | acc]

          {:error, reason} ->
            Logger.warning(
              "Discarding invalid runtime session #{entry.project_slug}/#{entry.story_id}: #{reason}"
            )

            _ = delete(entry.project_slug, entry.story_id)
            acc
        end
      end)
      |> Enum.reverse()

    {:ok, sessions}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @spec clear() :: :ok | {:error, String.t()}
  def clear do
    _ = Repo.delete_all(Entry)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  @spec prune_expired(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def prune_expired(now \\ DateTime.utc_now()) do
    {count, _} =
      from(entry in Entry,
        where: not is_nil(entry.expires_at) and entry.expires_at < ^now
      )
      |> Repo.delete_all()

    {:ok, count}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp decode_entry(%Entry{} = entry) do
    with {:ok, runtime_state} <- decode_term(entry.runtime_state_term),
         {:ok, resolved_ports} <- decode_json(entry.resolved_ports_json) do
      {:ok,
       %{
         project_slug: entry.project_slug,
         story_id: entry.story_id,
         status: decode_status(entry.status),
         session_type: decode_session_type(entry.session_type),
         runtime_kind: decode_runtime_kind(entry.runtime_kind),
         runtime_state: runtime_state,
         preview_url: entry.preview_url,
         resolved_ports: resolved_ports,
         workspace_path: entry.workspace_path,
         started_at: entry.started_at,
         expires_at: entry.expires_at,
         last_error: entry.last_error,
         inserted_at: entry.inserted_at,
         updated_at: entry.updated_at
       }}
    end
  end

  defp decode_term(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp decode_term(_value), do: {:error, "runtime state is invalid"}

  defp encode_json(nil), do: nil

  defp encode_json(map) when is_map(map) do
    case Jason.encode(map) do
      {:ok, json} -> json
      {:error, _} -> nil
    end
  end

  defp encode_json(_value), do: nil

  defp decode_json(nil), do: {:ok, %{}}

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:ok, %{}}
      {:error, reason} -> {:error, "invalid resolved_ports json: #{inspect(reason)}"}
    end
  end

  defp decode_json(_value), do: {:ok, %{}}

  defp build_preview_url(runtime_state) when is_map(runtime_state) do
    ports = Map.get(runtime_state, :resolved_ports, %{})

    case Map.get(ports, "PORT") do
      port when is_integer(port) and port > 0 -> "http://localhost:#{port}"
      _other -> nil
    end
  end

  defp build_preview_url(_runtime_state), do: nil

  defp encode_status(status) when is_atom(status), do: encode_status(Atom.to_string(status))
  defp encode_status(status) when status in @valid_statuses, do: status
  defp encode_status(_status), do: "running"

  defp decode_status("starting"), do: :starting
  defp decode_status("failed"), do: :failed
  defp decode_status("stopped"), do: :stopped
  defp decode_status(_status), do: :running

  defp encode_session_type(type) when is_atom(type), do: encode_session_type(Atom.to_string(type))
  defp encode_session_type(type) when type in @valid_session_types, do: type
  defp encode_session_type(_type), do: "testing"

  defp decode_session_type("preview"), do: :preview
  defp decode_session_type(_type), do: :testing

  defp encode_runtime_kind(kind) when is_atom(kind), do: encode_runtime_kind(Atom.to_string(kind))
  defp encode_runtime_kind(kind) when kind in @valid_runtime_kinds, do: kind
  defp encode_runtime_kind(_kind), do: "host"

  defp decode_runtime_kind("docker"), do: :docker
  defp decode_runtime_kind(_kind), do: :host

  defp changeset_error(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} ->
        message
      end)

    inspect(errors)
  end
end

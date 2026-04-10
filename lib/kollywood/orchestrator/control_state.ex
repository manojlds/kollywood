defmodule Kollywood.Orchestrator.ControlState do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Kollywood.Repo
  alias Kollywood.ServiceConfig

  @type maintenance_mode :: :normal | :drain

  @maintenance_mode_file "maintenance_mode.json"
  @status_file "status.json"
  @maintenance_mode_key "maintenance_mode"
  @status_key "status"

  @primary_key false
  schema "orchestrator_control_states" do
    field(:key, :string, primary_key: true)
    field(:value_json, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec maintenance_mode_path() :: String.t()
  def maintenance_mode_path do
    Path.join(control_dir(), @maintenance_mode_file)
  end

  @spec status_path() :: String.t()
  def status_path do
    Path.join(control_dir(), @status_file)
  end

  @spec load_maintenance_mode(maintenance_mode()) :: maintenance_mode()
  def load_maintenance_mode(default \\ :normal) do
    case read_maintenance_mode() do
      {:ok, mode} -> mode
      {:error, _reason} -> normalize_mode(default)
    end
  end

  @spec read_maintenance_mode() :: {:ok, maintenance_mode()} | {:error, String.t()}
  def read_maintenance_mode do
    if db_backend?() do
      case read_db_payload(@maintenance_mode_key) do
        {:ok, nil} -> {:ok, :normal}
        {:ok, payload} -> parse_mode(Map.get(payload, "mode"))
        {:error, reason} -> read_maintenance_mode_file(reason)
      end
    else
      read_maintenance_mode_file()
    end
  end

  @spec write_maintenance_mode(maintenance_mode() | String.t(), keyword()) ::
          :ok | {:error, String.t()}
  def write_maintenance_mode(mode, opts \\ []) do
    mode = normalize_mode(mode)

    payload = %{
      "mode" => Atom.to_string(mode),
      "updated_at" => now_iso8601(),
      "source" => to_optional_string(Keyword.get(opts, :source)),
      "reason" => to_optional_string(Keyword.get(opts, :reason))
    }

    payload =
      payload
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    write_payload(@maintenance_mode_key, maintenance_mode_path(), payload)
  end

  @spec write_status(map()) :: :ok | {:error, String.t()}
  def write_status(status) when is_map(status) do
    payload =
      status
      |> stringify_map()
      |> Map.put("updated_at", now_iso8601())

    write_payload(@status_key, status_path(), payload)
  end

  def write_status(_status), do: {:error, "status must be a map"}

  @spec read_status() :: {:ok, map()} | {:error, String.t()}
  def read_status do
    if db_backend?() do
      case read_db_payload(@status_key) do
        {:ok, payload} when is_map(payload) -> {:ok, payload}
        {:ok, nil} -> read_status_file()
        {:error, reason} -> read_status_file(reason)
      end
    else
      read_status_file()
    end
  end

  @spec parse_mode(term()) :: {:ok, maintenance_mode()} | {:error, String.t()}
  def parse_mode(mode) do
    case normalize_mode(mode) do
      :normal -> {:ok, :normal}
      :drain -> {:ok, :drain}
      :invalid -> {:error, "invalid maintenance mode: #{inspect(mode)}"}
    end
  end

  defp write_json(path, payload) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         data <- Jason.encode_to_iodata!(payload, pretty: true),
         :ok <- File.write(path, [data, "\n"]) do
      :ok
    else
      {:error, reason} ->
        {:error, "failed to write #{path}: #{inspect(reason)}"}
    end
  end

  defp write_payload(key, path, payload) do
    with :ok <- maybe_write_db_payload(key, payload),
         :ok <- write_json(path, payload) do
      :ok
    end
  end

  defp maybe_write_db_payload(key, payload) do
    if db_backend?() do
      write_db_payload(key, payload)
    else
      :ok
    end
  end

  defp write_db_payload(key, payload) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %__MODULE__{}
    |> changeset(%{
      key: key,
      value_json: Jason.encode!(payload),
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert(
      on_conflict: {:replace, [:value_json, :updated_at]},
      conflict_target: [:key]
    )
    |> case do
      {:ok, _entry} -> :ok
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp read_db_payload(key) do
    case Repo.get(__MODULE__, key) do
      nil ->
        {:ok, nil}

      %__MODULE__{value_json: nil} ->
        {:ok, nil}

      %__MODULE__{value_json: value_json} ->
        case Jason.decode(value_json) do
          {:ok, payload} when is_map(payload) ->
            {:ok, payload}

          {:ok, _other} ->
            {:error, "invalid control state payload for #{key}"}

          {:error, reason} ->
            {:error, "failed to decode control state #{key}: #{inspect(reason)}"}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp read_maintenance_mode_file(_reason \\ nil) do
    path = maintenance_mode_path()

    case File.read(path) do
      {:ok, content} ->
        with {:ok, decoded} <- Jason.decode(content),
             {:ok, mode} <- parse_mode(Map.get(decoded, "mode")) do
          {:ok, mode}
        else
          {:error, reason} -> {:error, "failed to parse #{path}: #{reason}"}
        end

      {:error, :enoent} ->
        {:ok, :normal}

      {:error, reason} ->
        {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end

  defp read_status_file(_reason \\ nil) do
    path = status_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:ok, _other} -> {:error, "failed to parse #{path}: expected JSON object"}
          {:error, reason} -> {:error, "failed to parse #{path}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end

  defp control_dir do
    Path.join(ServiceConfig.kollywood_home(), "orchestrator")
  end

  defp db_backend? do
    case System.get_env("KOLLYWOOD_CONTROL_STATE_BACKEND") do
      value when value in ["db", "DB"] ->
        true

      value when value in ["file", "FILE"] ->
        false

      _other ->
        case Application.get_env(:kollywood, :orchestrator_control_state_backend, :auto) do
          :db ->
            true

          :file ->
            false

          _auto ->
            Application.get_env(:kollywood, :ecto_adapter, Ecto.Adapters.SQLite3) ==
              Ecto.Adapters.Postgres
        end
    end
  end

  defp changeset(entry, attrs) do
    entry
    |> cast(attrs, [:key, :value_json, :inserted_at, :updated_at])
    |> validate_required([:key, :value_json])
  end

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> inspect()
  end

  defp normalize_mode(:normal), do: :normal
  defp normalize_mode(:drain), do: :drain
  defp normalize_mode("normal"), do: :normal
  defp normalize_mode("drain"), do: :drain

  defp normalize_mode(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> normalize_mode()
  end

  defp normalize_mode(_value), do: :invalid

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_value(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_value(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp to_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp to_optional_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> to_optional_string()

  defp to_optional_string(_value), do: nil

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end

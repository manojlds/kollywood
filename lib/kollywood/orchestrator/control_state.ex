defmodule Kollywood.Orchestrator.ControlState do
  @moduledoc false

  alias Kollywood.ServiceConfig

  @type maintenance_mode :: :normal | :drain

  @maintenance_mode_file "maintenance_mode.json"
  @status_file "status.json"

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

    write_json(maintenance_mode_path(), payload)
  end

  @spec write_status(map()) :: :ok | {:error, String.t()}
  def write_status(status) when is_map(status) do
    payload =
      status
      |> stringify_map()
      |> Map.put("updated_at", now_iso8601())

    write_json(status_path(), payload)
  end

  def write_status(_status), do: {:error, "status must be a map"}

  @spec read_status() :: {:ok, map()} | {:error, String.t()}
  def read_status do
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

  defp control_dir do
    Path.join(ServiceConfig.kollywood_home(), "orchestrator")
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

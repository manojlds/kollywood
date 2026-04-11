defmodule Kollywood.Worker.ControlPlaneClient do
  @moduledoc false

  @default_timeout_ms 15_000

  defstruct [:base_url, :token, timeout_ms: @default_timeout_ms]

  @type t :: %__MODULE__{
          base_url: String.t() | nil,
          token: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      base_url:
        opts
        |> Keyword.get(:base_url, Application.get_env(:kollywood, :control_plane_url))
        |> normalize_base_url(),
      token: Keyword.get(opts, :token, Application.get_env(:kollywood, :internal_api_token)),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    }
  end

  @spec lease_next(t(), String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def lease_next(%__MODULE__{} = client, worker_id, limit)
      when is_binary(worker_id) and is_integer(limit) and limit > 0 do
    with {:ok, body} <-
           post(client, "/api/internal/workers/lease-next", %{worker_id: worker_id, limit: limit}) do
      entries = get_in(body, ["data", "entries"]) || []
      {:ok, entries}
    end
  end

  @spec start_run(t(), integer(), String.t(), String.t()) ::
          :ok | :cancel_requested | {:error, term()}
  def start_run(%__MODULE__{} = client, entry_id, worker_id, lease_token)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) do
    case post(client, "/api/internal/runs/#{entry_id}/start", %{
           worker_id: worker_id,
           lease_token: lease_token
         }) do
      {:ok, body} -> response_status(body)
      {:error, reason} -> {:error, reason}
    end
  end

  def start_run(_client, _entry_id, _worker_id, _lease_token), do: {:error, :invalid_arguments}

  @spec heartbeat_run(t(), integer(), String.t(), String.t()) ::
          :ok | :cancel_requested | {:error, term()}
  def heartbeat_run(%__MODULE__{} = client, entry_id, worker_id, lease_token)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) do
    case post(client, "/api/internal/runs/#{entry_id}/heartbeat", %{
           worker_id: worker_id,
           lease_token: lease_token
         }) do
      {:ok, body} -> response_status(body)
      {:error, reason} -> {:error, reason}
    end
  end

  def heartbeat_run(_client, _entry_id, _worker_id, _lease_token),
    do: {:error, :invalid_arguments}

  @spec report_event(t(), integer(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def report_event(%__MODULE__{} = client, entry_id, worker_id, lease_token, issue_id, event)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) and
             is_binary(issue_id) and is_map(event) do
    case post(client, "/api/internal/runs/#{entry_id}/events", %{
           worker_id: worker_id,
           lease_token: lease_token,
           issue_id: issue_id,
           event: event
         }) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def report_event(_client, _entry_id, _worker_id, _lease_token, _issue_id, _event),
    do: {:error, :invalid_arguments}

  @spec complete_run(t(), integer(), String.t(), String.t(), map()) ::
          :ok | :cancel_requested | {:error, term()}
  def complete_run(%__MODULE__{} = client, entry_id, worker_id, lease_token, result_payload)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) and
             is_map(result_payload) do
    case post(client, "/api/internal/runs/#{entry_id}/complete", %{
           worker_id: worker_id,
           lease_token: lease_token,
           result_payload: result_payload
         }) do
      {:ok, body} -> response_status(body)
      {:error, reason} -> {:error, reason}
    end
  end

  def complete_run(_client, _entry_id, _worker_id, _lease_token, _result_payload),
    do: {:error, :invalid_arguments}

  @spec fail_run(t(), integer(), String.t(), String.t(), String.t()) ::
          :ok | :cancel_requested | {:error, term()}
  def fail_run(%__MODULE__{} = client, entry_id, worker_id, lease_token, error_message)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) and
             is_binary(error_message) do
    case post(client, "/api/internal/runs/#{entry_id}/fail", %{
           worker_id: worker_id,
           lease_token: lease_token,
           error: error_message
         }) do
      {:ok, body} -> response_status(body)
      {:error, reason} -> {:error, reason}
    end
  end

  def fail_run(_client, _entry_id, _worker_id, _lease_token, _error_message),
    do: {:error, :invalid_arguments}

  @spec cancel_ack_run(t(), integer(), String.t(), String.t()) :: :ok | {:error, term()}
  def cancel_ack_run(%__MODULE__{} = client, entry_id, worker_id, lease_token)
      when is_integer(entry_id) and is_binary(worker_id) and is_binary(lease_token) do
    case post(client, "/api/internal/runs/#{entry_id}/cancel-ack", %{
           worker_id: worker_id,
           lease_token: lease_token
         }) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_ack_run(_client, _entry_id, _worker_id, _lease_token),
    do: {:error, :invalid_arguments}

  defp post(%__MODULE__{base_url: nil}, _path, _payload), do: {:error, :missing_base_url}

  defp post(%__MODULE__{} = client, path, payload) do
    headers = auth_headers(client.token)

    case Req.post(client.base_url <> path,
           json: payload,
           headers: headers,
           receive_timeout: client.timeout_ms
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, error_from_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(_body), do: %{}

  defp response_status(%{"data" => %{"cancel_requested" => true}}), do: :cancel_requested
  defp response_status(_body), do: :ok

  defp error_from_body(%{"error" => error}) when is_binary(error), do: error
  defp error_from_body(body) when is_binary(body), do: body
  defp error_from_body(body), do: inspect(body)

  defp auth_headers(nil), do: []
  defp auth_headers(token), do: [{"authorization", "Bearer #{token}"}]

  defp normalize_base_url(nil), do: nil

  defp normalize_base_url(base_url) when is_binary(base_url) do
    case String.trim(base_url) do
      "" -> nil
      value -> String.trim_trailing(value, "/")
    end
  end

  defp normalize_base_url(_value), do: nil
end

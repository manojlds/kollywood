defmodule KollywoodWeb.Plugs.InternalApiAuth do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:kollywood, :internal_api_token) do
      token when is_binary(token) and token != "" ->
        authorize(conn, token)

      _other ->
        conn
    end
  end

  defp authorize(conn, token) do
    with [header] <- get_req_header(conn, "authorization"),
         "Bearer " <> provided <- header,
         true <- Plug.Crypto.secure_compare(provided, token) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:unauthorized, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end
end

defmodule Mix.Tasks.Kollywood.Orch.Shared do
  @moduledoc false

  alias Kollywood.Orchestrator

  @spec ensure_orchestrator_running!() :: GenServer.server()
  def ensure_orchestrator_running! do
    server = orchestrator_server()

    if running?(server) do
      server
    else
      Mix.Task.run("app.start")

      if running?(server) do
        server
      else
        Mix.raise("Kollywood orchestrator is not running. Ensure orchestrator is enabled.")
      end
    end
  end

  @spec orchestrator_server() :: GenServer.server()
  def orchestrator_server do
    Application.get_env(:kollywood, :orchestrator_server, Orchestrator)
  end

  @spec ensure_no_invalid_options!([{atom(), String.t() | nil}]) :: :ok
  def ensure_no_invalid_options!([]), do: :ok

  def ensure_no_invalid_options!(invalid) do
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

  @spec ensure_no_positional_args!([String.t()]) :: :ok
  def ensure_no_positional_args!([]), do: :ok

  def ensure_no_positional_args!(args) do
    Mix.raise("Unexpected positional arguments: #{Enum.join(args, " ")}")
  end

  @spec format_datetime(DateTime.t() | nil | any()) :: String.t()
  def format_datetime(nil), do: "-"
  def format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def format_datetime(value), do: inspect(value)

  defp running?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp running?(server) when is_pid(server), do: Process.alive?(server)
  defp running?(_server), do: false
end

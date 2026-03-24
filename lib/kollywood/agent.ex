defmodule Kollywood.Agent do
  @moduledoc """
  Behaviour and dispatch helpers for agent adapters.

  Adapters provide a common turn-loop interface while handling
  agent-specific CLI invocation details.
  """

  alias Kollywood.Agent.Amp
  alias Kollywood.Agent.Claude
  alias Kollywood.Agent.OpenCode
  alias Kollywood.Agent.Pi
  alias Kollywood.Agent.Session
  alias Kollywood.Config

  @type turn_result :: %{
          output: String.t(),
          raw_output: String.t(),
          exit_code: non_neg_integer(),
          duration_ms: non_neg_integer(),
          command: String.t(),
          args: [String.t()]
        }

  @type session_result :: {:ok, Session.t()} | {:error, String.t()}

  @callback start_session(map() | String.t(), map()) :: session_result()
  @callback run_turn(Session.t(), String.t(), map()) ::
              {:ok, turn_result()} | {:error, String.t()}
  @callback stop_session(Session.t()) :: :ok | {:error, String.t()}

  @doc "Returns the adapter module for an agent kind."
  @spec adapter_module(Config.agent_kind()) :: module()
  def adapter_module(:amp), do: Amp
  def adapter_module(:claude), do: Claude
  def adapter_module(:opencode), do: OpenCode
  def adapter_module(:pi), do: Pi

  @doc "Starts an adapter session from `%Kollywood.Config{}` and workspace info."
  @spec start_session(Config.t(), map() | String.t(), map()) :: session_result()
  def start_session(%Config{} = config, workspace, opts \\ %{}) do
    adapter = adapter_module(config.agent.kind)

    config_opts =
      config.agent
      |> Map.take([:command, :args, :env, :timeout_ms])
      |> Map.reject(fn
        {:args, []} -> true
        {_key, value} -> is_nil(value)
      end)

    adapter.start_session(workspace, Map.merge(config_opts, normalize_opts(opts)))
  end

  @doc "Runs one turn using the adapter stored in the session."
  @spec run_turn(Session.t(), String.t(), map()) :: {:ok, turn_result()} | {:error, String.t()}
  def run_turn(%Session{adapter: adapter} = session, prompt, opts \\ %{}) do
    adapter.run_turn(session, prompt, normalize_opts(opts))
  end

  @doc "Stops an adapter session."
  @spec stop_session(Session.t()) :: :ok | {:error, String.t()}
  def stop_session(%Session{adapter: adapter} = session) do
    adapter.stop_session(session)
  end

  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
end

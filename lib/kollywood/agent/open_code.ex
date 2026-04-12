defmodule Kollywood.Agent.OpenCode do
  @moduledoc """
  Adapter for the OpenCode CLI.

  Prompts are streamed through stdin for each turn.
  """

  @behaviour Kollywood.Agent

  alias Kollywood.Agent.CLI
  alias Kollywood.Agent.Session

  @defaults %{
    command: "opencode",
    args: ["run"],
    prompt_mode: :argv,
    timeout_ms: 7_200_000,
    env: %{}
  }

  @impl true
  @spec start_session(map() | String.t(), map()) :: {:ok, Session.t()} | {:error, String.t()}
  def start_session(workspace, opts \\ %{}) do
    CLI.start_session(__MODULE__, workspace, opts, @defaults)
  end

  @impl true
  @spec run_turn(Session.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def run_turn(session, prompt, opts \\ %{}) do
    CLI.run_turn(session, prompt, maybe_put_model_args(session, opts))
  end

  @impl true
  @spec stop_session(Session.t()) :: :ok
  def stop_session(session) do
    CLI.stop_session(session)
  end

  defp maybe_put_model_args(%Session{model: session_model}, opts) when is_map(opts) do
    model = model_from_opts(opts) || normalize_model(session_model)

    if is_binary(model) and model != "" do
      opts
      |> Map.update(:extra_args, ["--model", model], fn extra_args ->
        ["--model", model] ++ List.wrap(extra_args)
      end)
      |> Map.put_new("extra_args", ["--model", model])
    else
      opts
    end
  end

  defp maybe_put_model_args(_session, opts), do: opts

  defp model_from_opts(opts) do
    normalize_model(Map.get(opts, :model) || Map.get(opts, "model"))
  end

  defp normalize_model(model) when is_binary(model), do: String.trim(model)
  defp normalize_model(_model), do: nil
end

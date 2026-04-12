defmodule Kollywood.Agent.Pi do
  @moduledoc """
  Adapter for the Pi CLI.

  Prompts are streamed through stdin for each turn.
  """

  @behaviour Kollywood.Agent

  alias Kollywood.Agent.CLI
  alias Kollywood.Agent.Session

  @defaults %{
    command: "pi",
    args: ["--print"],
    prompt_mode: :stdin,
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
      Map.update(opts, :extra_args, ["--model", model], fn extra_args ->
        ["--model", model] ++ List.wrap(extra_args)
      end)
    else
      opts
    end
  end

  defp maybe_put_model_args(_session, opts), do: opts

  defp model_from_opts(opts) do
    model = Map.get(opts, :model) || Map.get(opts, "model")
    normalize_model(model)
  end

  defp normalize_model(model) when is_binary(model) do
    trimmed = String.trim(model)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_model(_model), do: nil
end

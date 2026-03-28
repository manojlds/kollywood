defmodule Kollywood.Agent.Cursor do
  @moduledoc """
  Adapter for the Cursor Agent CLI.

  Uses headless non-interactive mode via `--print` and passes prompts as argv.
  """

  @behaviour Kollywood.Agent

  alias Kollywood.Agent.CLI
  alias Kollywood.Agent.Session

  @defaults %{
    command: "cursor",
    args: ["agent", "--print", "--output-format", "text", "--force", "--trust"],
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
    CLI.run_turn(session, prompt, opts)
  end

  @impl true
  @spec stop_session(Session.t()) :: :ok
  def stop_session(session) do
    CLI.stop_session(session)
  end
end

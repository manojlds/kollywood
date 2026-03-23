defmodule Kollywood.Tracker do
  @moduledoc """
  Behaviour for tracker adapters used by the orchestrator.
  """

  alias Kollywood.Config

  @type issue :: map()
  @type issue_id :: String.t()
  @type done_metadata :: map()
  @type failure_reason :: String.t()
  @type failure_attempt :: pos_integer()

  @callback list_active_issues(Config.t()) :: {:ok, [issue()]} | {:error, String.t()}

  @callback claim_issue(Config.t(), issue_id()) :: :ok | {:error, String.t()}

  @callback mark_in_progress(Config.t(), issue_id()) :: :ok | {:error, String.t()}

  @callback mark_done(Config.t(), issue_id(), done_metadata()) :: :ok | {:error, String.t()}

  @callback mark_failed(Config.t(), issue_id(), failure_reason(), failure_attempt()) ::
              :ok | {:error, String.t()}

  @doc "Returns the tracker module for a tracker kind string/atom."
  @spec module_for_kind(String.t() | atom() | nil) :: module()
  def module_for_kind(kind)

  def module_for_kind(kind) when is_atom(kind) do
    kind
    |> Atom.to_string()
    |> module_for_kind()
  end

  def module_for_kind(kind) when is_binary(kind) do
    case kind |> String.trim() |> String.downcase() do
      "prd_json" -> Kollywood.Tracker.PrdJson
      "prd-json" -> Kollywood.Tracker.PrdJson
      "prd" -> Kollywood.Tracker.PrdJson
      "local" -> Kollywood.Tracker.PrdJson
      "noop" -> Kollywood.Tracker.Noop
      "none" -> Kollywood.Tracker.Noop
      _other -> Kollywood.Tracker.Noop
    end
  end

  def module_for_kind(_kind), do: Kollywood.Tracker.Noop
end

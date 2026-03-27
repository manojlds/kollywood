defmodule Kollywood.Tracker.Noop do
  @moduledoc """
  Default tracker adapter that returns no issues.
  """

  @behaviour Kollywood.Tracker

  @impl true
  @spec list_active_issues(Kollywood.Config.t()) :: {:ok, [map()]}
  def list_active_issues(_config), do: {:ok, []}

  @impl true
  @spec claim_issue(Kollywood.Config.t(), String.t()) :: :ok
  def claim_issue(_config, _issue_id), do: :ok

  @impl true
  @spec mark_in_progress(Kollywood.Config.t(), String.t()) :: :ok
  def mark_in_progress(_config, _issue_id), do: :ok

  @impl true
  @spec mark_done(Kollywood.Config.t(), String.t(), map()) :: :ok
  def mark_done(_config, _issue_id, _metadata), do: :ok

  @impl true
  @spec mark_pending_merge(Kollywood.Config.t(), String.t(), map()) :: :ok
  def mark_pending_merge(_config, _issue_id, _metadata), do: :ok

  @impl true
  @spec mark_merged(Kollywood.Config.t(), String.t(), map()) :: :ok
  def mark_merged(_config, _issue_id, _metadata), do: :ok

  @impl true
  @spec mark_failed(Kollywood.Config.t(), String.t(), String.t(), pos_integer()) :: :ok
  def mark_failed(_config, _issue_id, _reason, _attempt), do: :ok
end

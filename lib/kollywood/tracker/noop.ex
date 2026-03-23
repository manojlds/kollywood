defmodule Kollywood.Tracker.Noop do
  @moduledoc """
  Default tracker adapter that returns no issues.
  """

  @behaviour Kollywood.Tracker

  @impl true
  @spec list_active_issues(Kollywood.Config.t()) :: {:ok, [map()]}
  def list_active_issues(_config), do: {:ok, []}
end

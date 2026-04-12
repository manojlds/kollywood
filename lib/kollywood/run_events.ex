defmodule Kollywood.RunEvents do
  @moduledoc """
  Boundary for structured run-event persistence.
  """

  alias Kollywood.RunEvents.Store

  @spec append(map(), map(), atom() | String.t()) :: :ok | {:error, term()}
  def append(context, event, category), do: Store.append(context, event, category)

  @spec stream_exists?(String.t(), String.t(), pos_integer()) ::
          {:ok, boolean()} | {:error, term()}
  def stream_exists?(project_slug, story_id, attempt),
    do: Store.stream_exists?(project_slug, story_id, attempt)

  @spec list_events(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()], non_neg_integer()} | {:error, term()}
  def list_events(project_slug, story_id, attempt, opts \\ []),
    do: Store.list_events(project_slug, story_id, attempt, opts)
end

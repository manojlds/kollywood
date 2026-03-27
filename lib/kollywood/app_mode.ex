defmodule Kollywood.AppMode do
  @moduledoc """
  Runtime mode selector for composing the application supervision tree.

  Modes:

  - `:all` - web UI + orchestrator + agent pool (default)
  - `:web` - web UI only
  - `:orchestrator` - orchestrator + agent pool
  - `:worker` - agent pool only
  """

  @type t :: :all | :web | :orchestrator | :worker

  @valid_modes [:all, :web, :orchestrator, :worker]

  @spec normalize(term()) :: t()
  def normalize(value)

  def normalize(value) when value in @valid_modes, do: value

  def normalize(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "all" -> :all
      "web" -> :web
      "orchestrator" -> :orchestrator
      "worker" -> :worker
      _other -> :all
    end
  end

  def normalize(_value), do: :all

  @spec web_enabled?(t()) :: boolean()
  def web_enabled?(mode), do: normalize(mode) in [:all, :web]

  @spec data_enabled?(t()) :: boolean()
  def data_enabled?(mode), do: normalize(mode) in [:all, :web, :orchestrator]

  @spec orchestrator_enabled?(t()) :: boolean()
  def orchestrator_enabled?(mode), do: normalize(mode) in [:all, :orchestrator]

  @spec agent_pool_enabled?(t()) :: boolean()
  def agent_pool_enabled?(mode), do: normalize(mode) in [:all, :orchestrator, :worker]
end

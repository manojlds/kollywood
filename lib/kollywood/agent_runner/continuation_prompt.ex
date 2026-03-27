defmodule Kollywood.AgentRunner.ContinuationPrompt do
  @moduledoc """
  Builds follow-up prompts for continuation turns.
  """

  @doc """
  Builds a continuation prompt for turn 2 and beyond.
  """
  @spec build(map(), pos_integer()) :: String.t()
  def build(issue, turn_number) when turn_number > 1 do
    identifier = field(issue, :identifier) || "unknown-issue"
    title = field(issue, :title) || "Untitled"

    """
    Continue working on issue #{identifier}: #{title}.
    This is continuation turn ##{turn_number}.
    Review the current workspace changes, continue implementation, and execute the next concrete step.
    """
    |> String.trim()
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil
end

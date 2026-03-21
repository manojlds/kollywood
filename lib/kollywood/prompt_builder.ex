defmodule Kollywood.PromptBuilder do
  @moduledoc """
  Renders Liquid prompt templates with issue context using the Solid library.
  """

  @doc """
  Renders a Liquid template string with the given variables.

  Variables are expected as a map with string keys, e.g.:
    %{"issue" => %{"identifier" => "ABC-123", "title" => "Fix bug"}, "attempt" => 1}

  Returns `{:ok, rendered}` or `{:error, reason}`.
  """
  @spec render(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def render(template, variables) do
    with {:ok, parsed} <- Solid.parse(template),
         {:ok, iolist} <- Solid.render(parsed, variables) do
      {:ok, IO.iodata_to_binary(iolist)}
    else
      {:error, reason} ->
        {:error, "Template parse error: #{inspect(reason)}"}
    end
  end

  @doc """
  Builds the standard variable map for a given issue.
  """
  @spec build_variables(map(), non_neg_integer() | nil) :: map()
  def build_variables(issue, attempt \\ nil) do
    %{
      "issue" => stringify_keys(issue),
      "attempt" => attempt
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(value), do: value
end

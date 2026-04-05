defmodule Kollywood.PromptPipeline do
  @moduledoc """
  Deterministic prompt processing pipeline.

  The pipeline has explicit stages:

  1. validate template argument usage (`args.<name>`)
  2. substitute user-provided prompt args
  3. inject runtime context keys
  4. render the final prompt
  """

  alias Kollywood.PromptBuilder

  @args_reference ~r/\{\{\s*args\.([A-Za-z0-9_]+)\b/
  @reserved_arg_keys ~w(issue_id workspace_path branch run_attempt)

  @spec default_reserved_keys() :: [String.t()]
  def default_reserved_keys, do: @reserved_arg_keys

  @spec settings_snapshot(String.t(), map() | keyword() | nil, keyword()) :: map()
  def settings_snapshot(template, prompt_args, opts \\ []) do
    args = normalize_prompt_args(prompt_args)
    reserved_keys = normalize_reserved_keys(Keyword.get(opts, :reserved_keys, @reserved_arg_keys))

    runtime_context_keys =
      opts
      |> Keyword.get(:runtime_context_keys, [])
      |> normalize_runtime_context_keys()

    required_args = required_arg_keys(template)
    provided_args = args |> Map.keys() |> Enum.sort()
    reserved_collisions = Enum.filter(provided_args, &(&1 in reserved_keys))
    missing_args = required_args -- provided_args
    unused_args = provided_args -- required_args

    errors =
      []
      |> maybe_append_error(reserved_collisions, "reserved prompt args are not allowed")
      |> maybe_append_error(missing_args, "missing required prompt args")

    warnings =
      []
      |> maybe_append_warning(unused_args, "unused prompt args")

    %{
      "required_args" => required_args,
      "provided_args" => provided_args,
      "missing_args" => missing_args,
      "unused_args" => unused_args,
      "reserved_keys" => reserved_keys,
      "runtime_context_keys" => runtime_context_keys,
      "warnings" => warnings,
      "errors" => errors
    }
  end

  @spec validate_settings(map()) :: :ok | {:error, String.t()}
  def validate_settings(%{"errors" => errors}) when is_list(errors) and errors != [] do
    {:error, Enum.join(errors, "; ")}
  end

  def validate_settings(_settings), do: :ok

  @spec build(String.t(), map() | nil, keyword()) ::
          {:ok, String.t(), map()} | {:error, String.t(), map()}
  def build(template, base_variables, opts \\ []) do
    args = normalize_prompt_args(Keyword.get(opts, :prompt_args, %{}))
    runtime_context = normalize_runtime_context(Keyword.get(opts, :runtime_context, %{}))

    settings =
      settings_snapshot(template, args,
        reserved_keys: Keyword.get(opts, :reserved_keys, @reserved_arg_keys),
        runtime_context_keys: Map.keys(runtime_context)
      )

    with :ok <- validate_settings(settings),
         {:ok, prompt} <- render(template, base_variables, args, runtime_context) do
      {:ok, prompt, settings}
    else
      {:error, reason} ->
        settings = put_render_error(settings, reason)
        {:error, reason, settings}
    end
  end

  @spec required_arg_keys(String.t()) :: [String.t()]
  def required_arg_keys(template) when is_binary(template) do
    @args_reference
    |> Regex.scan(template)
    |> Enum.map(fn
      [_full, key] -> key
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def required_arg_keys(_template), do: []

  defp render(template, base_variables, args, runtime_context) when is_binary(template) do
    variables =
      base_variables
      |> normalize_base_variables()
      |> Map.put("args", args)
      |> Map.merge(runtime_context)

    case PromptBuilder.render(template, variables) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, "template render failed: #{reason}"}
    end
  end

  defp render(_template, _base_variables, _args, _runtime_context) do
    {:error, "template must be a non-empty string"}
  end

  defp normalize_base_variables(variables) when is_map(variables), do: variables
  defp normalize_base_variables(_variables), do: %{}

  defp normalize_prompt_args(args) when is_map(args) do
    Map.new(args, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_prompt_args(args) when is_list(args) do
    if Keyword.keyword?(args) do
      args
      |> Map.new()
      |> normalize_prompt_args()
    else
      %{}
    end
  end

  defp normalize_prompt_args(_args), do: %{}

  defp normalize_runtime_context(runtime_context) when is_map(runtime_context) do
    Map.new(runtime_context, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_runtime_context(_runtime_context), do: %{}

  defp normalize_reserved_keys(keys) when is_list(keys) do
    keys
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_reserved_keys(_keys), do: @reserved_arg_keys

  defp normalize_runtime_context_keys(keys) when is_list(keys) do
    keys
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_runtime_context_keys(_keys), do: []

  defp maybe_append_error(errors, [], _label), do: errors

  defp maybe_append_error(errors, values, label) when is_list(values) do
    ["#{label}: #{Enum.join(values, ", ")}" | errors]
  end

  defp maybe_append_warning(warnings, [], _label), do: warnings

  defp maybe_append_warning(warnings, values, label) when is_list(values) do
    ["#{label}: #{Enum.join(values, ", ")}" | warnings]
  end

  defp put_render_error(settings, reason) do
    errors = [reason | List.wrap(Map.get(settings, "errors", []))]
    Map.put(settings, "errors", errors)
  end
end

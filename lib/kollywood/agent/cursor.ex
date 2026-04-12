defmodule Kollywood.Agent.Cursor do
  @moduledoc """
  Adapter for the Cursor Agent CLI.

  Uses headless non-interactive mode via `--print` with `stream-json` output so
  long-running turns flush incremental log updates while the process is active.
  Prompts are passed as argv.
  """

  @behaviour Kollywood.Agent

  alias Kollywood.Agent.CLI
  alias Kollywood.Agent.Session

  @defaults %{
    command: "cursor",
    args: [
      "agent",
      "--print",
      "--output-format",
      "stream-json",
      "--stream-partial-output",
      "--force",
      "--trust"
    ],
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
    opts =
      opts
      |> maybe_put_model_args(session)
      |> maybe_enable_visual_raw_log()

    case CLI.run_turn(session, prompt, opts) do
      {:ok, result} ->
        {:ok, normalize_stream_result(result)}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  @spec stop_session(Session.t()) :: :ok
  def stop_session(session) do
    CLI.stop_session(session)
  end

  defp maybe_enable_visual_raw_log(opts) when is_map(opts) do
    raw_log = Map.get(opts, :raw_log) || Map.get(opts, "raw_log")

    has_raw_log_mode? =
      Map.has_key?(opts, :raw_log_mode) or Map.has_key?(opts, "raw_log_mode")

    if is_binary(raw_log) and String.trim(raw_log) != "" and not has_raw_log_mode? do
      Map.put(opts, :raw_log_mode, :cursor_stream_json_to_text)
    else
      opts
    end
  end

  defp maybe_enable_visual_raw_log(opts), do: opts

  defp maybe_put_model_args(opts, %Session{model: session_model}) when is_map(opts) do
    model = model_from_opts(opts) || normalize_model(session_model)

    if is_binary(model) and model != "" do
      Map.update(opts, :extra_args, ["--model", model], fn extra_args ->
        ["--model", model] ++ List.wrap(extra_args)
      end)
    else
      opts
    end
  end

  defp maybe_put_model_args(opts, _session), do: opts

  defp model_from_opts(opts) do
    model = Map.get(opts, :model) || Map.get(opts, "model")
    normalize_model(model)
  end

  defp normalize_model(model) when is_binary(model) do
    trimmed = String.trim(model)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_model(_model), do: nil

  defp normalize_stream_result(%{raw_output: raw_output} = result) do
    case extract_final_output(raw_output) do
      {:ok, output} -> %{result | output: output}
      :error -> result
    end
  end

  defp normalize_stream_result(result), do: result

  defp extract_final_output(raw_output) when is_binary(raw_output) do
    raw_output
    |> String.split("\n", trim: true)
    |> Enum.reduce({nil, []}, &collect_stream_output/2)
    |> finalize_stream_output()
  end

  defp extract_final_output(_raw_output), do: :error

  defp collect_stream_output(line, {result_text, assistant_chunks}) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result", "result" => text}} when is_binary(text) ->
        {text, assistant_chunks}

      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}}
      when is_list(content) ->
        chunk = assistant_content_text(content)

        if chunk == "" do
          {result_text, assistant_chunks}
        else
          {result_text, [chunk | assistant_chunks]}
        end

      _other ->
        {result_text, assistant_chunks}
    end
  end

  defp finalize_stream_output({result_text, assistant_chunks}) when is_binary(result_text) do
    case String.trim(result_text) do
      "" -> fallback_assistant_output(assistant_chunks)
      trimmed -> {:ok, trimmed}
    end
  end

  defp finalize_stream_output({_result_text, assistant_chunks}) do
    fallback_assistant_output(assistant_chunks)
  end

  defp fallback_assistant_output(assistant_chunks) do
    assistant_chunks
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim()
    |> case do
      "" -> :error
      text -> {:ok, text}
    end
  end

  defp assistant_content_text(content) do
    Enum.map_join(content, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _other -> ""
    end)
  end
end

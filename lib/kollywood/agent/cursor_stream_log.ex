defmodule Kollywood.Agent.CursorStreamLog do
  @moduledoc false

  @type state :: %{
          buffer: String.t(),
          saw_cursor_stream?: boolean(),
          saw_assistant_text?: boolean()
        }

  @spec init_state() :: state()
  def init_state do
    %{
      buffer: "",
      saw_cursor_stream?: false,
      saw_assistant_text?: false
    }
  end

  @spec feed(state(), binary()) :: {iodata(), state()}
  def feed(state, chunk) when is_map(state) and is_binary(chunk) do
    data = state.buffer <> chunk
    {lines, remainder} = split_lines_with_remainder(data)

    {chunks, state} =
      Enum.reduce(lines, {[], %{state | buffer: remainder}}, fn line, {acc, current_state} ->
        {rendered, next_state} = decode_line(line, current_state, true)
        {[rendered | acc], next_state}
      end)

    {Enum.reverse(chunks), state}
  end

  @spec flush(state()) :: {iodata(), state()}
  def flush(%{buffer: ""} = state), do: {"", state}

  def flush(%{buffer: buffer} = state) do
    decode_line(buffer, %{state | buffer: ""}, false)
  end

  @spec render(binary()) :: binary()
  def render(content) when is_binary(content) do
    state = init_state()
    {rendered, state} = feed(state, content)
    {tail, state} = flush(state)

    output =
      [rendered, tail]
      |> IO.iodata_to_binary()
      |> String.trim_trailing()

    if state.saw_cursor_stream? && output != "" do
      output
    else
      content
    end
  end

  defp split_lines_with_remainder(data) do
    {parts, remainder} =
      data
      |> :binary.split("\n", [:global])
      |> split_last_segment([])

    {parts, remainder}
  end

  defp split_last_segment([last], acc), do: {Enum.reverse(acc), last}
  defp split_last_segment([part | rest], acc), do: split_last_segment(rest, [part | acc])
  defp split_last_segment([], acc), do: {Enum.reverse(acc), ""}

  defp decode_line(line, state, line_terminated?) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {render_raw_line(line, line_terminated?), state}
    else
      case Jason.decode(trimmed) do
        {:ok, %{"type" => type} = event} when is_binary(type) ->
          {rendered, state} = format_event(type, event, state)
          {rendered, %{state | saw_cursor_stream?: true}}

        _other ->
          {render_raw_line(line, line_terminated?), state}
      end
    end
  end

  defp render_raw_line(line, true), do: [line, "\n"]
  defp render_raw_line(line, false), do: line

  defp format_event("assistant", event, state) do
    text = assistant_text(event)

    if text == "" do
      {"", state}
    else
      {text, %{state | saw_assistant_text?: true}}
    end
  end

  defp format_event("tool_call", event, state) do
    {tool_call_line(event), state}
  end

  defp format_event("result", event, state) do
    result =
      event
      |> Map.get("result")
      |> case do
        value when is_binary(value) -> String.trim(value)
        _other -> ""
      end

    cond do
      result == "" ->
        {"", state}

      state.saw_assistant_text? ->
        # Stream-json usually emits assistant text deltas plus a final result
        # summary; avoid duplicating the same content in visual logs.
        {"", state}

      true ->
        {"\n\n#{result}\n", state}
    end
  end

  defp format_event("system", _event, state), do: {"", state}
  defp format_event("user", _event, state), do: {"", state}
  defp format_event(_type, _event, state), do: {"", state}

  defp assistant_text(event) when is_map(event) do
    content =
      event
      |> Map.get("message", %{})
      |> Map.get("content")

    cond do
      is_list(content) ->
        Enum.map_join(content, "", &assistant_content_text/1)

      is_binary(content) ->
        content

      is_binary(Map.get(event, "text")) ->
        Map.get(event, "text")

      true ->
        ""
    end
  end

  defp assistant_text(_event), do: ""

  defp assistant_content_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp assistant_content_text(_content), do: ""

  defp tool_call_line(event) do
    subtype = tool_call_subtype(Map.get(event, "subtype"))
    {tool_name, payload} = tool_call_info(Map.get(event, "tool_call"))
    summary = tool_summary(tool_name, payload)

    line =
      "[tool #{subtype}] #{tool_name}" <>
        if(summary, do: ": #{summary}", else: "")

    "\n#{line}\n"
  end

  defp tool_call_subtype(subtype) when is_binary(subtype) and subtype != "", do: subtype
  defp tool_call_subtype(_subtype), do: "event"

  defp tool_call_info(tool_call) when is_map(tool_call) do
    case Enum.at(tool_call, 0) do
      {name, payload} when is_binary(name) ->
        {tool_name(name), payload}

      _other ->
        {"tool", %{}}
    end
  end

  defp tool_call_info(_tool_call), do: {"tool", %{}}

  defp tool_name(name) when is_binary(name) do
    name
    |> String.replace_suffix("ToolCall", "")
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> case do
      "" -> "tool"
      value -> value
    end
  end

  defp tool_name(_name), do: "tool"

  defp tool_summary(tool_name, payload) when is_binary(tool_name) and is_map(payload) do
    args = Map.get(payload, "args", %{})

    summary =
      case tool_name do
        "shell" -> arg(args, ["command", "cmd"])
        "read_file" -> arg(args, ["path"])
        "grep" -> arg(args, ["pattern"])
        "glob" -> arg(args, ["globPattern", "glob_pattern"])
        _other -> nil
      end

    case summary do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: String.slice(trimmed, 0, 120)

      _other ->
        nil
    end
  end

  defp tool_summary(_tool_name, _payload), do: nil

  defp arg(args, keys) when is_map(args) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(args, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp arg(_args, _keys), do: nil
end

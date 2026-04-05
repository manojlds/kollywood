defmodule Kollywood.Chat.Session do
  @moduledoc false

  use GenServer

  require Logger

  alias Kollywood.Chat

  @initialize_method "initialize"
  @session_new_method "session/new"
  @session_prompt_method "session/prompt"
  @session_cancel_method "session/cancel"

  @type state :: %{
          session_id: String.t(),
          project_slug: String.t(),
          cwd: String.t(),
          title: String.t(),
          status: :starting | :ready | :running | :cancelling | :error | :stopped,
          error: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          port: port() | nil,
          buffer: String.t(),
          next_rpc_id: pos_integer(),
          pending: %{optional(integer()) => atom() | tuple()},
          acp_session_id: String.t() | nil,
          messages: [map()],
          remote_to_local: %{optional(String.t()) => String.t()},
          queued_prompts: [{String.t(), String.t()}]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec snapshot(pid()) :: {:ok, map()} | {:error, String.t()}
  def snapshot(pid) when is_pid(pid) do
    GenServer.call(pid, :snapshot)
  catch
    :exit, _ -> {:error, "chat session is unavailable"}
  end

  @spec summary(pid()) :: {:ok, map()} | {:error, String.t()}
  def summary(pid) when is_pid(pid) do
    GenServer.call(pid, :summary)
  catch
    :exit, _ -> {:error, "chat session is unavailable"}
  end

  @spec send_prompt(pid(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def send_prompt(pid, prompt) when is_pid(pid) and is_binary(prompt) do
    GenServer.call(pid, {:send_prompt, prompt}, 120_000)
  catch
    :exit, _ -> {:error, "chat session is unavailable"}
  end

  @spec cancel(pid()) :: :ok | {:error, String.t()}
  def cancel(pid) when is_pid(pid) do
    GenServer.call(pid, :cancel)
  catch
    :exit, _ -> {:error, "chat session is unavailable"}
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    project_slug = Keyword.fetch!(opts, :project_slug)
    cwd = Keyword.fetch!(opts, :cwd)
    title = Keyword.get(opts, :title, "New chat")
    now = DateTime.utc_now()

    state = %{
      session_id: session_id,
      project_slug: project_slug,
      cwd: cwd,
      title: title,
      status: :starting,
      error: nil,
      created_at: now,
      updated_at: now,
      port: nil,
      buffer: "",
      next_rpc_id: 1,
      pending: %{},
      acp_session_id: nil,
      messages: [],
      remote_to_local: %{},
      queued_prompts: []
    }

    case open_acp_port(cwd) do
      {:ok, port} ->
        state =
          state
          |> Map.put(:port, port)
          |> send_request(@initialize_method, initialize_params(), :initialize)
          |> publish_update()

        {:ok, state}

      {:error, reason} ->
        state =
          state
          |> set_error(reason)
          |> publish_update()

        {:ok, state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, snapshot_view(state)}, state}
  end

  def handle_call(:summary, _from, state) do
    {:reply, {:ok, summary_view(state)}, state}
  end

  def handle_call({:send_prompt, prompt}, _from, state) do
    text = String.trim(prompt)

    cond do
      text == "" ->
        {:reply, {:error, "prompt is required"}, state}

      state.status == :cancelling ->
        {:reply, {:error, "chat session is busy (status=#{state.status})"}, state}

      is_nil(state.port) ->
        {:reply, {:error, "chat transport is not available"}, state}

      state.status == :error and is_nil(state.acp_session_id) ->
        {:reply, {:error, state.error || "chat session is not ready"}, state}

      true ->
        user_message = new_message("user", text)

        {state, queued?} =
          state
          |> append_message(user_message)
          |> maybe_update_title_from_prompt(text)
          |> queue_or_send_prompt(text, user_message.id)
          |> then(fn {queued_state, queue_status} ->
            queued_state =
              queued_state
              |> touch()
              |> clear_error()
              |> publish_update()

            {queued_state, queue_status == :queued}
          end)

        {:reply, {:ok, %{message_id: user_message.id, queued: queued?}}, state}
    end
  end

  def handle_call(:cancel, _from, state) do
    cond do
      is_nil(state.acp_session_id) ->
        {:reply, {:error, "chat session is not ready"}, state}

      is_nil(state.port) ->
        {:reply, {:error, "chat transport is not available"}, state}

      true ->
        state =
          state
          |> send_notification(@session_cancel_method, %{"sessionId" => state.acp_session_id})
          |> Map.put(:status, :cancelling)
          |> Map.put(:queued_prompts, [])
          |> touch()
          |> clear_error()
          |> publish_update()

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) when is_binary(chunk) do
    state =
      state
      |> consume_chunk(chunk)
      |> publish_update_if_changed()

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = "ACP process exited with status #{status}"

    state =
      state
      |> Map.put(:port, nil)
      |> Map.put(:status, :stopped)
      |> set_error(reason)
      |> touch()
      |> publish_update()

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_port(state.port), do: Port.close(state.port)
    :ok
  end

  defp initialize_params do
    %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      },
      "clientInfo" => %{
        "name" => "kollywood",
        "version" => Kollywood.Version.full()
      }
    }
  end

  defp open_acp_port(cwd) when is_binary(cwd) do
    config = Application.get_env(:kollywood, :chat_acp, [])
    command = Keyword.get(config, :command, "opencode")
    base_args = Keyword.get(config, :args, ["acp", "--pure"])
    args = base_args ++ ["--cwd", cwd]

    executable = System.find_executable(command)

    cond do
      !File.dir?(cwd) ->
        {:error, "chat cwd does not exist: #{cwd}"}

      is_nil(executable) ->
        {:error, "ACP command not found: #{command}"}

      true ->
        try do
          port =
            Port.open({:spawn_executable, String.to_charlist(executable)}, [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              {:args, Enum.map(args, &String.to_charlist/1)},
              {:cd, String.to_charlist(cwd)}
            ])

          {:ok, port}
        rescue
          error ->
            {:error, "failed to start ACP process: #{Exception.message(error)}"}
        end
    end
  end

  defp consume_chunk(state, chunk) do
    data = state.buffer <> chunk
    {lines, rest} = split_lines(data)

    state =
      Enum.reduce(lines, %{state | buffer: rest}, fn line, acc ->
        process_line(acc, line)
      end)

    %{state | buffer: rest}
  end

  defp split_lines(data) when is_binary(data) do
    parts = :binary.split(data, "\n", [:global])

    case parts do
      [] ->
        {[], ""}

      [single] ->
        {[], single}

      _many ->
        rest = List.last(parts) || ""
        lines = Enum.slice(parts, 0, length(parts) - 1)
        {lines, rest}
    end
  end

  defp process_line(state, line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      state
    else
      case Jason.decode(trimmed) do
        {:ok, payload} when is_map(payload) ->
          process_payload(state, payload)

        _other ->
          state
      end
    end
  end

  defp process_payload(state, %{"id" => id} = payload) when is_integer(id) do
    handle_response(state, id, payload)
  end

  defp process_payload(state, %{"method" => "session/update"} = payload) do
    handle_session_update(state, payload)
  end

  defp process_payload(state, _payload), do: state

  defp handle_response(state, id, payload) do
    {tag, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}

    cond do
      Map.has_key?(payload, "error") ->
        reason = format_rpc_error(payload["error"])

        case tag do
          {:prompt, _message_id} ->
            state |> Map.put(:status, :ready) |> set_error(reason) |> touch()

          _other ->
            state |> set_error(reason) |> touch()
        end

      true ->
        result = Map.get(payload, "result", %{})

        case tag do
          :initialize ->
            state
            |> send_request(
              @session_new_method,
              %{"cwd" => state.cwd, "mcpServers" => []},
              :session_new
            )
            |> touch()

          :session_new ->
            acp_session_id =
              result
              |> Map.get("sessionId")
              |> case do
                value when is_binary(value) and value != "" -> value
                _ -> nil
              end

            if is_binary(acp_session_id) do
              state
              |> Map.put(:acp_session_id, acp_session_id)
              |> Map.put(:status, :ready)
              |> clear_error()
              |> touch()
              |> maybe_dispatch_next_prompt()
            else
              state
              |> set_error("ACP session/new did not return a sessionId")
              |> touch()
            end

          {:prompt, _message_id} ->
            state
            |> Map.put(:status, :ready)
            |> clear_error()
            |> touch()
            |> maybe_dispatch_next_prompt()

          _other ->
            state
        end
    end
  end

  defp handle_session_update(state, payload) do
    update = get_in(payload, ["params", "update"])

    case update do
      _other ->
        case assistant_update(update) do
          {:ok, remote_id, text} ->
            {state, local_id} = ensure_assistant_message(state, remote_id)
            state |> append_message_text(local_id, text) |> clear_error() |> touch()

          :ignore ->
            state
        end
    end
  end

  defp assistant_update(update) when is_map(update) do
    type =
      update
      |> Map.get("sessionUpdate", "")
      |> to_string()

    cond do
      type in ["agent_message", "agent_message_chunk", "agent_message_delta"] ->
        remote_id =
          case Map.get(update, "messageId") do
            value when is_binary(value) and value != "" ->
              value

            _other ->
              "assistant-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
          end

        text =
          get_in(update, ["content", "text"]) ||
            Map.get(update, "text") ||
            get_in(update, ["message", "content", "text"])

        if is_binary(text) and text != "" do
          {:ok, remote_id, text}
        else
          :ignore
        end

      true ->
        :ignore
    end
  end

  defp assistant_update(_update), do: :ignore

  defp ensure_assistant_message(state, remote_id) do
    case Map.get(state.remote_to_local, remote_id) do
      local_id when is_binary(local_id) ->
        {state, local_id}

      _other ->
        message = new_message("assistant", "")

        state =
          state
          |> append_message(message)
          |> Map.put(:remote_to_local, Map.put(state.remote_to_local, remote_id, message.id))

        {state, message.id}
    end
  end

  defp send_request(state, method, params, tag) do
    if is_port(state.port) do
      id = state.next_rpc_id

      payload = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      }

      Port.command(state.port, Jason.encode!(payload) <> "\n")

      %{state | next_rpc_id: id + 1, pending: Map.put(state.pending, id, tag)}
    else
      state
    end
  end

  defp queue_or_send_prompt(state, text, message_id)
       when is_binary(text) and is_binary(message_id) do
    cond do
      is_nil(state.acp_session_id) or state.status == :starting ->
        {enqueue_prompt(state, text, message_id), :queued}

      state.status == :running ->
        {enqueue_prompt(state, text, message_id), :queued}

      true ->
        {dispatch_prompt_request(state, text, message_id), :sent}
    end
  end

  defp maybe_dispatch_next_prompt(
         %{status: :ready, queued_prompts: [{text, message_id} | rest]} = state
       )
       when is_binary(state.acp_session_id) and is_port(state.port) do
    state
    |> Map.put(:queued_prompts, rest)
    |> dispatch_prompt_request(text, message_id)
  end

  defp maybe_dispatch_next_prompt(state), do: state

  defp enqueue_prompt(state, text, message_id) do
    Map.put(state, :queued_prompts, state.queued_prompts ++ [{text, message_id}])
  end

  defp dispatch_prompt_request(state, text, message_id) do
    params = %{
      "sessionId" => state.acp_session_id,
      "prompt" => [%{"type" => "text", "text" => text}]
    }

    state
    |> send_request(@session_prompt_method, params, {:prompt, message_id})
    |> Map.put(:status, :running)
  end

  defp send_notification(state, method, params) do
    if is_port(state.port) do
      payload = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
      Port.command(state.port, Jason.encode!(payload) <> "\n")
    end

    state
  end

  defp new_message(role, content) do
    %{
      id: "m-" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
      role: role,
      content: content,
      created_at: DateTime.utc_now()
    }
  end

  defp append_message(state, message) do
    %{state | messages: state.messages ++ [message]}
  end

  defp append_message_text(state, message_id, text) do
    messages =
      Enum.map(state.messages, fn message ->
        if message.id == message_id do
          %{message | content: message.content <> text}
        else
          message
        end
      end)

    %{state | messages: messages}
  end

  defp maybe_update_title_from_prompt(state, text) do
    should_set_title? =
      state.title in ["", "New chat"] and count_user_messages(state.messages) == 1

    if should_set_title? do
      title =
        text
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 64)

      %{state | title: if(title == "", do: "New chat", else: title)}
    else
      state
    end
  end

  defp count_user_messages(messages) do
    Enum.count(messages, &(&1.role == "user"))
  end

  defp format_rpc_error(%{"message" => message}) when is_binary(message), do: message
  defp format_rpc_error(error), do: "ACP error: #{inspect(error)}"

  defp set_error(state, reason) when is_binary(reason) do
    state
    |> Map.put(:status, :error)
    |> Map.put(:error, reason)
  end

  defp clear_error(state), do: %{state | error: nil}

  defp touch(state), do: %{state | updated_at: DateTime.utc_now()}

  defp summary_view(state) do
    %{
      id: state.session_id,
      project_slug: state.project_slug,
      title: state.title,
      status: state.status,
      error: state.error,
      updated_at: state.updated_at
    }
  end

  defp snapshot_view(state) do
    %{
      id: state.session_id,
      project_slug: state.project_slug,
      cwd: state.cwd,
      title: state.title,
      status: state.status,
      error: state.error,
      acp_session_id: state.acp_session_id,
      created_at: state.created_at,
      updated_at: state.updated_at,
      messages: state.messages
    }
  end

  defp publish_update(state) do
    Phoenix.PubSub.broadcast(
      Kollywood.PubSub,
      Chat.topic(state.project_slug),
      {:chat_session_updated, state.project_slug, state.session_id}
    )

    state
  end

  defp publish_update_if_changed(state), do: publish_update(state)
end

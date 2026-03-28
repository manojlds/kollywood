defmodule Kollywood.Agent.CLI do
  @moduledoc false

  alias Kollywood.Agent.CursorStreamLog
  alias Kollywood.Agent.Session

  @type defaults :: %{
          command: String.t(),
          args: [String.t()],
          prompt_mode: Session.prompt_mode(),
          timeout_ms: pos_integer(),
          env: map()
        }

  @spec start_session(module(), map() | String.t(), map(), defaults()) ::
          {:ok, Session.t()} | {:error, String.t()}
  def start_session(adapter, workspace, opts, defaults) when is_map(opts) do
    with {:ok, workspace_path} <- workspace_path(workspace),
         :ok <- ensure_workspace_exists(workspace_path),
         {:ok, command} <- command(opts, defaults),
         {:ok, args} <- args(opts, defaults),
         {:ok, env} <- env(opts, defaults),
         {:ok, timeout_ms} <- timeout_ms(opts, defaults),
         {:ok, prompt_mode} <- prompt_mode(opts, defaults) do
      {:ok,
       %Session{
         id: System.unique_integer([:positive, :monotonic]),
         adapter: adapter,
         workspace_path: workspace_path,
         command: command,
         args: args,
         env: env,
         timeout_ms: timeout_ms,
         prompt_mode: prompt_mode
       }}
    end
  end

  def start_session(_adapter, _workspace, _opts, _defaults) do
    {:error, "Session options must be a map"}
  end

  @spec run_turn(Session.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def run_turn(%Session{} = session, prompt, opts) when is_binary(prompt) and is_map(opts) do
    with {:ok, extra_args} <- extra_args(opts),
         {:ok, env} <- merge_turn_env(session.env, opts),
         {:ok, timeout_ms} <- turn_timeout(session.timeout_ms, opts),
         {:ok, prompt_mode} <- turn_prompt_mode(session.prompt_mode, opts) do
      args = session.args ++ extra_args
      raw_log = opt(opts, :raw_log, nil)
      raw_log_mode = opt(opts, :raw_log_mode, :raw)
      execute(session, args, prompt, prompt_mode, env, timeout_ms, raw_log, raw_log_mode)
    end
  end

  def run_turn(_session, _prompt, _opts),
    do: {:error, "Prompt must be a string and options must be a map"}

  @spec stop_session(Session.t()) :: :ok
  def stop_session(%Session{}), do: :ok

  defp execute(session, args, prompt, prompt_mode, env, timeout_ms, raw_log, raw_log_mode) do
    {command, command_args, command_opts, cleanup} =
      command_invocation(session, args, prompt, prompt_mode, env)

    try do
      started_at = System.monotonic_time(:millisecond)

      result =
        port_execute(command, command_args, command_opts, timeout_ms, raw_log, raw_log_mode)

      case result do
        {:ok, {output, 0}} ->
          {:ok,
           %{
             output: String.trim(output),
             raw_output: output,
             exit_code: 0,
             duration_ms: System.monotonic_time(:millisecond) - started_at,
             command: session.command,
             args: final_args(args, prompt, prompt_mode)
           }}

        {:ok, {output, exit_code}} ->
          {:error, "Agent command failed with exit code #{exit_code}: #{String.trim(output)}"}

        {:error, :timeout} ->
          {:error, "Agent command timed out after #{timeout_ms}ms"}
      end
    rescue
      error in ErlangError ->
        {:error,
         "Failed to execute agent command #{session.command}: #{Exception.message(error)}"}
    after
      cleanup.()
    end
  end

  defp port_execute(command, args, opts, timeout_ms, raw_log, raw_log_mode) do
    # Port.open requires charlists for executable, args, cd, and env keys/values.
    # System.cmd handles these conversions internally; we must do them explicitly.
    executable =
      (System.find_executable(command) || command) |> String.to_charlist()

    cd =
      opts
      |> Keyword.get(:cd)
      |> then(fn
        nil -> nil
        s -> String.to_charlist(s)
      end)

    env =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    args_cl = Enum.map(args, &String.to_charlist/1)

    port_opts =
      [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args_cl}]
      |> then(fn o -> if cd, do: [{:cd, cd} | o], else: o end)
      |> then(fn o -> if env != [], do: [{:env, env} | o], else: o end)

    port = Port.open({:spawn_executable, executable}, port_opts)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_port_output(port, raw_log, init_raw_log_state(raw_log_mode), [], deadline)
  end

  defp collect_port_output(port, raw_log, raw_log_state, chunks, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Port.close(port)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, chunk}} ->
          {log_chunk, raw_log_state} = format_raw_log_chunk(raw_log_state, chunk)
          maybe_write_raw_log(raw_log, log_chunk)

          collect_port_output(port, raw_log, raw_log_state, [chunks, chunk], deadline)

        {^port, {:exit_status, status}} ->
          {tail_chunk, _raw_log_state} = flush_raw_log_chunk(raw_log_state)
          maybe_write_raw_log(raw_log, tail_chunk)

          {:ok, {IO.iodata_to_binary(chunks), status}}
      after
        remaining ->
          Port.close(port)
          {:error, :timeout}
      end
    end
  end

  defp init_raw_log_state(:cursor_stream_json_to_text),
    do: {:cursor_stream_json_to_text, CursorStreamLog.init_state()}

  defp init_raw_log_state("cursor_stream_json_to_text"),
    do: {:cursor_stream_json_to_text, CursorStreamLog.init_state()}

  defp init_raw_log_state(_mode), do: :raw

  defp format_raw_log_chunk(:raw, chunk), do: {chunk, :raw}

  defp format_raw_log_chunk({:cursor_stream_json_to_text, state}, chunk) when is_binary(chunk) do
    {rendered, state} = CursorStreamLog.feed(state, chunk)
    {rendered, {:cursor_stream_json_to_text, state}}
  end

  defp format_raw_log_chunk(_state, chunk), do: {chunk, :raw}

  defp flush_raw_log_chunk(:raw), do: {"", :raw}

  defp flush_raw_log_chunk({:cursor_stream_json_to_text, state}) do
    {rendered, state} = CursorStreamLog.flush(state)
    {rendered, {:cursor_stream_json_to_text, state}}
  end

  defp flush_raw_log_chunk(_state), do: {"", :raw}

  defp maybe_write_raw_log(raw_log, chunk) when is_binary(raw_log) do
    if iodata_present?(chunk) do
      File.write(raw_log, chunk, [:append])
    else
      :ok
    end
  end

  defp maybe_write_raw_log(_raw_log, _chunk), do: :ok

  defp iodata_present?(chunk) do
    try do
      IO.iodata_length(chunk) > 0
    rescue
      _ -> false
    end
  end

  defp command_invocation(session, args, prompt, :argv, env) do
    # Wrap with bash to redirect stdin from /dev/null — prevents CLI tools that
    # detect a pipe on stdin (e.g. claude) from waiting for input and polluting stdout.
    wrapper_args =
      ["-c", "exec \"$1\" \"${@:2}\" < /dev/null", "--", session.command] ++ args ++ [prompt]

    {"bash", wrapper_args, command_opts(session.workspace_path, env), fn -> :ok end}
  end

  defp command_invocation(session, args, prompt, :stdin, env) do
    prompt_file = prompt_file()
    File.write!(prompt_file, prompt)

    wrapper_args =
      ["-lc", "exec \"$2\" \"${@:3}\" < \"$1\"", "--", prompt_file, session.command] ++ args

    {"bash", wrapper_args, command_opts(session.workspace_path, env),
     fn -> File.rm(prompt_file) end}
  end

  defp command_opts(workspace_path, env) do
    [
      cd: workspace_path,
      env: env_to_cmd_env(env),
      stderr_to_stdout: true
    ]
  end

  defp final_args(args, _prompt, :stdin), do: args
  defp final_args(args, prompt, :argv), do: args ++ [prompt]

  defp prompt_file do
    filename = "kollywood_prompt_#{System.unique_integer([:positive, :monotonic])}.txt"
    Path.join(System.tmp_dir!(), filename)
  end

  defp workspace_path(%{path: path}) when is_binary(path), do: {:ok, path}
  defp workspace_path(path) when is_binary(path), do: {:ok, path}
  defp workspace_path(_), do: {:error, "Workspace must be a path string or map with :path"}

  defp ensure_workspace_exists(path) do
    if File.dir?(path) do
      :ok
    else
      {:error, "Workspace path does not exist: #{path}"}
    end
  end

  defp command(opts, defaults) do
    value = opt(opts, :command, defaults.command)

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, "Agent command must be a non-empty string"}
    end
  end

  defp args(opts, defaults), do: string_list(opt(opts, :args, defaults.args), "agent args")

  defp extra_args(opts), do: string_list(opt(opts, :extra_args, []), "turn extra_args")

  defp string_list(value, label) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      {:error, "#{label} must be a list of strings"}
    end
  end

  defp string_list(_value, label), do: {:error, "#{label} must be a list of strings"}

  defp env(opts, defaults) do
    normalize_env(opt(opts, :env, defaults.env), "session env")
  end

  defp merge_turn_env(base_env, opts) do
    with {:ok, turn_env} <- normalize_env(opt(opts, :env, %{}), "turn env") do
      {:ok, Map.merge(base_env, turn_env)}
    end
  end

  defp normalize_env(value, _label) when is_map(value) do
    {:ok,
     Map.new(value, fn {key, val} ->
       {to_string(key), to_string(val)}
     end)}
  end

  defp normalize_env(_value, label), do: {:error, "#{label} must be a map"}

  defp turn_timeout(default_timeout, opts) do
    parse_timeout(opt(opts, :timeout_ms, default_timeout), "turn timeout_ms")
  end

  defp timeout_ms(opts, defaults) do
    parse_timeout(opt(opts, :timeout_ms, defaults.timeout_ms), "session timeout_ms")
  end

  defp parse_timeout(value, _label) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_timeout(_value, label), do: {:error, "#{label} must be a positive integer"}

  defp prompt_mode(opts, defaults) do
    parse_prompt_mode(opt(opts, :prompt_mode, defaults.prompt_mode), "session prompt_mode")
  end

  defp turn_prompt_mode(default_prompt_mode, opts) do
    parse_prompt_mode(opt(opts, :prompt_mode, default_prompt_mode), "turn prompt_mode")
  end

  defp parse_prompt_mode(value, _label) when value in [:stdin, :argv], do: {:ok, value}

  defp parse_prompt_mode(_value, label) do
    {:error, "#{label} must be :stdin or :argv"}
  end

  defp env_to_cmd_env(env), do: Enum.to_list(env)

  defp opt(opts, key, default) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end
end

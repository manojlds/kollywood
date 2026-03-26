defmodule Kollywood.Agent.CLI do
  @moduledoc false

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
      execute(session, args, prompt, prompt_mode, env, timeout_ms, raw_log)
    end
  end

  def run_turn(_session, _prompt, _opts),
    do: {:error, "Prompt must be a string and options must be a map"}

  @spec stop_session(Session.t()) :: :ok
  def stop_session(%Session{}), do: :ok

  defp execute(session, args, prompt, prompt_mode, env, timeout_ms, raw_log \\ nil) do
    {command, command_args, command_opts, cleanup} =
      command_invocation(session, args, prompt, prompt_mode, env, raw_log)

    try do
      started_at = System.monotonic_time(:millisecond)
      result = execute_with_timeout(command, command_args, command_opts, timeout_ms)

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

  defp command_invocation(session, args, prompt, :argv, env, raw_log)
       when is_binary(raw_log) do
    # Redirect stdin from /dev/null; tee -a captures raw stdout to log file as it streams.
    wrapper_args =
      [
        "-c",
        "set -o pipefail; \"$1\" \"${@:2}\" < /dev/null | tee -a \"$0\"",
        raw_log,
        session.command
      ] ++ args ++ [prompt]

    {"bash", wrapper_args, command_opts(session.workspace_path, env), fn -> :ok end}
  end

  defp command_invocation(session, args, prompt, :argv, env, _raw_log) do
    # Wrap with bash to redirect stdin from /dev/null — prevents CLI tools that
    # detect a pipe on stdin (e.g. claude) from waiting for input and polluting stdout.
    wrapper_args =
      ["-c", "exec \"$1\" \"${@:2}\" < /dev/null", "--", session.command] ++ args ++ [prompt]

    {"bash", wrapper_args, command_opts(session.workspace_path, env), fn -> :ok end}
  end

  defp command_invocation(session, args, prompt, :stdin, env, raw_log)
       when is_binary(raw_log) do
    prompt_file = prompt_file()
    File.write!(prompt_file, prompt)

    wrapper_args =
      [
        "-lc",
        "set -o pipefail; \"$2\" \"${@:3}\" < \"$1\" | tee -a \"$0\"",
        raw_log,
        prompt_file,
        session.command
      ] ++ args

    {"bash", wrapper_args, command_opts(session.workspace_path, env),
     fn -> File.rm(prompt_file) end}
  end

  defp command_invocation(session, args, prompt, :stdin, env, _raw_log) do
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

  defp execute_with_timeout(command, args, opts, timeout_ms) do
    task = Task.async(fn -> System.cmd(command, args, opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
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

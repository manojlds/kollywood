defmodule Kollywood.Runtime.Host do
  @moduledoc """
  Host runtime — executes commands directly on the machine.

  Uses devenv process lifecycle with port-offset isolation.
  """

  @behaviour Kollywood.Runtime

  require Logger
  @stop_retry_attempts 1
  @stop_retry_delay_ms 500
  @stop_output_preview_chars 240

  # ── Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(config, workspace) do
    runtime_config = config_section(config)

    base = %{
      kind: :host,
      profile: :full_stack,
      process_state: :pending,
      started?: false,
      command: nil,
      processes: [],
      env: %{},
      user_env: %{},
      port_bases: %{},
      resolved_ports: %{},
      port_offset: 0,
      port_offset_mod: 1000,
      port_offset_seed: 0,
      offset_lease_name: nil,
      start_timeout_ms: 120_000,
      stop_timeout_ms: 60_000,
      workspace_key: nil,
      workspace_identity: nil,
      workspace_path: nil
    }

    case workspace do
      nil ->
        base

      ws ->
        workspace_key = Map.get(ws, :key) || Path.basename(ws.path)
        workspace_path = ws.path
        workspace_identity = workspace_identity(workspace_key, workspace_path)

        user_env = env_map(field(runtime_config, :env))
        port_bases = ports_map(field(runtime_config, :ports))
        port_offset_mod = pos_int(field(runtime_config, :port_offset_mod), 1000)
        port_offset_seed = port_offset_seed(workspace_identity, port_offset_mod)
        resolved_ports = resolve_ports(port_bases, port_offset_seed)

        %{
          base
          | command: optional_string(field(runtime_config, :command)) || "devenv",
            processes: process_list(field(runtime_config, :processes)),
            env:
              build_env(workspace_key, workspace_path, user_env, port_offset_seed, resolved_ports),
            user_env: user_env,
            port_bases: port_bases,
            resolved_ports: resolved_ports,
            port_offset: port_offset_seed,
            port_offset_mod: port_offset_mod,
            port_offset_seed: port_offset_seed,
            start_timeout_ms: pos_int(field(runtime_config, :start_timeout_ms), 120_000),
            stop_timeout_ms: pos_int(field(runtime_config, :stop_timeout_ms), 60_000),
            workspace_key: workspace_key,
            workspace_identity: workspace_identity,
            workspace_path: workspace_path
        }
    end
  end

  @impl true
  def start(%{started?: true} = state), do: {:ok, state}

  def start(state) do
    with {:ok, state} <- ensure_isolation(state) do
      args = start_args(state)

      case execute(state.command, args, state.workspace_path, state.env, state.start_timeout_ms) do
        {:ok, _output, _ms} ->
          {:ok, %{state | started?: true, process_state: :running}}

        {:error, reason, _output, _ms} ->
          {:error, "failed to start runtime processes: #{reason}",
           %{state | process_state: :start_failed}}
      end
    else
      {:error, reason} ->
        {:error, "failed to start runtime processes: #{reason}",
         %{state | process_state: :isolation_failed}}
    end
  end

  @impl true
  def stop(state) do
    if stop_required?(state) do
      case stop_runtime_processes(state) do
        :ok ->
          {:ok, %{state | started?: false, process_state: :stopped} |> release()}

        {:error, reason} ->
          {:error, reason, %{state | process_state: :stop_failed} |> release()}
      end
    else
      {:ok, release(state)}
    end
  end

  @impl true
  def exec(state, command, timeout_ms) do
    execute("bash", ["-lc", command], state.workspace_path, %{}, timeout_ms)
  end

  @impl true
  def wrap_agent_command(_state, command, args) do
    {command, args, %{}}
  end

  @impl true
  def release(state) do
    case Map.get(state, :offset_lease_name) do
      nil ->
        state

      lease_name ->
        release_lease(lease_name)
        %{state | offset_lease_name: nil}
    end
  end

  # ── Port offset isolation ──────────────────────────────────────────

  defp ensure_isolation(%{offset_lease_name: name} = state) when not is_nil(name),
    do: {:ok, state}

  defp ensure_isolation(state) do
    modulus = pos_int(state.port_offset_mod, 1000)
    seed = port_offset_seed(state.workspace_identity, modulus)

    case acquire_lease(modulus, seed) do
      {:ok, offset, lease_name} ->
        resolved_ports = resolve_ports(state.port_bases, offset)

        env =
          build_env(
            state.workspace_key,
            state.workspace_path,
            state.user_env,
            offset,
            resolved_ports
          )

        {:ok,
         %{
           state
           | port_offset_seed: seed,
             port_offset: offset,
             resolved_ports: resolved_ports,
             env: env,
             offset_lease_name: lease_name
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp acquire_lease(modulus, seed) do
    0..(modulus - 1)
    |> Enum.reduce_while(:none, fn probe, _acc ->
      offset = rem(seed + probe, modulus)
      lease_name = {:kollywood, :runtime_port_offset, modulus, offset}

      case :global.register_name(lease_name, self()) do
        :yes -> {:halt, {:ok, offset, lease_name}}
        :no -> {:cont, :none}
      end
    end)
    |> case do
      {:ok, _, _} = ok -> ok
      :none -> {:error, "no available runtime port offsets within modulus #{modulus}"}
    end
  end

  defp release_lease(lease_name) do
    case :global.whereis_name(lease_name) do
      pid when pid == self() -> :global.unregister_name(lease_name)
      _other -> :ok
    end
  end

  # ── Command execution ─────────────────────────────────────────────

  defp execute(command, args, workspace_path, env, timeout_ms) do
    started_at_ms = System.monotonic_time(:millisecond)

    opts =
      [cd: workspace_path, stderr_to_stdout: true]
      |> maybe_put_env(env)

    try do
      task = Task.async(fn -> System.cmd(command, args, opts) end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} ->
          {:ok, output, elapsed(started_at_ms)}

        {:ok, {output, exit_code}} ->
          {:error, "exit code #{exit_code}", output, elapsed(started_at_ms)}

        nil ->
          {:error, "timed out after #{timeout_ms}ms", "", elapsed(started_at_ms)}
      end
    rescue
      error ->
        {:error, Exception.message(error), "", elapsed(started_at_ms)}
    end
  end

  defp maybe_put_env(opts, env) when map_size(env) == 0, do: opts
  defp maybe_put_env(opts, env), do: Keyword.put(opts, :env, Enum.to_list(env))

  defp elapsed(started_at_ms), do: max(System.monotonic_time(:millisecond) - started_at_ms, 0)

  # ── Process args ───────────────────────────────────────────────────

  defp start_args(state) do
    base = ["processes", "up", "--detach", "--strict-ports"]
    if state.processes == [], do: base, else: base ++ state.processes
  end

  defp stop_required?(state) do
    state.started? == true or state.process_state == :start_failed
  end

  defp stop_runtime_processes(state) do
    case stop_processes_once(state) do
      :ok ->
        :ok

      {:error, reason, output} ->
        if output_indicates_runtime_already_stopped?(output) do
          Logger.warning("runtime stop returned non-zero but appears already stopped: #{reason}")
          :ok
        else
          retry_stop_runtime_processes(state, reason, output)
        end
    end
  end

  defp stop_processes_once(state) do
    case execute(
           state.command,
           ["processes", "down"],
           state.workspace_path,
           state.env,
           state.stop_timeout_ms
         ) do
      {:ok, _output, _ms} ->
        :ok

      {:error, reason, output, _ms} ->
        {:error, reason, output}
    end
  end

  defp retry_stop_runtime_processes(state, first_reason, first_output) do
    Logger.warning("runtime stop failed (attempt 1); retrying once: #{first_reason}")

    1..@stop_retry_attempts
    |> Enum.reduce_while({:error, first_reason, first_output}, fn _attempt, _acc ->
      Process.sleep(@stop_retry_delay_ms)

      case stop_processes_once(state) do
        :ok ->
          {:halt, :ok}

        {:error, retry_reason, retry_output} ->
          if output_indicates_runtime_already_stopped?(retry_output) do
            Logger.warning(
              "runtime stop retry returned non-zero but appears already stopped: #{retry_reason}"
            )

            {:halt, :ok}
          else
            {:cont, {:error, retry_reason, retry_output}}
          end
      end
    end)
    |> case do
      :ok ->
        :ok

      {:error, last_reason, last_output} ->
        {:error,
         "failed to stop runtime processes after #{@stop_retry_attempts + 1} attempts " <>
           "(attempt1=#{format_stop_failure(first_reason, first_output)}; " <>
           "attempt#{@stop_retry_attempts + 1}=#{format_stop_failure(last_reason, last_output)})"}
    end
  end

  defp output_indicates_runtime_already_stopped?(output) when is_binary(output) do
    normalized =
      output
      |> String.downcase()
      |> String.trim()

    normalized != "" and
      Enum.any?(
        [
          "already stopped",
          "not running",
          "no running process",
          "no running processes",
          "no process to stop",
          "nothing to stop"
        ],
        &String.contains?(normalized, &1)
      )
  end

  defp output_indicates_runtime_already_stopped?(_output), do: false

  defp format_stop_failure(reason, output) do
    reason_text = optional_string(reason) || "unknown"

    output_text =
      output
      |> optional_string()
      |> case do
        nil ->
          nil

        value ->
          trimmed = String.trim(value)

          if trimmed == "" do
            nil
          else
            trimmed
            |> String.slice(0, @stop_output_preview_chars)
            |> String.replace("\n", "\\n")
          end
      end

    if output_text do
      "#{reason_text}; output=#{output_text}"
    else
      reason_text
    end
  end

  # ── Env / ports helpers ────────────────────────────────────────────

  defp build_env(workspace_key, workspace_path, user_env, port_offset, resolved_ports) do
    builtins = %{
      "KOLLYWOOD_RUNTIME_WORKTREE_KEY" => to_string(workspace_key),
      "KOLLYWOOD_RUNTIME_WORKTREE_PATH" => to_string(workspace_path),
      "KOLLYWOOD_RUNTIME_PORT_OFFSET" => Integer.to_string(port_offset)
    }

    port_env = Map.new(resolved_ports, fn {k, v} -> {k, Integer.to_string(v)} end)

    user_env |> Map.merge(builtins) |> Map.merge(port_env)
  end

  defp resolve_ports(port_bases, offset) do
    Map.new(port_bases, fn {key, base} -> {key, base + offset} end)
  end

  defp port_offset_seed(workspace_identity, modulus) do
    :erlang.phash2(to_string(workspace_identity), max(pos_int(modulus, 1000), 1))
  end

  defp workspace_identity(key, path) do
    optional_string(path) || optional_string(key) || "unknown-worktree"
  end

  # ── Config helpers ─────────────────────────────────────────────────

  defp config_section(config) do
    Map.get(config || %{}, :runtime) || %{}
  end

  defp process_list(value) when is_list(value) do
    value |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp process_list(_), do: []

  defp env_map(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp env_map(_), do: %{}

  defp ports_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, val}, acc ->
      case pos_int(val, nil) do
        parsed when is_integer(parsed) and parsed > 0 -> Map.put(acc, to_string(key), parsed)
        _ -> acc
      end
    end)
  end

  defp ports_map(_), do: %{}

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_, _), do: nil

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_), do: nil

  defp pos_int(value, _fallback) when is_integer(value) and value > 0, do: value

  defp pos_int(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp pos_int(_, fallback), do: fallback
end

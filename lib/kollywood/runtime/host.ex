defmodule Kollywood.Runtime.Host do
  @moduledoc """
  Host runtime — runs processes via pitchfork with per-issue isolation.

  Pitchfork manages daemon lifecycles (start, stop, ready checks, retries)
  as a background supervisor. Each workspace directory is a separate
  pitchfork namespace, providing natural isolation between concurrent runs.

  A `pitchfork.local.toml` is generated in each workspace with resolved
  environment variables (port offsets, workspace identity) before starting.
  """

  @behaviour Kollywood.Runtime

  require Logger

  @healthcheck_poll_interval_ms 250
  @healthcheck_connect_timeout_ms 250
  @healthcheck_skip_env "KOLLYWOOD_RUNTIME_SKIP_HEALTHCHECK"
  @runtime_managed_dir ".kollywood/runtime"
  @runtime_managed_pitchfork_local "pitchfork.local.toml"
  @runtime_managed_artifacts "artifacts"

  # ── Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(config, workspace) do
    runtime_config = config_section(config)

    base = %{
      kind: :host,
      profile: :full_stack,
      process_state: :pending,
      started?: false,
      command: "pitchfork",
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
          | processes: process_list(field(runtime_config, :processes)),
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
    with {:ok, state} <- ensure_isolation(state),
         :ok <- ensure_runtime_managed_dir(state) do
      case start_pitchfork(state) do
        {:ok, started_state} ->
          {:ok, %{started_state | started?: true, process_state: :running}}

        {:error, reason, failed_state} ->
          {:error, "failed to start runtime processes: #{reason}",
           %{failed_state | process_state: :start_failed}}
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
      case stop_pitchfork(state) do
        :ok ->
          {:ok,
           %{state | started?: false, process_state: :stopped}
           |> release()}

        {:error, reason} ->
          {:error, reason,
           %{state | process_state: :stop_failed}
           |> release()}
      end
    else
      {:ok, release(state)}
    end
  end

  @impl true
  def healthcheck(state) do
    if skip_healthcheck?(state) do
      :ok
    else
      await_runtime_ports(state)
    end
  end

  @impl true
  def ensure_exec_ready(state), do: {:ok, state}

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

  @impl true
  def reclaim_workspace(_state), do: :ok

  # ── Port offset isolation ──────────────────────────────────────────

  defp ensure_isolation(%{offset_lease_name: name} = state) when not is_nil(name),
    do: {:ok, state}

  defp ensure_isolation(state) do
    modulus = pos_int(state.port_offset_mod, 1000)
    seed = port_offset_seed(state.workspace_identity, modulus)

    case acquire_lease(modulus, seed, state.port_bases) do
      {:ok, offset, lease_name, resolved_ports} ->
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

  defp acquire_lease(modulus, seed, port_bases) do
    0..(modulus - 1)
    |> Enum.reduce_while(:none, fn probe, _acc ->
      offset = rem(seed + probe, modulus)
      lease_name = {:kollywood, :runtime_port_offset, modulus, offset}

      case :global.register_name(lease_name, self()) do
        :yes ->
          resolved_ports = resolve_ports(port_bases, offset)

          if ports_available?(resolved_ports) do
            {:halt, {:ok, offset, lease_name, resolved_ports}}
          else
            :global.unregister_name(lease_name)
            {:cont, :none}
          end

        :no ->
          {:cont, :none}
      end
    end)
    |> case do
      {:ok, _, _, _} = ok ->
        ok

      :none ->
        {:error,
         "no available runtime port offsets within modulus #{modulus} (ports occupied or leased)"}
    end
  end

  defp ports_available?(resolved_ports) when map_size(resolved_ports) == 0, do: true

  defp ports_available?(resolved_ports) do
    Enum.all?(resolved_ports, fn {_name, port} -> not runtime_port_open?(port) end)
  end

  defp release_lease(lease_name) do
    case :global.whereis_name(lease_name) do
      pid when pid == self() -> :global.unregister_name(lease_name)
      _other -> :ok
    end
  end

  # ── Command execution ─────────────────────────────────────────────

  @doc false
  def execute(command, args, workspace_path, env, timeout_ms) do
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

  # ── Pitchfork lifecycle ──────────────────────────────────────────

  defp start_pitchfork(%{processes: []} = state), do: {:ok, state}

  defp start_pitchfork(state) do
    with :ok <- write_pitchfork_local_toml(state) do
      cleanup_stale_daemons(state)

      args = ["start"] ++ state.processes

      case System.cmd("pitchfork", args,
             cd: state.workspace_path,
             env: string_env(state.env),
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          {:ok, state}

        {output, code} ->
          {:error, "pitchfork start failed (exit #{code}): #{String.trim(output)}", state}
      end
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  rescue
    error ->
      {:error, "pitchfork start error: #{Exception.message(error)}", state}
  end

  defp stop_pitchfork(%{processes: []}), do: :ok

  defp stop_pitchfork(state) do
    args = ["stop"] ++ state.processes

    case System.cmd("pitchfork", args,
           cd: state.workspace_path,
           stderr_to_stdout: true
         ) do
      {_output, code} when code in [0, 1] ->
        :ok

      {output, code} ->
        {:error, "pitchfork stop failed (exit #{code}): #{String.trim(output)}"}
    end
  rescue
    _ -> :ok
  end

  defp stop_required?(state) do
    state.started? == true or state.process_state == :start_failed
  end

  defp write_pitchfork_local_toml(state) do
    path = runtime_managed_pitchfork_local_path(state.workspace_path)

    with {:ok, daemon_runs} <- daemon_run_map(state.workspace_path, state.processes),
         :ok <- File.rm(path) |> ignore_enoent(),
         :ok <- File.write(path, render_pitchfork_local(daemon_runs, state.env) <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, "failed to prepare pitchfork.local.toml: #{inspect(reason)}"}
    end
  end

  defp ensure_runtime_managed_dir(%{workspace_path: workspace_path})
       when is_binary(workspace_path) and workspace_path != "" do
    runtime_managed_dir = runtime_managed_dir_path(workspace_path)
    runtime_artifacts_dir = Path.join(runtime_managed_dir, @runtime_managed_artifacts)

    with :ok <- File.mkdir_p(runtime_artifacts_dir),
         :ok <- symlink_runtime_managed_pitchfork_local(workspace_path) do
      :ok
    else
      {:error, reason} ->
        {:error, "failed to prepare runtime managed directory: #{inspect(reason)}"}
    end
  end

  defp ensure_runtime_managed_dir(_state), do: :ok

  defp symlink_runtime_managed_pitchfork_local(workspace_path)
       when is_binary(workspace_path) and workspace_path != "" do
    workspace_pitchfork_local = Path.join(workspace_path, @runtime_managed_pitchfork_local)
    runtime_target = runtime_managed_pitchfork_local_link_target()
    expected_target = runtime_managed_pitchfork_local_path(workspace_path)

    case File.ln_s(runtime_target, workspace_pitchfork_local) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.read_link(workspace_pitchfork_local) do
          {:ok, existing_target} ->
            existing_expanded =
              Path.expand(existing_target, Path.dirname(workspace_pitchfork_local))

            if existing_expanded == expected_target do
              :ok
            else
              replace_runtime_managed_symlink(workspace_pitchfork_local, runtime_target)
            end

          _ ->
            replace_runtime_managed_symlink(workspace_pitchfork_local, runtime_target)
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp symlink_runtime_managed_pitchfork_local(_workspace_path), do: :ok

  defp replace_runtime_managed_symlink(workspace_pitchfork_local, runtime_target) do
    with :ok <- File.rm(workspace_pitchfork_local),
         :ok <- File.ln_s(runtime_target, workspace_pitchfork_local) do
      :ok
    end
  end

  defp runtime_managed_dir_path(workspace_path)
       when is_binary(workspace_path) and workspace_path != "" do
    Path.join(workspace_path, @runtime_managed_dir)
  end

  defp runtime_managed_dir_path(_workspace_path), do: nil

  defp runtime_managed_pitchfork_local_path(workspace_path)
       when is_binary(workspace_path) and workspace_path != "" do
    workspace_path
    |> runtime_managed_dir_path()
    |> Path.join(@runtime_managed_pitchfork_local)
  end

  defp runtime_managed_pitchfork_local_path(_workspace_path),
    do: @runtime_managed_pitchfork_local

  defp runtime_managed_pitchfork_local_link_target do
    Path.join(@runtime_managed_dir, @runtime_managed_pitchfork_local)
  end

  defp daemon_run_map(workspace_path, daemons) do
    pitchfork_path = Path.join(workspace_path, "pitchfork.toml")

    with {:ok, content} <- File.read(pitchfork_path) do
      runs = extract_daemon_runs(content)

      Enum.reduce_while(daemons, {:ok, %{}}, fn daemon, {:ok, acc} ->
        case Map.fetch(runs, daemon) do
          {:ok, run_value} ->
            {:cont, {:ok, Map.put(acc, daemon, normalize_daemon_run(run_value))}}

          :error ->
            {:halt, {:error, "missing run command for daemon #{daemon} in pitchfork.toml"}}
        end
      end)
    else
      {:error, reason} -> {:error, "unable to read pitchfork.toml: #{inspect(reason)}"}
    end
  end

  defp extract_daemon_runs(content) do
    regex =
      ~r/^\s*\[daemons\.([\w.-]+)\]\s*$([\s\S]*?)(?=^\s*\[|\z)/m

    Regex.scan(regex, content)
    |> Enum.reduce(%{}, fn [_full, daemon, body], acc ->
      case Regex.run(~r/^\s*run\s*=\s*(.+)\s*$/m, body) do
        [_match, run_value] -> Map.put(acc, daemon, String.trim(run_value))
        _ -> acc
      end
    end)
  end

  defp normalize_daemon_run(run_value) when is_binary(run_value) do
    trimmed = String.trim(run_value)
    decoded = unwrap_toml_string(trimmed)

    if shell_wrapper_needed?(decoded) and not shell_wrapped?(decoded) do
      inspect("bash -lc '#{shell_single_quote(decoded)}'")
    else
      trimmed
    end
  end

  defp normalize_daemon_run(run_value), do: run_value

  defp unwrap_toml_string(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      String.length(value) >= 2 and String.starts_with?(value, "\"") and
          String.ends_with?(value, "\"") ->
        value
        |> String.slice(1, String.length(value) - 2)
        |> String.replace("\\\"", "\"")

      String.length(value) >= 2 and String.starts_with?(value, "'") and
          String.ends_with?(value, "'") ->
        String.slice(value, 1, String.length(value) - 2)

      true ->
        value
    end
  end

  defp shell_wrapper_needed?(command) when is_binary(command) do
    String.contains?(command, "&&") or String.contains?(command, "||")
  end

  defp shell_wrapped?(command) when is_binary(command) do
    String.starts_with?(command, "bash -lc ") or String.starts_with?(command, "sh -lc ")
  end

  defp shell_single_quote(command) when is_binary(command) do
    String.replace(command, "'", "'\"'\"'")
  end

  defp render_pitchfork_local(daemon_runs, env) do
    env_entries =
      env
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k} = #{inspect(to_string(v))}" end)

    daemon_runs
    |> Enum.sort_by(fn {daemon, _run} -> daemon end)
    |> Enum.map_join("\n\n", fn {daemon, run_value} ->
      """
      [daemons.#{daemon}]
      run = #{run_value}

      [daemons.#{daemon}.env]
      #{env_entries}\
      """
    end)
  end

  defp ignore_enoent(:ok), do: :ok
  defp ignore_enoent({:error, :enoent}), do: :ok
  defp ignore_enoent(other), do: other

  defp cleanup_stale_daemons(state) do
    case System.cmd("pitchfork", ["status", "--json"],
           cd: state.workspace_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        System.cmd("pitchfork", ["stop"] ++ state.processes,
          cd: state.workspace_path,
          stderr_to_stdout: true
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp string_env(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  # ── Healthcheck ────────────────────────────────────────────────────

  defp await_runtime_ports(state) do
    port_entries =
      state
      |> Map.get(:resolved_ports, %{})
      |> Enum.reduce([], fn {name, value}, acc ->
        case pos_int(value, nil) do
          port when is_integer(port) and port > 0 -> [{to_string(name), port} | acc]
          _other -> acc
        end
      end)
      |> Enum.sort_by(fn {name, _port} -> name end)

    if port_entries == [] do
      :ok
    else
      deadline_ms = System.monotonic_time(:millisecond) + max(state.start_timeout_ms, 1)
      wait_for_ports(port_entries, deadline_ms)
    end
  end

  defp wait_for_ports([], _deadline_ms), do: :ok

  defp wait_for_ports(port_entries, deadline_ms) do
    pending =
      Enum.reject(port_entries, fn {_name, port} ->
        runtime_port_open?(port)
      end)

    cond do
      pending == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        {:error,
         "ports not reachable before timeout: " <>
           Enum.map_join(pending, ", ", fn {name, port} -> "#{name}=#{port}" end)}

      true ->
        Process.sleep(@healthcheck_poll_interval_ms)
        wait_for_ports(pending, deadline_ms)
    end
  end

  defp runtime_port_open?(port) when is_integer(port) and port > 0 do
    case :gen_tcp.connect(
           ~c"127.0.0.1",
           port,
           [:binary, active: false],
           @healthcheck_connect_timeout_ms
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp runtime_port_open?(_port), do: false

  defp skip_healthcheck?(state) do
    state
    |> Map.get(:env, %{})
    |> Map.get(@healthcheck_skip_env)
    |> truthy_env?()
  end

  defp truthy_env?(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    normalized in ["1", "true", "yes", "on"]
  end

  defp truthy_env?(_value), do: false

  # ── Env / ports helpers ────────────────────────────────────────────

  defp build_env(workspace_key, workspace_path, user_env, port_offset, resolved_ports) do
    builtins = %{
      "KOLLYWOOD_RUNTIME_WORKTREE_KEY" => to_string(workspace_key),
      "KOLLYWOOD_RUNTIME_WORKTREE_PATH" => to_string(workspace_path),
      "KOLLYWOOD_RUNTIME_PORT_OFFSET" => Integer.to_string(port_offset),
      "MISE_TRUSTED_CONFIG_PATHS" => to_string(workspace_path)
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

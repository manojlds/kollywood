defmodule Kollywood.Runtime.Host do
  @moduledoc """
  Host runtime — runs processes via devenv with per-issue isolation.

  Uses systemd-run on Linux for cgroup-based process tree management
  (guaranteed cleanup, no orphans). Falls back to setsid + direct
  process group kill on other platforms (macOS).
  """

  @behaviour Kollywood.Runtime

  require Logger

  @healthcheck_poll_interval_ms 250
  @healthcheck_connect_timeout_ms 250
  @healthcheck_skip_env "KOLLYWOOD_RUNTIME_SKIP_HEALTHCHECK"

  # ── Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(config, workspace) do
    runtime_config = config_section(config)

    base = %{
      kind: :host,
      profile: :full_stack,
      process_state: :pending,
      started?: false,
      process_wrapper: detect_wrapper(),
      systemd_unit: nil,
      command: "devenv",
      manager_port: nil,
      manager_os_pid: nil,
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
    with {:ok, state} <- ensure_isolation(state) do
      case start_devenv(state) do
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
      case stop_devenv(state) do
        :ok ->
          {:ok,
           %{
             state
             | started?: false,
               process_state: :stopped,
               manager_port: nil,
               manager_os_pid: nil,
               systemd_unit: nil
           }
           |> release()}

        {:error, reason} ->
          {:error, reason,
           %{state | process_state: :stop_failed, manager_port: nil, manager_os_pid: nil}
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

  defp devenv(args, workspace_path, env, timeout_ms) do
    execute("devenv", args, workspace_path, env, timeout_ms)
  end

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

  # ── Devenv lifecycle — dispatch ───────────────────────────────────

  defp start_devenv(state) do
    case state.process_wrapper do
      :systemd -> start_devenv_systemd(state)
      :direct -> start_devenv_direct(state)
    end
  end

  defp stop_devenv(state) do
    case state.process_wrapper do
      :systemd -> stop_devenv_systemd(state)
      :direct -> stop_devenv_direct(state)
    end
  end

  defp stop_required?(state) do
    state.started? == true or state.process_state == :start_failed
  end

  # ── Systemd lifecycle ─────────────────────────────────────────────

  defp start_devenv_systemd(state) do
    unit = systemd_unit_name(state.workspace_key)
    cleanup_stale_systemd_unit(unit)

    devenv_args = ["processes", "up", "--strict-ports"] ++ state.processes
    args = ["--user", "--scope", "--unit=#{unit}", "--", "devenv"] ++ devenv_args

    env_list =
      state.env
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("systemd-run")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          cd: state.workspace_path,
          env: env_list
        ]
      )

    os_pid = port_os_pid(port)

    Process.sleep(500)

    case check_port_alive(port) do
      :alive ->
        {:ok, %{state | manager_port: port, manager_os_pid: os_pid, systemd_unit: unit}}

      {:exited, exit_status} ->
        {:error, "systemd-run exited immediately with status #{exit_status}", state}
    end
  end

  defp stop_devenv_systemd(state) do
    unit = state.systemd_unit

    if unit do
      scope = "#{unit}.scope"

      case System.cmd("systemctl", ["--user", "stop", scope], stderr_to_stdout: true) do
        {_output, 0} ->
          close_manager_port(state)
          :ok

        {_output, _code} ->
          close_manager_port(state)

          if systemd_unit_inactive?(unit) do
            :ok
          else
            {:error, "failed to stop systemd scope #{scope}"}
          end
      end
    else
      close_manager_port(state)
      :ok
    end
  end

  defp systemd_unit_inactive?(unit) do
    case System.cmd("systemctl", ["--user", "is-active", "#{unit}.scope"], stderr_to_stdout: true) do
      {output, _} -> String.trim(output) in ["inactive", "failed", "not-found"]
    end
  rescue
    _ -> false
  end

  defp cleanup_stale_systemd_unit(unit) do
    scope = "#{unit}.scope"

    case System.cmd("systemctl", ["--user", "is-active", scope], stderr_to_stdout: true) do
      {output, _} ->
        if String.trim(output) in ["active", "activating"] do
          Logger.warning("cleaning up stale systemd unit #{scope}")
          System.cmd("systemctl", ["--user", "stop", scope], stderr_to_stdout: true)
          Process.sleep(200)
        end
    end
  rescue
    _ -> :ok
  end

  defp systemd_unit_name(workspace_key) do
    sanitized =
      workspace_key
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
      |> String.trim("-")
      |> String.slice(0, 64)

    "kollywood-rt-#{sanitized}"
  end

  # ── Direct lifecycle (fallback for macOS / no systemd) ────────────

  defp start_devenv_direct(state) do
    devenv_args = ["processes", "up", "--strict-ports"] ++ state.processes

    {executable, args} =
      case System.find_executable("setsid") do
        nil -> {System.find_executable("devenv"), devenv_args}
        setsid_path -> {setsid_path, ["devenv"] ++ devenv_args}
      end

    env_list =
      state.env
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          cd: state.workspace_path,
          env: env_list
        ]
      )

    os_pid = port_os_pid(port)

    Process.sleep(500)

    case check_port_alive(port) do
      :alive ->
        {:ok, %{state | manager_port: port, manager_os_pid: os_pid}}

      {:exited, exit_status} ->
        {:error, "devenv processes up exited immediately with status #{exit_status}", state}
    end
  end

  defp stop_devenv_direct(state) do
    devenv(["processes", "down"], state.workspace_path, state.env, state.stop_timeout_ms)
    close_manager_port(state)
    kill_process_group(state.manager_os_pid)
    :ok
  end

  # ── Shared process helpers ────────────────────────────────────────

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp check_port_alive(port) do
    receive do
      {^port, {:exit_status, status}} -> {:exited, status}
    after
      0 -> :alive
    end
  end

  defp close_manager_port(%{manager_port: port}) when is_port(port) do
    try do
      Port.close(port)
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp close_manager_port(_state), do: :ok

  defp kill_process_group(os_pid) when is_integer(os_pid) and os_pid > 0 do
    try do
      System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp kill_process_group(_), do: :ok

  # ── Wrapper detection ─────────────────────────────────────────────

  defp detect_wrapper do
    case :os.type() do
      {:unix, :linux} ->
        if System.find_executable("systemd-run") && systemd_user_available?() do
          :systemd
        else
          :direct
        end

      _ ->
        :direct
    end
  end

  defp systemd_user_available? do
    case System.cmd("systemctl", ["--user", "is-system-running"], stderr_to_stdout: true) do
      {output, _} -> String.trim(output) in ["running", "degraded"]
    end
  rescue
    _ -> false
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

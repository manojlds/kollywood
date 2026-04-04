defmodule Kollywood.Runtime.Docker do
  @moduledoc """
  Docker runtime — runs processes inside a container with mise + pitchfork.

  The container uses the kollywood-runtime image (Ubuntu + mise + pitchfork)
  with `--network host` so the port offset mechanism works identically to the
  Host runtime. Inside the container, pitchfork manages daemon lifecycles.

  Lifecycle:
    1. docker create  — container with workspace bind-mount, host networking, env
    2. docker start   — tini boots as PID 1
    3. docker exec    — pitchfork start <daemons>
    4. healthcheck    — TCP poll on host ports (same as Host runtime)
    5. stop           — pitchfork stop inside container, then docker stop + rm

  ## Smoke / integration tests

  Container lifecycle smoke coverage lives in `test/kollywood/runtime/docker_test.exs`
  under the `:docker_integration` tag. Those tests need a running Docker daemon and
  the `kollywood-runtime` image from `priv/docker/runtime/Dockerfile`. Run them with
  `mix test --include docker_integration` (the tag is excluded by default in
  `test/test_helper.exs`).
  """

  @behaviour Kollywood.Runtime

  alias Kollywood.Runtime.Host

  require Logger

  @default_image "kollywood-runtime:latest"
  @container_workspace "/workspace"
  @container_home "/home/runtime"
  @container_mise_installs "#{@container_home}/.local/share/mise/installs"
  @container_ready_poll_ms 500
  @container_ready_timeout_ms 30_000
  @mise_install_timeout_ms 600_000
  @healthcheck_poll_interval_ms 250
  @healthcheck_connect_timeout_ms 250
  @healthcheck_skip_env "KOLLYWOOD_RUNTIME_SKIP_HEALTHCHECK"

  # ── Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(config, workspace) do
    runtime_config = config_section(config)

    base = %{
      kind: :docker,
      profile: :full_stack,
      process_state: :pending,
      started?: false,
      command: "docker",
      image: Map.get(runtime_config, :image) || @default_image,
      container_id: nil,
      container_name: nil,
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
            image: optional_string(field(runtime_config, :image)) || @default_image,
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
    with {:ok, state} <- ensure_exec_ready(state),
         {:ok, state} <- await_container_ready(state),
         {:ok, state} <- mise_install_tools(state),
         {:ok, state} <- start_pitchfork_in_container(state) do
      {:ok, %{state | started?: true, process_state: :running}}
    else
      {:error, reason, failed_state} ->
        cleanup_container(failed_state)

        {:error, "failed to start docker runtime: #{reason}",
         %{failed_state | process_state: :start_failed}}

      {:error, reason} ->
        {:error, "failed to start docker runtime: #{reason}",
         %{state | process_state: :start_failed}}
    end
  end

  @impl true
  def stop(state) do
    if stop_required?(state) do
      stop_pitchfork_in_container(state)
      cleanup_container(state)

      {:ok,
       %{
         state
         | started?: false,
           process_state: :stopped,
           container_id: nil,
           container_name: nil
       }
       |> release()}
    else
      cleanup_container(state)
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
  def ensure_exec_ready(%{container_id: cid} = state) when is_binary(cid), do: {:ok, state}

  def ensure_exec_ready(state) do
    with {:ok, state} <- ensure_isolation(state),
         :ok <- write_pitchfork_local_toml(state),
         {:ok, state} <- create_container(state),
         {:ok, state} <- start_container(state) do
      {:ok, state}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, "failed to prepare docker container: #{reason}", state}

      {:error, reason, failed_state} ->
        cleanup_container(failed_state)
        {:error, "failed to prepare docker container: #{reason}", failed_state}

      {:error, reason} ->
        {:error, "failed to prepare docker container: #{reason}", state}
    end
  end

  @impl true
  def exec(state, command, timeout_ms) do
    Host.exec(state, command, timeout_ms)
  end

  @impl true
  def wrap_agent_command(state, command, args) do
    Host.wrap_agent_command(state, command, args)
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

  # ── Container lifecycle ────────────────────────────────────────────

  defp create_container(state) do
    name = container_name(state.workspace_key)

    cleanup_stale_container(name)

    env_args =
      state.env
      |> Map.put("HOME", @container_home)
      |> Map.put_new("LANG", "C.UTF-8")
      |> Map.put_new("LC_ALL", "C.UTF-8")
      |> Enum.flat_map(fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    args =
      [
        "create",
        "--name",
        name,
        "--network",
        "host",
        "--init",
        "--user",
        host_uid_gid(),
        "--tmpfs",
        "/tmp:exec",
        "-v",
        "#{state.workspace_path}:#{@container_workspace}:rw",
        "-v",
        "#{mise_installs_host_dir()}:#{@container_mise_installs}:rw",
        "-v",
        "#{mise_host_dir("downloads")}:#{@container_home}/.local/share/mise/downloads:rw",
        "-v",
        "#{mise_host_dir("cache")}:#{@container_home}/.cache/mise:rw"
      ] ++
        env_args ++
        [state.image]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {container_id, 0} ->
        {:ok, %{state | container_id: String.trim(container_id), container_name: name}}

      {output, code} ->
        {:error, "docker create failed (exit #{code}): #{String.trim(output)}", state}
    end
  end

  defp start_container(state) do
    case System.cmd("docker", ["start", state.container_id], stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, state}

      {output, code} ->
        {:error, "docker start failed (exit #{code}): #{String.trim(output)}", state}
    end
  end

  defp await_container_ready(state) do
    deadline = System.monotonic_time(:millisecond) + @container_ready_timeout_ms
    poll_container_ready(state, deadline)
  end

  defp poll_container_ready(state, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, "container did not become ready within #{@container_ready_timeout_ms}ms", state}
    else
      case System.cmd(
             "docker",
             ["exec", state.container_id, "pitchfork", "--version"],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          {:ok, state}

        _ ->
          Process.sleep(@container_ready_poll_ms)
          poll_container_ready(state, deadline)
      end
    end
  rescue
    _ ->
      Process.sleep(@container_ready_poll_ms)
      poll_container_ready(state, deadline)
  end

  defp mise_install_tools(state) do
    Logger.info("[docker] running mise install in #{state.workspace_path}")

    task =
      Task.async(fn ->
        System.cmd(
          "docker",
          [
            "exec",
            "-w",
            @container_workspace,
            state.container_id,
            "bash",
            "-lc",
            "mise install --yes 2>&1"
          ],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @mise_install_timeout_ms) || Task.shutdown(task) do
      {:ok, {_output, 0}} ->
        {:ok, state}

      {:ok, {output, code}} ->
        {:error,
         "mise install failed (exit #{code}): #{String.trim(output) |> String.slice(-500..-1//1)}",
         state}

      nil ->
        {:error, "mise install timed out after #{div(@mise_install_timeout_ms, 1000)}s", state}
    end
  rescue
    error ->
      {:error, "mise install failed: #{Exception.message(error)}", state}
  end

  defp start_pitchfork_in_container(state) do
    daemon_list = Enum.join(state.processes, " ")

    exec_args =
      [
        "exec",
        "-d",
        "-w",
        @container_workspace,
        state.container_id,
        "bash",
        "-lc",
        "pitchfork start #{daemon_list}"
      ]

    case System.cmd("docker", exec_args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, state}

      {output, code} ->
        {:error, "pitchfork start inside container failed (exit #{code}): #{String.trim(output)}",
         state}
    end
  end

  defp stop_pitchfork_in_container(%{container_id: nil}), do: :ok

  defp stop_pitchfork_in_container(%{container_id: cid} = state) do
    daemon_list = Enum.join(state.processes, " ")

    System.cmd(
      "docker",
      [
        "exec",
        "-w",
        @container_workspace,
        cid,
        "bash",
        "-lc",
        "pitchfork stop #{daemon_list}"
      ],
      stderr_to_stdout: true
    )

    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_container(%{container_id: nil}), do: :ok

  defp cleanup_container(%{container_id: cid}) do
    System.cmd("docker", ["stop", "-t", "10", cid], stderr_to_stdout: true)
    System.cmd("docker", ["rm", "-f", cid], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_stale_container(name) do
    case System.cmd("docker", ["inspect", "--format", "{{.State.Status}}", name],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        status = String.trim(output)
        Logger.warning("cleaning up stale container #{name} (status: #{status})")
        System.cmd("docker", ["stop", "-t", "5", name], stderr_to_stdout: true)
        System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp container_name(workspace_key) do
    sanitized =
      workspace_key
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_.-]/, "-")
      |> String.trim("-")
      |> String.slice(0, 64)

    "kollywood-rt-#{sanitized}"
  end

  defp host_uid_gid do
    uid = :os.cmd(~c"id -u") |> to_string() |> String.trim()
    gid = :os.cmd(~c"id -g") |> to_string() |> String.trim()
    "#{uid}:#{gid}"
  end

  defp mise_installs_host_dir do
    Path.join([System.user_home!(), ".local", "share", "mise", "installs"])
  end

  defp mise_host_dir(subdir) do
    case subdir do
      "downloads" -> Path.join([System.user_home!(), ".local", "share", "mise", "downloads"])
      "cache" -> Path.join([System.user_home!(), ".cache", "mise"])
    end
  end

  defp stop_required?(state) do
    state.started? == true or state.process_state == :start_failed
  end

  defp write_pitchfork_local_toml(state) do
    path = Path.join(state.workspace_path || "", "pitchfork.local.toml")

    with {:ok, daemon_runs} <- daemon_run_map(state.workspace_path, state.processes),
         :ok <- File.rm(path) |> ignore_enoent(),
         :ok <- File.write(path, render_pitchfork_local(daemon_runs, state.env) <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, "failed to prepare pitchfork.local.toml: #{inspect(reason)}"}
    end
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

  # ── Port offset isolation (shared with Host) ──────────────────────

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
    value |> String.trim() |> String.downcase() |> Kernel.in(["1", "true", "yes", "on"])
  end

  defp truthy_env?(_value), do: false

  # ── Env / ports helpers ────────────────────────────────────────────

  defp build_env(workspace_key, workspace_path, user_env, port_offset, resolved_ports) do
    builtins = %{
      "KOLLYWOOD_RUNTIME_WORKTREE_KEY" => to_string(workspace_key),
      "KOLLYWOOD_RUNTIME_WORKTREE_PATH" => to_string(workspace_path),
      "KOLLYWOOD_RUNTIME_PORT_OFFSET" => Integer.to_string(port_offset),
      "MISE_TRUSTED_CONFIG_PATHS" => @container_workspace
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

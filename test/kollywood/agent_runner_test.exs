defmodule Kollywood.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias Kollywood.AgentRunner
  alias Kollywood.Config

  @no_hooks %{after_create: nil, before_run: nil, after_run: nil, before_remove: nil}

  @issue %{
    id: "ISS-1",
    identifier: "ABC-123",
    title: "Implement Stage 4 runner",
    description: "Add turn loop"
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_agent_runner_test_#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(root, "workspaces")
    cli_path = Path.join(root, "fake_runner_cli.sh")
    review_cli_path = Path.join(root, "fake_review_cli.sh")
    prompt_log = Path.join(root, "prompts.log")

    File.mkdir_p!(root)

    File.write!(cli_path, """
    #!/usr/bin/env bash
    set -eu

    prompt="$(cat)"

    if [ -n "${PROMPT_LOG_FILE:-}" ]; then
      printf "PROMPT<<%s>>\n" "$prompt" >> "$PROMPT_LOG_FILE"
    fi

    if [ -n "${FAIL_PROMPT_CONTAINS:-}" ]; then
      case "$prompt" in
        *"$FAIL_PROMPT_CONTAINS"*)
          echo "forced failure"
          exit 55
          ;;
      esac
    fi

    echo "ok:$prompt"
    """)

    File.chmod!(cli_path, 0o755)

    File.write!(review_cli_path, """
    #!/usr/bin/env bash
    set -eu

    prompt="$(cat)"

    if [ -n "${REVIEW_PROMPT_LOG_FILE:-}" ]; then
      printf "REVIEW_PROMPT<<%s>>\n" "$prompt" >> "$REVIEW_PROMPT_LOG_FILE"
    fi

    if [ -n "${REVIEW_FAIL_ONCE_FILE:-}" ]; then
      if [ ! -f "$REVIEW_FAIL_ONCE_FILE" ]; then
        touch "$REVIEW_FAIL_ONCE_FILE"
        echo "REVIEW_FAIL: address review feedback"
        echo "reviewed:$prompt"
        exit 0
      fi
    fi

    verdict="${REVIEW_VERDICT:-REVIEW_PASS}"
    echo "$verdict"
    echo "reviewed:$prompt"
    """)

    File.chmod!(review_cli_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{
      root: root,
      workspace_root: workspace_root,
      cli_path: cli_path,
      review_cli_path: review_cli_path,
      prompt_log: prompt_log
    }
  end

  test "runs a single turn and emits events in order", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config = runner_config(workspace_root, cli_path, prompt_log)
    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.status == :ok
    assert result.turn_count == 1
    assert result.workspace_path == Path.join(workspace_root, @issue.identifier)
    assert result.last_output =~ "ok:Work on ABC-123"

    assert Enum.map(result.events, & &1.type) == [
             :run_started,
             :workspace_ready,
             :session_started,
             :turn_started,
             :turn_succeeded,
             :session_stopped,
             :quality_cycle_started,
             :quality_cycle_passed,
             :publish_skipped,
             :run_finished
           ]
  end

  test "appends verification section to initial prompt when checks are required", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{
        required: ["test -d .", "pwd >/dev/null"],
        timeout_ms: 10_000,
        fail_fast: true
      })

    template = "Work on {{ issue.identifier }}"

    assert {:ok, _result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    prompt_history = File.read!(prompt_log)
    assert prompt_history =~ "## Verification"

    assert prompt_history =~
             "Run these commands to verify your changes before finishing:\n- `test -d .`\n- `pwd >/dev/null`"
  end

  test "omits verification section from initial prompt when checks are empty", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config = runner_config(workspace_root, cli_path, prompt_log)
    template = "Work on {{ issue.identifier }}"

    assert {:ok, _result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    prompt_history = File.read!(prompt_log)
    refute prompt_history =~ "## Verification"
  end

  test "fails when before_run hook fails", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config = runner_config(workspace_root, cli_path, prompt_log, %{before_run: "exit 9"})
    template = "Work on {{ issue.identifier }}"

    assert {:error, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.status == :failed
    assert result.turn_count == 0
    assert result.error =~ "before_run hook exited with code 9"
    assert :turn_failed in Enum.map(result.events, & &1.type)
  end

  test "ignores after_run hook failures", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config = runner_config(workspace_root, cli_path, prompt_log, %{after_run: "exit 1"})
    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.status == :ok
    assert result.turn_count == 1
  end

  test "stops at max_turns in max_turns mode", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config = runner_config(workspace_root, cli_path, prompt_log, %{}, %{max_turns: 3})
    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :max_turns
             )

    assert result.status == :max_turns_reached
    assert result.turn_count == 3
    assert result.last_output =~ "continuation turn #3"

    prompt_history = File.read!(prompt_log)
    assert prompt_history =~ "PROMPT<<Work on ABC-123>>"
    assert prompt_history =~ "continuation turn #2"
    assert prompt_history =~ "continuation turn #3"
  end

  test "stops session when a later turn fails", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config =
      runner_config(workspace_root, cli_path, prompt_log, %{}, %{
        max_turns: 4,
        env: %{"FAIL_PROMPT_CONTAINS" => "continuation turn #2"}
      })

    template = "Work on {{ issue.identifier }}"

    assert {:error, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :max_turns
             )

    assert result.status == :failed
    assert result.turn_count == 2
    assert result.error =~ "forced failure"
    assert Enum.take(Enum.map(result.events, & &1.type), -2) == [:session_stopped, :run_finished]
  end

  test "fails when a required check command fails", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{
        required: ["echo preflight", "exit 7"],
        timeout_ms: 10_000,
        fail_fast: true
      })

    template = "Work on {{ issue.identifier }}"

    assert {:error, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.error =~ "required checks failed"
    assert result.error =~ "exit code 7"
    assert :check_failed in Enum.map(result.events, & &1.type)
    assert :checks_failed in Enum.map(result.events, & &1.type)
  end

  test "passes required check commands on successful turn", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{
        required: ["test -d .", "pwd >/dev/null"],
        timeout_ms: 10_000,
        fail_fast: true
      })

    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.status == :ok
    assert :checks_started in Enum.map(result.events, & &1.type)
    assert :check_passed in Enum.map(result.events, & &1.type)
    assert :checks_passed in Enum.map(result.events, & &1.type)
  end

  test "checks_only profile runs checks without starting runtime processes", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_checks_only.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{required: ["test -d ."], timeout_ms: 10_000, fail_fast: true})
      |> Map.put(:runtime, full_stack_runtime(:checks_only, fake_devenv, fake_devenv_log))

    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.status == :ok
    refute :runtime_started in Enum.map(result.events, & &1.type)
    refute File.exists?(fake_devenv_log)
  end

  test "full_stack profile starts isolated runtime and runs checks in devenv shell", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_full_stack.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{
        required: [
          "test \"$RUNTIME_SENTINEL\" = \"ok\"",
          "test \"$KOLLYWOOD_RUNTIME_PROFILE\" = \"full_stack\"",
          "test -n \"$APP_PORT\""
        ],
        timeout_ms: 10_000,
        fail_fast: true
      })
      |> Map.put(:runtime, full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log))

    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    event_types = Enum.map(result.events, & &1.type)
    assert :runtime_starting in event_types
    assert :runtime_started in event_types
    assert :runtime_stopping in event_types
    assert :runtime_stopped in event_types

    log = File.read!(fake_devenv_log)
    assert log =~ "processes up --detach --strict-ports server"
    assert log =~ "shell -- bash -lc test \"$RUNTIME_SENTINEL\" = \"ok\""
    assert log =~ "processes down"
  end

  test "full_stack runtime is stopped when checks fail", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_fail.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{required: ["exit 3"], timeout_ms: 10_000, fail_fast: true})
      |> Map.put(:runtime, full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log))

    template = "Work on {{ issue.identifier }}"

    assert {:error, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.error =~ "required checks failed"

    event_types = Enum.map(result.events, & &1.type)
    assert :runtime_started in event_types
    assert :runtime_stopped in event_types

    log = File.read!(fake_devenv_log)
    assert log =~ "processes up --detach --strict-ports server"
    assert log =~ "processes down"
  end

  test "full_stack runtime attempts shutdown after startup failure", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_start_fail.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    runtime =
      full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log)
      |> put_in([:full_stack, :env, "FAKE_DEVENV_FAIL_UP"], "1")

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{required: ["test -d ."], timeout_ms: 10_000, fail_fast: true})
      |> Map.put(:runtime, runtime)

    template = "Work on {{ issue.identifier }}"

    assert {:error, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.error =~ "failed to start runtime processes"

    event_types = Enum.map(result.events, & &1.type)
    assert :runtime_start_failed in event_types
    assert :runtime_stopping in event_types
    assert :runtime_stopped in event_types

    log = File.read!(fake_devenv_log)
    assert log =~ "processes up --detach --strict-ports server"
    assert log =~ "processes down"
  end

  test "full_stack runtime identity env cannot be overridden by user env", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_identity.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)
    expected_workspace_path = Path.join(workspace_root, @issue.identifier)

    runtime =
      full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log)
      |> put_in([:full_stack, :env, "KOLLYWOOD_RUNTIME_WORKTREE_KEY"], "tampered-key")
      |> put_in([:full_stack, :env, "KOLLYWOOD_RUNTIME_WORKTREE_PATH"], "/tmp/tampered-path")

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{
        required: [
          "test \"$KOLLYWOOD_RUNTIME_WORKTREE_KEY\" = \"#{@issue.identifier}\"",
          "test \"$KOLLYWOOD_RUNTIME_WORKTREE_PATH\" = \"#{expected_workspace_path}\""
        ],
        timeout_ms: 10_000,
        fail_fast: true
      })
      |> Map.put(:runtime, runtime)

    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.status == :ok
  end

  test "full_stack runtime fails fast when no isolated port offset is available", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_offset_exhausted.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    runtime =
      full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log)
      |> put_in([:full_stack, :port_offset_mod], 1)

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{required: ["sleep 1"], timeout_ms: 10_000, fail_fast: true})
      |> Map.put(:runtime, runtime)

    template = "Work on {{ issue.identifier }}"

    first_issue = %{@issue | id: "ISS-ISO-1", identifier: "ISO-1"}
    second_issue = %{@issue | id: "ISS-ISO-2", identifier: "ISO-2"}
    parent = self()

    first_task =
      Task.async(fn ->
        AgentRunner.run_issue(first_issue,
          config: config,
          prompt_template: template,
          mode: :single_turn,
          on_event: fn event ->
            if event.type == :runtime_started do
              send(parent, {:runtime_started, first_issue.id})
            end
          end
        )
      end)

    assert_receive {:runtime_started, "ISS-ISO-1"}, 5_000

    second_task =
      Task.async(fn ->
        AgentRunner.run_issue(second_issue,
          config: config,
          prompt_template: template,
          mode: :single_turn
        )
      end)

    assert {:error, second_result} = Task.await(second_task, 10_000)
    assert second_result.error =~ "no available runtime port offsets"
    assert :runtime_start_failed in Enum.map(second_result.events, & &1.type)
    refute :runtime_stopping in Enum.map(second_result.events, & &1.type)

    assert {:ok, first_result} = Task.await(first_task, 15_000)
    assert first_result.status == :ok
  end

  test "runs config-enabled review round and passes on REVIEW_PASS", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    review_cli_path: review_cli_path,
    prompt_log: prompt_log
  } do
    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:review, %{
        enabled: true,
        pass_token: "REVIEW_PASS",
        fail_token: "REVIEW_FAIL",
        agent: %{
          explicit: true,
          kind: :pi,
          command: review_cli_path,
          args: [],
          env: %{"REVIEW_VERDICT" => "REVIEW_PASS"},
          timeout_ms: 10_000
        }
      })

    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.status == :ok
    assert :quality_cycle_started in Enum.map(result.events, & &1.type)
    assert :quality_cycle_passed in Enum.map(result.events, & &1.type)
    assert :review_started in Enum.map(result.events, & &1.type)
    assert :review_passed in Enum.map(result.events, & &1.type)
  end

  test "retries with remediation turn when review fails before max cycles", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    review_cli_path: review_cli_path,
    prompt_log: prompt_log
  } do
    fail_once_file = Path.join(root, "review_fail_once.marker")

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:review, %{
        enabled: true,
        max_cycles: 2,
        pass_token: "REVIEW_PASS",
        fail_token: "REVIEW_FAIL",
        agent: %{
          explicit: true,
          kind: :pi,
          command: review_cli_path,
          args: [],
          env: %{"REVIEW_FAIL_ONCE_FILE" => fail_once_file},
          timeout_ms: 10_000
        }
      })

    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.status == :ok
    assert result.turn_count == 2
    assert :quality_cycle_retrying in Enum.map(result.events, & &1.type)
    assert :review_failed in Enum.map(result.events, & &1.type)
    assert :review_passed in Enum.map(result.events, & &1.type)

    prompt_history = File.read!(prompt_log)
    assert prompt_history =~ "Work on ABC-123"
    assert prompt_history =~ "Reviewer feedback from cycle 1"
  end

  test "fails run when review verdict is REVIEW_FAIL", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    review_cli_path: review_cli_path,
    prompt_log: prompt_log
  } do
    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:review, %{
        enabled: true,
        pass_token: "REVIEW_PASS",
        fail_token: "REVIEW_FAIL",
        agent: %{
          explicit: true,
          kind: :pi,
          command: review_cli_path,
          args: [],
          env: %{"REVIEW_VERDICT" => "REVIEW_FAIL: missing regression test"},
          timeout_ms: 10_000
        }
      })

    template = "Work on {{ issue.identifier }}"

    assert {:error, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.error =~ "review failed after 1 cycle"
    assert result.error =~ "missing regression test"
    assert :review_failed in Enum.map(result.events, & &1.type)
  end

  defp runner_config(workspace_root, cli_path, prompt_log, hooks \\ %{}, agent_overrides \\ %{}) do
    hooks = Map.merge(@no_hooks, hooks)

    base_agent = %{
      kind: :amp,
      max_concurrent_agents: 2,
      max_turns: 3,
      command: cli_path,
      args: [],
      env: %{"PROMPT_LOG_FILE" => prompt_log},
      timeout_ms: 10_000
    }

    agent =
      base_agent
      |> Map.merge(Map.delete(agent_overrides, :env))
      |> Map.update!(:env, &Map.merge(&1, Map.get(agent_overrides, :env, %{})))

    %Config{
      tracker: %{},
      polling: %{},
      workspace: %{root: workspace_root, strategy: :clone},
      hooks: hooks,
      checks: %{required: [], timeout_ms: 10_000, fail_fast: true},
      runtime: %{
        profile: :checks_only,
        full_stack: %{
          command: "devenv",
          processes: [],
          env: %{},
          ports: %{},
          port_offset_mod: 1000,
          start_timeout_ms: 120_000,
          stop_timeout_ms: 60_000
        }
      },
      review: %{enabled: false, max_cycles: 1, agent: %{kind: agent.kind}},
      agent: agent,
      raw: %{}
    }
  end

  defp full_stack_runtime(profile, command, log_path) do
    %{
      profile: profile,
      full_stack: %{
        command: command,
        processes: ["server"],
        env: %{
          "FAKE_DEVENV_LOG" => log_path,
          "RUNTIME_SENTINEL" => "ok"
        },
        ports: %{"APP_PORT" => 4100},
        port_offset_mod: 1000,
        start_timeout_ms: 10_000,
        stop_timeout_ms: 10_000
      }
    }
  end

  defp write_fake_devenv!(root, log_path) do
    path = Path.join(root, "fake_devenv.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    set -eu

    if [ -n "${FAKE_DEVENV_LOG:-}" ]; then
      printf "PWD:%s\\n" "$PWD" >> "$FAKE_DEVENV_LOG"
      printf "ENV:KEY=%s PATH=%s OFFSET=%s APP_PORT=%s\\n" "${KOLLYWOOD_RUNTIME_WORKTREE_KEY:-}" "${KOLLYWOOD_RUNTIME_WORKTREE_PATH:-}" "${KOLLYWOOD_RUNTIME_PORT_OFFSET:-}" "${APP_PORT:-}" >> "$FAKE_DEVENV_LOG"
      printf "CMD:%s\\n" "$*" >> "$FAKE_DEVENV_LOG"
    fi

    if [ "${1:-}" = "shell" ]; then
      shift

      if [ "${1:-}" = "--" ]; then
        shift
      fi

      "$@"
      exit $?
    fi

    if [ "${1:-}" = "processes" ] && [ "${2:-}" = "up" ]; then
      if [ "${FAKE_DEVENV_FAIL_UP:-}" = "1" ]; then
        echo "forced up failure" >&2
        exit 52
      fi

      exit 0
    fi

    if [ "${1:-}" = "processes" ] && [ "${2:-}" = "down" ]; then
      exit 0
    fi

    echo "unexpected fake devenv invocation: $*" >&2
    exit 41
    """)

    File.chmod!(path, 0o755)
    File.rm(log_path)
    path
  end
end

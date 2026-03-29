defmodule Kollywood.AgentRunnerTest do
  use ExUnit.Case, async: false

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
    testing_cli_path = Path.join(root, "fake_testing_cli.sh")
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

    # Extract review.json path from prompt
    review_json_path=$(printf '%s' "$prompt" | grep -oP 'Write your review to `\\K[^`]+' || echo "/tmp/review_fallback.json")

    write_review_json() {
      payload="$1"
      if [ -n "${REVIEW_APPEND_MODE:-}" ]; then
        printf '%s' "$payload" >> "$review_json_path"
      else
        printf '%s' "$payload" > "$review_json_path"
      fi
    }

    if [ -n "${REVIEW_INVALID_JSON_ONCE_FILE:-}" ]; then
      if [ ! -f "$REVIEW_INVALID_JSON_ONCE_FILE" ]; then
        touch "$REVIEW_INVALID_JSON_ONCE_FILE"
        write_review_json '{"verdict":"pass","summary":"review complete","findings":[]}
    {"verdict":"fail","summary":"stale reviewer output","findings":[{"severity":"critical","description":"stale review appended"}]}'
        exit 0
      fi
    fi

    if [ -n "${REVIEW_FAIL_ONCE_FILE:-}" ]; then
      if [ ! -f "$REVIEW_FAIL_ONCE_FILE" ]; then
        touch "$REVIEW_FAIL_ONCE_FILE"
        write_review_json '{"verdict":"fail","summary":"address review feedback","findings":[{"severity":"critical","description":"missing regression test"}]}'
        exit 0
      fi
    fi

    verdict="${REVIEW_VERDICT:-pass}"
    write_review_json "$(printf '{"verdict":"%s","summary":"review complete","findings":[]}' "$verdict")"
    """)

    File.chmod!(review_cli_path, 0o755)

    File.write!(testing_cli_path, """
    #!/usr/bin/env bash
    set -eu

    prompt=""

    if [ "$#" -gt 0 ]; then
      prompt="${@: -1}"
    else
      prompt="$(cat)"
    fi

    if [ -n "${TESTING_PROMPT_LOG_FILE:-}" ]; then
      printf "TESTING_PROMPT<<%s>>\n" "$prompt" >> "$TESTING_PROMPT_LOG_FILE"
    fi

    testing_json_path=$(printf '%s' "$prompt" | grep -oP 'Write your testing report to `\\K[^`]+' || true)

    if [ -z "$testing_json_path" ]; then
      testing_json_path="/tmp/testing_fallback.json"
    fi

    write_testing_json() {
      payload="$1"

      if [ -n "${TESTING_APPEND_MODE:-}" ]; then
        printf '%s' "$payload" >> "$testing_json_path"
      else
        printf '%s' "$payload" > "$testing_json_path"
      fi
    }

    write_artifact_file() {
      artifact_path="$1"
      mkdir -p "$(dirname "$artifact_path")"
      printf 'artifact' > "$artifact_path"
    }

    if [ -n "${TESTING_FAIL_ONCE_FILE:-}" ]; then
      if [ ! -f "$TESTING_FAIL_ONCE_FILE" ]; then
        touch "$TESTING_FAIL_ONCE_FILE"
        write_artifact_file "artifacts/testing-remediation-failure.png"
        write_testing_json '{"verdict":"fail","summary":"address testing feedback","checkpoints":[{"name":"smoke","status":"fail","details":"endpoint returned 500"}],"artifacts":[{"kind":"screenshot","path":"artifacts/testing-remediation-failure.png"},{"kind":"replay","path":"https://agent-browser.local/replays/testing-remediation"}]}'
        echo "testing failed once"
        exit 0
      fi
    fi

    if [ -n "${TESTING_SLEEP_SECS:-}" ]; then
      sleep "$TESTING_SLEEP_SECS"
    fi

    verdict="${TESTING_VERDICT:-pass}"

    if [ "$verdict" = "fail" ]; then
      write_artifact_file "artifacts/testing-failure.png"
      write_artifact_file "artifacts/testing-failure.webm"
      write_testing_json '{"verdict":"fail","summary":"testing failed","checkpoints":[{"name":"smoke","status":"fail","details":"runtime check failed"}],"artifacts":[{"kind":"screenshot","path":"artifacts/testing-failure.png"},{"kind":"video","path":"artifacts/testing-failure.webm"},{"kind":"replay","path":"https://agent-browser.local/replays/testing-failure"}]}'
      echo "testing failed"
      exit 0
    else
      write_artifact_file "artifacts/testing-success.png"
      write_artifact_file "artifacts/testing-success.webm"
      write_testing_json '{"verdict":"pass","summary":"testing complete","checkpoints":[{"name":"smoke","status":"pass","details":"runtime check passed"}],"artifacts":[{"kind":"screenshot","path":"artifacts/testing-success.png"},{"kind":"video","path":"artifacts/testing-success.webm"},{"kind":"replay","path":"https://agent-browser.local/replays/testing-success"}]}'
      echo "testing passed"
    fi
    """)

    File.chmod!(testing_cli_path, 0o755)

    git_cli_path = Path.join(root, "fake_git_runner_cli.sh")

    File.write!(git_cli_path, """
    #!/usr/bin/env bash
    set -eu

    prompt="$(cat)"
    printf "%s\n" "$prompt" > agent_output.txt
    printf "%s\n" "${RANDOM:-0}" >> agent_output.txt

    git add agent_output.txt
    git commit -m "agent commit" >/dev/null

    echo "ok:$prompt"
    """)

    File.chmod!(git_cli_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{
      root: root,
      workspace_root: workspace_root,
      cli_path: cli_path,
      git_cli_path: git_cli_path,
      review_cli_path: review_cli_path,
      testing_cli_path: testing_cli_path,
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

  test "fail-fast checks stop after the first failing command", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{
        required: ["exit 3", "exit 7"],
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
    assert result.error =~ "check #1 failed (exit 3): exit code 3"
    refute result.error =~ "check #2 failed"

    checks_started_event = Enum.find(result.events, &(&1.type == :checks_started))
    assert checks_started_event.fail_fast == true

    check_started_events = Enum.filter(result.events, &(&1.type == :check_started))
    assert length(check_started_events) == 1

    check_failed_events = Enum.filter(result.events, &(&1.type == :check_failed))
    assert length(check_failed_events) == 1
  end

  test "disabled fail-fast checks report every failing command in one cycle", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:checks, %{
        required: ["exit 3", "exit 7"],
        timeout_ms: 10_000,
        fail_fast: false
      })

    template = "Work on {{ issue.identifier }}"

    assert {:error, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.error =~ "required checks failed"
    assert result.error =~ "check #1 failed (exit 3): exit code 3"
    assert result.error =~ "check #2 failed (exit 7): exit code 7"

    checks_started_event = Enum.find(result.events, &(&1.type == :checks_started))
    assert checks_started_event.fail_fast == false

    check_started_events = Enum.filter(result.events, &(&1.type == :check_started))
    assert length(check_started_events) == 2

    check_failed_events = Enum.filter(result.events, &(&1.type == :check_failed))
    assert length(check_failed_events) == 2
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

  test "checks run without starting runtime processes", %{
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

  test "checks do not run inside runtime shell even when runtime is configured", %{
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
          "test \"$RUNTIME_SENTINEL\" = \"ok\""
        ],
        timeout_ms: 10_000,
        fail_fast: true
      })
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
    refute :runtime_starting in event_types
    refute :runtime_started in event_types
    refute :runtime_stopping in event_types
    refute :runtime_stopped in event_types
    refute File.exists?(fake_devenv_log)
  end

  test "runtime is stopped when testing fails", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_fail.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:runtime, full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log))
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 1,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{"TESTING_VERDICT" => "fail"},
          timeout_ms: 10_000
        }
      })

    issue_with_testing =
      Map.put(@issue, :settings, %{"execution" => %{"testing_enabled" => true}})

    template = "Work on {{ issue.identifier }}"

    assert {:error, result} =
             AgentRunner.run_issue(issue_with_testing,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.error =~ "testing failed after 1 cycle"

    event_types = Enum.map(result.events, & &1.type)
    assert :runtime_started in event_types
    assert :runtime_stopped in event_types
    assert :testing_failed in event_types

    log = File.read!(fake_devenv_log)
    assert log =~ "processes up --detach --strict-ports server"
    assert log =~ "processes down"
  end

  test "runtime stop retries once on transient down failure", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_stop_retry.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)
    down_fail_once_file = Path.join(root, "devenv_down_fail_once.marker")

    runtime =
      full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log)
      |> put_in([:env, "FAKE_DEVENV_FAIL_DOWN_ONCE_FILE"], down_fail_once_file)

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:runtime, runtime)
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 1,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{"TESTING_VERDICT" => "pass"},
          timeout_ms: 10_000
        }
      })

    issue_with_testing =
      Map.put(@issue, :settings, %{"execution" => %{"testing_enabled" => true}})

    assert {:ok, result} =
             AgentRunner.run_issue(issue_with_testing,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn
             )

    event_types = Enum.map(result.events, & &1.type)
    assert :runtime_started in event_types
    assert :runtime_stopped in event_types
    refute :runtime_stop_failed in event_types

    down_count =
      fake_devenv_log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.count(&String.contains?(&1, "CMD:processes down"))

    assert down_count == 2
  end

  test "runtime attempts shutdown after startup failure during testing", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_start_fail.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    runtime =
      full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log)
      |> put_in([:env, "FAKE_DEVENV_FAIL_UP"], "1")

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:runtime, runtime)
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 1,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{},
          timeout_ms: 10_000
        }
      })

    issue_with_testing =
      Map.put(@issue, :settings, %{"execution" => %{"testing_enabled" => true}})

    template = "Work on {{ issue.identifier }}"

    assert {:error, result} =
             AgentRunner.run_issue(issue_with_testing,
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

  test "runtime identity env cannot be overridden by user env", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_identity.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)
    expected_workspace_path = Path.join(workspace_root, @issue.identifier)

    runtime =
      full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log)
      |> put_in([:env, "KOLLYWOOD_RUNTIME_WORKTREE_KEY"], "tampered-key")
      |> put_in([:env, "KOLLYWOOD_RUNTIME_WORKTREE_PATH"], "/tmp/tampered-path")

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:runtime, runtime)
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 1,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{"TESTING_VERDICT" => "pass"},
          timeout_ms: 10_000
        }
      })

    issue_with_testing =
      Map.put(@issue, :settings, %{"execution" => %{"testing_enabled" => true}})

    template = "Work on {{ issue.identifier }}"

    assert {:ok, result} =
             AgentRunner.run_issue(issue_with_testing,
               config: config,
               prompt_template: template,
               mode: :single_turn
             )

    assert result.status == :ok

    log = File.read!(fake_devenv_log)
    assert log =~ "ENV:KEY=#{@issue.identifier} PATH=#{expected_workspace_path}"
    refute log =~ "ENV:KEY=tampered-key"
    refute log =~ "PATH=/tmp/tampered-path"
  end

  test "runtime fails fast when no isolated port offset is available", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_offset_exhausted.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    runtime =
      full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log)
      |> put_in([:port_offset_mod], 1)

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:runtime, runtime)
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 1,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{
            "TESTING_VERDICT" => "pass",
            "TESTING_SLEEP_SECS" => "1"
          },
          timeout_ms: 10_000
        }
      })

    template = "Work on {{ issue.identifier }}"

    first_issue =
      @issue
      |> Map.merge(%{id: "ISS-ISO-1", identifier: "ISO-1"})
      |> Map.put(:settings, %{"execution" => %{"testing_enabled" => true}})

    second_issue =
      @issue
      |> Map.merge(%{id: "ISS-ISO-2", identifier: "ISO-2"})
      |> Map.put(:settings, %{"execution" => %{"testing_enabled" => true}})

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
        agent: %{
          explicit: true,
          kind: :pi,
          command: review_cli_path,
          args: [],
          env: %{"REVIEW_VERDICT" => "pass"},
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

  test "retries with remediation turn when reviewer emits malformed review.json", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    review_cli_path: review_cli_path,
    prompt_log: prompt_log
  } do
    invalid_json_once_file = Path.join(root, "review_invalid_json_once.marker")

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:review, %{
        enabled: true,
        max_cycles: 2,
        agent: %{
          explicit: true,
          kind: :pi,
          command: review_cli_path,
          args: [],
          env: %{"REVIEW_INVALID_JSON_ONCE_FILE" => invalid_json_once_file},
          timeout_ms: 10_000
        }
      })

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn
             )

    assert result.status == :ok
    assert result.turn_count == 2
    assert :quality_cycle_retrying in Enum.map(result.events, & &1.type)
    assert :review_failed in Enum.map(result.events, & &1.type)
    assert :review_passed in Enum.map(result.events, & &1.type)

    review_failed_event = Enum.find(result.events, &(&1.type == :review_failed))
    assert review_failed_event.reason =~ "failed to parse review.json"

    prompt_history = File.read!(prompt_log)
    assert prompt_history =~ "Reviewer feedback from cycle 1"
  end

  test "clears stale review.json before review to avoid concatenated outputs", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    review_cli_path: review_cli_path,
    prompt_log: prompt_log
  } do
    stale_review_json =
      Path.join([workspace_root, @issue.identifier, ".kollywood", "review.json"])

    File.mkdir_p!(Path.dirname(stale_review_json))
    File.write!(stale_review_json, "{\"verdict\":\"fail\",\"summary\":\"stale\",\"findings\":[]}")

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:review, %{
        enabled: true,
        agent: %{
          explicit: true,
          kind: :pi,
          command: review_cli_path,
          args: [],
          env: %{"REVIEW_APPEND_MODE" => "1", "REVIEW_VERDICT" => "pass"},
          timeout_ms: 10_000
        }
      })

    assert {:ok, result} =
             AgentRunner.run_issue(@issue,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn
             )

    assert result.status == :ok
    assert :review_passed in Enum.map(result.events, & &1.type)
    refute :review_failed in Enum.map(result.events, & &1.type)
  end

  test "applies story override for review_max_cycles during execution", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    review_cli_path: review_cli_path,
    prompt_log: prompt_log
  } do
    fail_once_file = Path.join(root, "review_fail_once_override.marker")

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:quality, %{
        max_cycles: 2,
        review: %{
          max_cycles: 1,
          agent: %{kind: :pi, explicit: true}
        }
      })
      |> Map.put(:review, %{
        enabled: true,
        max_cycles: 1,
        agent: %{
          explicit: true,
          kind: :pi,
          command: review_cli_path,
          args: [],
          env: %{"REVIEW_FAIL_ONCE_FILE" => fail_once_file},
          timeout_ms: 10_000
        }
      })

    issue_with_overrides =
      Map.put(@issue, :settings, %{
        "execution" => %{
          "review_max_cycles" => 2
        }
      })

    assert {:ok, result} =
             AgentRunner.run_issue(issue_with_overrides,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn
             )

    assert result.status == :ok
    assert result.turn_count == 2
    assert :quality_cycle_retrying in Enum.map(result.events, & &1.type)
    assert :review_failed in Enum.map(result.events, & &1.type)
    assert :review_passed in Enum.map(result.events, & &1.type)
  end

  test "rejects invalid story execution overrides before starting the run", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    prompt_log: prompt_log
  } do
    config = runner_config(workspace_root, cli_path, prompt_log)

    issue_with_invalid_overrides =
      Map.put(@issue, :settings, %{
        "execution" => %{
          "agent_kind" => "not-a-valid-kind"
        }
      })

    assert {:error, result} =
             AgentRunner.run_issue(issue_with_invalid_overrides,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn
             )

    assert result.error =~ "invalid story execution settings"
    assert result.error =~ "agent_kind"
    assert result.events == []
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
        agent: %{
          explicit: true,
          kind: :pi,
          command: review_cli_path,
          args: [],
          env: %{"REVIEW_VERDICT" => "fail"},
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
    assert result.error =~ "review complete"
    assert :review_failed in Enum.map(result.events, & &1.type)
  end

  test "runs testing phase with runtime and emits checkpoint events", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_testing.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:quality, %{max_cycles: 2})
      |> Map.put(:runtime, full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log))
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 1,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{"TESTING_VERDICT" => "pass"},
          timeout_ms: 10_000
        }
      })

    issue_with_testing =
      Map.put(@issue, :settings, %{"execution" => %{"testing_enabled" => true}})

    assert {:ok, result} =
             AgentRunner.run_issue(issue_with_testing,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn
             )

    assert result.status == :ok

    event_types = Enum.map(result.events, & &1.type)
    assert :testing_started in event_types
    assert :testing_checkpoint in event_types
    assert :testing_passed in event_types
    assert :runtime_started in event_types
    assert :runtime_stopped in event_types

    testing_json = Path.join([workspace_root, @issue.identifier, ".kollywood", "testing.json"])
    assert File.exists?(testing_json)
    {:ok, payload} = testing_json |> File.read!() |> Jason.decode()
    assert payload["verdict"] == "pass"

    artifact_kinds =
      payload
      |> Map.get("artifacts", [])
      |> Enum.map(&Map.get(&1, "kind"))

    assert "screenshot" in artifact_kinds
    assert "video" in artifact_kinds
    assert "replay" in artifact_kinds
  end

  test "passes testing_notes only to testing agent prompt", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    review_cli_path: review_cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_testing_notes.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)
    review_prompt_log = Path.join(root, "review-prompts.log")
    testing_prompt_log = Path.join(root, "testing-prompts.log")
    attempt_dir = Path.join(root, "attempt-testing-notes")

    log_files = %{
      review_json: Path.join(attempt_dir, "review.json"),
      review_cycles_dir: Path.join(attempt_dir, "review_cycles"),
      testing_json: Path.join(attempt_dir, "testing.json"),
      testing_cycles_dir: Path.join(attempt_dir, "testing_cycles")
    }

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:quality, %{max_cycles: 2})
      |> Map.put(:runtime, full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log))
      |> Map.put(:review, %{
        enabled: true,
        max_cycles: 1,
        agent: %{
          explicit: true,
          kind: :pi,
          command: review_cli_path,
          args: [],
          env: %{"REVIEW_PROMPT_LOG_FILE" => review_prompt_log},
          timeout_ms: 10_000
        }
      })
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 1,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{
            "TESTING_VERDICT" => "pass",
            "TESTING_PROMPT_LOG_FILE" => testing_prompt_log
          },
          timeout_ms: 10_000
        }
      })

    issue_with_testing =
      @issue
      |> Map.put("testing_notes", "Use tester account and capture checkout flow video.")
      |> Map.put(:settings, %{"execution" => %{"testing_enabled" => true}})

    assert {:ok, result} =
             AgentRunner.run_issue(issue_with_testing,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn,
               log_files: log_files
             )

    assert result.status == :ok

    prompt_history = File.read!(prompt_log)
    refute prompt_history =~ "Use tester account and capture checkout flow video."

    review_prompt_history = File.read!(review_prompt_log)
    refute review_prompt_history =~ "Use tester account and capture checkout flow video."

    testing_prompt_history = File.read!(testing_prompt_log)
    assert testing_prompt_history =~ "Use tester account and capture checkout flow video."
    assert File.exists?(Path.join(log_files.review_cycles_dir, "cycle-001.json"))
    assert File.exists?(Path.join(log_files.testing_cycles_dir, "cycle-001.json"))
  end

  test "persists testing report and local artifacts to run-log paths", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_testing_artifacts.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)

    attempt_dir = Path.join(root, "attempt-testing-artifacts")
    File.mkdir_p!(attempt_dir)

    log_files = %{
      testing_json: Path.join(attempt_dir, "testing.json"),
      testing_cycles_dir: Path.join(attempt_dir, "testing_cycles"),
      testing_report: Path.join(attempt_dir, "testing_report.json"),
      testing_artifacts_dir: Path.join(attempt_dir, "testing_artifacts")
    }

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:quality, %{max_cycles: 2})
      |> Map.put(:runtime, full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log))
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 1,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{"TESTING_VERDICT" => "pass"},
          timeout_ms: 10_000
        }
      })

    issue_with_testing =
      Map.put(@issue, :settings, %{"execution" => %{"testing_enabled" => true}})

    assert {:ok, result} =
             AgentRunner.run_issue(issue_with_testing,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn,
               log_files: log_files
             )

    assert result.status == :ok
    assert File.exists?(log_files.testing_json)
    assert File.exists?(Path.join(log_files.testing_cycles_dir, "cycle-001.json"))
    assert File.exists?(log_files.testing_report)
    assert File.dir?(log_files.testing_artifacts_dir)

    report = log_files.testing_report |> File.read!() |> Jason.decode!()
    assert report["verdict"] == "pass"

    stored_artifacts =
      report
      |> Map.get("artifacts", [])
      |> Enum.filter(fn artifact ->
        is_binary(artifact["stored_path"]) and String.trim(artifact["stored_path"]) != ""
      end)

    assert length(stored_artifacts) >= 2
  end

  test "retries with remediation turn when testing fails before max cycles", %{
    root: root,
    workspace_root: workspace_root,
    cli_path: cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    fake_devenv_log = Path.join(root, "fake_devenv_testing_retry.log")
    fake_devenv = write_fake_devenv!(root, fake_devenv_log)
    fail_once_file = Path.join(root, "testing_fail_once.marker")

    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:quality, %{max_cycles: 2})
      |> Map.put(:runtime, full_stack_runtime(:full_stack, fake_devenv, fake_devenv_log))
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 2,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{"TESTING_FAIL_ONCE_FILE" => fail_once_file},
          timeout_ms: 10_000
        }
      })

    issue_with_testing =
      Map.put(@issue, :settings, %{"execution" => %{"testing_enabled" => true}})

    assert {:ok, result} =
             AgentRunner.run_issue(issue_with_testing,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn
             )

    assert result.status == :ok
    assert result.turn_count == 2
    assert :quality_cycle_retrying in Enum.map(result.events, & &1.type)
    assert :testing_failed in Enum.map(result.events, & &1.type)
    assert :testing_passed in Enum.map(result.events, & &1.type)

    prompt_history = File.read!(prompt_log)
    assert prompt_history =~ "Tester feedback from cycle 1"
  end

  test "fails when testing is enabled but runtime processes are not configured", %{
    workspace_root: workspace_root,
    cli_path: cli_path,
    testing_cli_path: testing_cli_path,
    prompt_log: prompt_log
  } do
    config =
      runner_config(workspace_root, cli_path, prompt_log)
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 1,
        timeout_ms: 10_000,
        agent: %{
          explicit: true,
          kind: :cursor,
          command: testing_cli_path,
          args: [],
          env: %{},
          timeout_ms: 10_000
        }
      })

    issue_with_testing =
      Map.put(@issue, :settings, %{"execution" => %{"testing_enabled" => true}})

    assert {:error, result} =
             AgentRunner.run_issue(issue_with_testing,
               config: config,
               prompt_template: "Work on {{ issue.identifier }}",
               mode: :single_turn
             )

    assert result.error =~ "testing requires runtime.processes to be configured"
    assert :testing_started in Enum.map(result.events, & &1.type)
    assert :testing_error in Enum.map(result.events, & &1.type)
  end

  test "push mode pushes branch only", %{root: root, git_cli_path: git_cli_path} do
    %{source: source, workspaces_root: workspaces_root, origin: origin} =
      setup_worktree_repo(root)

    seed_prd_story!(source, @issue.id)

    config =
      worktree_runner_config(source, workspaces_root, git_cli_path)
      |> Map.put(:publish, %{mode: :push})
      |> Map.put(:project_provider, :local)

    assert {:ok, result} =
             AgentRunner.run_issue(@issue, config: config, prompt_template: "Implement")

    event_types = Enum.map(result.events, & &1.type)
    assert :publish_push_succeeded in event_types
    assert :publish_succeeded in event_types
    refute :publish_pr_created in event_types
    refute :publish_merged in event_types

    verify_path = Path.join(root, "verify_push_repo")
    git!(["clone", origin, verify_path], root)
    git!(["checkout", "main"], verify_path)
    refute File.exists?(Path.join(verify_path, "agent_output.txt"))
  end

  test "pr mode creates PR and marks tracker pending_merge", %{
    root: root,
    git_cli_path: git_cli_path
  } do
    %{source: source, workspaces_root: workspaces_root} = setup_worktree_repo(root)
    seed_prd_story!(source, @issue.id)

    gh_log = Path.join(root, "fake_gh_pr.log")
    fake_gh = write_fake_gh!(root, gh_log)

    with_path(fake_gh, fn ->
      config =
        worktree_runner_config(source, workspaces_root, git_cli_path)
        |> Map.put(:publish, %{provider: :github, mode: :pr})

      assert {:ok, result} =
               AgentRunner.run_issue(@issue, config: config, prompt_template: "Implement")

      event_types = Enum.map(result.events, & &1.type)
      assert :publish_push_succeeded in event_types
      assert :publish_pr_created in event_types
      refute :publish_merged in event_types

      assert_prd_status(source, @issue.id, "pending_merge")

      prd = read_prd(source)
      story = Enum.find(prd["userStories"], &(&1["id"] == @issue.id))
      assert story["pr_url"] == "https://example.test/pulls/123"

      gh_output = File.read!(gh_log)
      assert gh_output =~ "pr create"
      refute gh_output =~ "pr merge --auto"
    end)
  end

  test "auto_merge on github enables PR auto-merge and marks pending_merge", %{
    root: root,
    git_cli_path: git_cli_path
  } do
    %{source: source, workspaces_root: workspaces_root} = setup_worktree_repo(root)
    seed_prd_story!(source, @issue.id)

    gh_log = Path.join(root, "fake_gh_auto_merge.log")
    fake_gh = write_fake_gh!(root, gh_log)

    with_path(fake_gh, fn ->
      config =
        worktree_runner_config(source, workspaces_root, git_cli_path)
        |> Map.put(:publish, %{provider: :github, mode: :auto_merge})

      assert {:ok, result} =
               AgentRunner.run_issue(@issue, config: config, prompt_template: "Implement")

      event_types = Enum.map(result.events, & &1.type)
      assert :publish_push_succeeded in event_types
      assert :publish_pr_created in event_types
      refute :publish_merged in event_types

      assert_prd_status(source, @issue.id, "pending_merge")

      gh_output = File.read!(gh_log)
      assert gh_output =~ "pr create"
      assert gh_output =~ "pr merge --auto"
    end)
  end

  test "auto_merge github failure after push keeps push event in timeline", %{
    root: root,
    git_cli_path: git_cli_path
  } do
    %{source: source, workspaces_root: workspaces_root} = setup_worktree_repo(root)
    seed_prd_story!(source, @issue.id)

    gh_log = Path.join(root, "fake_gh_auto_merge_fail.log")
    fake_gh = write_fake_gh!(root, gh_log)

    with_path(fake_gh, fn ->
      previous = System.get_env("FAKE_GH_FAIL_AUTO_MERGE")
      System.put_env("FAKE_GH_FAIL_AUTO_MERGE", "1")

      try do
        config =
          worktree_runner_config(source, workspaces_root, git_cli_path)
          |> Map.put(:publish, %{provider: :github, mode: :auto_merge})

        assert {:error, result} =
                 AgentRunner.run_issue(@issue, config: config, prompt_template: "Implement")

        event_types = Enum.map(result.events, & &1.type)
        assert :publish_push_succeeded in event_types
        assert :publish_failed in event_types
        refute :publish_succeeded in event_types
        assert result.error =~ "auto-merge enable failed"
      after
        if is_nil(previous) do
          System.delete_env("FAKE_GH_FAIL_AUTO_MERGE")
        else
          System.put_env("FAKE_GH_FAIL_AUTO_MERGE", previous)
        end
      end
    end)
  end

  test "auto_merge on local provider merges branch after push", %{
    root: root,
    git_cli_path: git_cli_path
  } do
    %{source: source, workspaces_root: workspaces_root, origin: origin} =
      setup_worktree_repo(root)

    seed_prd_story!(source, @issue.id)

    config =
      worktree_runner_config(source, workspaces_root, git_cli_path)
      |> Map.put(:publish, %{mode: :auto_merge})
      |> Map.put(:project_provider, :local)

    assert {:ok, result} =
             AgentRunner.run_issue(@issue, config: config, prompt_template: "Implement")

    event_types = Enum.map(result.events, & &1.type)
    assert :publish_push_succeeded in event_types
    assert :publish_merged in event_types
    assert :publish_succeeded in event_types

    verify_path = Path.join(root, "verify_repo")
    git!(["clone", origin, verify_path], root)
    git!(["checkout", "main"], verify_path)

    assert File.exists?(Path.join(verify_path, "agent_output.txt"))
    assert_prd_status(source, @issue.id, "merged")
  end

  test "auto_merge conflict triggers remediation turn and retries merge", %{root: root} do
    %{source: source, workspaces_root: workspaces_root} = setup_worktree_repo(root)

    seed_prd_story!(source, @issue.id)
    seed_conflict_file!(source)

    prompt_log = Path.join(root, "conflict_prompts.log")
    conflict_cli_path = write_conflict_agent!(root)

    config =
      worktree_runner_config(source, workspaces_root, conflict_cli_path)
      |> Map.put(:publish, %{mode: :auto_merge})
      |> Map.put(:project_provider, :local)
      |> update_in([Access.key(:agent), Access.key(:env)], fn env ->
        Map.merge(env, %{
          "SOURCE_REPO" => source,
          "PROMPT_LOG_FILE" => prompt_log
        })
      end)

    assert {:ok, result} =
             AgentRunner.run_issue(@issue, config: config, prompt_template: "Implement")

    event_types = Enum.map(result.events, & &1.type)
    assert :publish_push_succeeded in event_types
    assert :publish_merge_conflict in event_types
    assert :publish_merge_conflict_resolved in event_types
    assert :publish_merged in event_types
    assert :publish_succeeded in event_types
    assert result.turn_count == 2

    prompt_history = File.read!(prompt_log)
    assert prompt_history =~ "Please resolve the conflicts"
    assert prompt_history =~ "git rebase origin/main"
    assert prompt_history =~ "git push --force-with-lease origin"

    assert_prd_status(source, @issue.id, "merged")
  end

  test "auto_merge conflict remediation failure fails publish", %{root: root} do
    %{source: source, workspaces_root: workspaces_root} = setup_worktree_repo(root)

    seed_prd_story!(source, @issue.id)
    seed_conflict_file!(source)

    conflict_cli_path = write_conflict_agent!(root)

    config =
      worktree_runner_config(source, workspaces_root, conflict_cli_path)
      |> Map.put(:publish, %{mode: :auto_merge})
      |> Map.put(:project_provider, :local)
      |> update_in([Access.key(:agent), Access.key(:env)], fn env ->
        Map.merge(env, %{
          "SOURCE_REPO" => source,
          "FAIL_CONFLICT_REMEDIATION" => "1"
        })
      end)

    assert {:error, result} =
             AgentRunner.run_issue(@issue, config: config, prompt_template: "Implement")

    event_types = Enum.map(result.events, & &1.type)
    assert :publish_push_succeeded in event_types
    assert :publish_merge_conflict in event_types
    assert :publish_failed in event_types
    refute :publish_merged in event_types
    refute :publish_succeeded in event_types
    assert result.error =~ "conflict resolution failed"
    assert_prd_status(source, @issue.id, "open")
  end

  test "auto_merge failure does not fail publish", %{
    root: root,
    git_cli_path: git_cli_path
  } do
    %{source: source, workspaces_root: workspaces_root} = setup_worktree_repo(root)

    config =
      worktree_runner_config(source, workspaces_root, git_cli_path)
      |> Map.put(:publish, %{mode: :auto_merge})
      |> Map.put(:git, %{base_branch: "does-not-exist"})
      |> Map.put(:project_provider, :local)

    assert {:ok, result} =
             AgentRunner.run_issue(@issue, config: config, prompt_template: "Implement")

    event_types = Enum.map(result.events, & &1.type)
    assert :publish_push_succeeded in event_types
    assert :publish_merge_failed in event_types
    assert :publish_succeeded in event_types
    refute :publish_failed in event_types
    refute :publish_merge_conflict in event_types
    assert result.turn_count == 1
  end

  defp worktree_runner_config(source, workspaces_root, git_cli_path) do
    %Config{
      tracker: %{kind: "local", path: "prd.json"},
      polling: %{},
      workspace: %{
        root: workspaces_root,
        strategy: :worktree,
        source: source,
        branch_prefix: "kw/"
      },
      hooks: %{
        @no_hooks
        | after_create: "git config user.email test@test.com && git config user.name Test"
      },
      checks: %{required: [], timeout_ms: 10_000, fail_fast: true},
      runtime: %{
        kind: :host,
        command: "devenv",
        processes: [],
        env: %{},
        ports: %{},
        port_offset_mod: 1000,
        start_timeout_ms: 120_000,
        stop_timeout_ms: 60_000
      },
      review: %{enabled: false, max_cycles: 1, agent: %{kind: :amp}},
      agent: %{
        kind: :amp,
        max_concurrent_agents: 1,
        max_turns: 1,
        command: git_cli_path,
        args: [],
        env: %{},
        timeout_ms: 10_000
      },
      publish: %{mode: :push},
      git: %{base_branch: "main"},
      raw: %{}
    }
  end

  defp seed_prd_story!(source_repo, issue_id) do
    prd_path = Path.join(source_repo, "prd.json")

    git!(["config", "user.email", "test@test.com"], source_repo)
    git!(["config", "user.name", "Test"], source_repo)

    prd = %{
      "userStories" => [
        %{
          "id" => issue_id,
          "title" => "Story #{issue_id}",
          "description" => "Test story",
          "acceptanceCriteria" => ["it works"],
          "status" => "open",
          "priority" => 1,
          "dependsOn" => []
        }
      ]
    }

    File.write!(prd_path, Jason.encode_to_iodata!(prd, pretty: true))
    git!(["add", "prd.json"], source_repo)
    git!(["commit", "-m", "add prd story"], source_repo)
    git!(["push", "origin", "main"], source_repo)
  end

  defp seed_conflict_file!(source_repo) do
    conflict_path = Path.join(source_repo, "conflict.txt")

    File.write!(conflict_path, "base\n")
    git!(["add", "conflict.txt"], source_repo)
    git!(["commit", "-m", "seed conflict file"], source_repo)
    git!(["push", "origin", "main"], source_repo)
  end

  defp assert_prd_status(source_repo, issue_id, expected_status) do
    prd = read_prd(source_repo)
    story = Enum.find(prd["userStories"], &(&1["id"] == issue_id))
    assert story["status"] == expected_status
  end

  defp read_prd(source_repo) do
    source_repo
    |> Path.join("prd.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_fake_gh!(root, log_path) do
    fake_bin = Path.join(root, "fake_bin")
    File.mkdir_p!(fake_bin)

    path = Path.join(fake_bin, "gh")

    File.write!(path, """
    #!/usr/bin/env bash
    set -eu

    printf "%s\n" "$*" >> "#{log_path}"

    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
      echo "https://example.test/pulls/123"
      exit 0
    fi

    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ] && [ "${3:-}" = "--auto" ]; then
      if [ "${FAKE_GH_FAIL_AUTO_MERGE:-}" = "1" ]; then
        echo "forced auto-merge failure" >&2
        exit 23
      fi

      exit 0
    fi

    echo "unexpected gh invocation: $*" >&2
    exit 17
    """)

    File.chmod!(path, 0o755)
    File.rm(log_path)
    path
  end

  defp write_conflict_agent!(root) do
    path = Path.join(root, "fake_conflict_runner_cli.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    set -eu

    prompt="$(cat)"

    if [ -n "${PROMPT_LOG_FILE:-}" ]; then
      printf "PROMPT<<%s>>\n" "$prompt" >> "$PROMPT_LOG_FILE"
    fi

    case "$prompt" in
      *"Please resolve the conflicts:"*)
        if [ "${FAIL_CONFLICT_REMEDIATION:-}" = "1" ]; then
          echo "forced remediation failure" >&2
          exit 61
        fi

        git fetch origin >/dev/null

        set +e
        git rebase origin/main >/dev/null 2>&1
        rebase_code=$?
        set -e

        if [ "$rebase_code" -ne 0 ]; then
          printf "resolved in remediation\n" > conflict.txt
          git add conflict.txt
          GIT_EDITOR=true git rebase --continue >/dev/null
        fi

        branch="$(git rev-parse --abbrev-ref HEAD)"
        git push --force-with-lease origin "$branch" >/dev/null
        echo "ok:remediation"
        exit 0
        ;;
    esac

    printf "branch change\n" > conflict.txt
    git add conflict.txt
    git commit -m "branch change" >/dev/null

    if [ -n "${SOURCE_REPO:-}" ]; then
      git -C "$SOURCE_REPO" checkout main >/dev/null 2>&1
      printf "main change\n" > "$SOURCE_REPO/conflict.txt"
      git -C "$SOURCE_REPO" add conflict.txt
      git -C "$SOURCE_REPO" commit -m "main change" >/dev/null
      git -C "$SOURCE_REPO" push origin main >/dev/null
    fi

    echo "ok:initial"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp with_path(binary_path, fun) when is_binary(binary_path) and is_function(fun, 0) do
    original_path = System.get_env("PATH") || ""
    new_path = "#{Path.dirname(binary_path)}:#{original_path}"

    System.put_env("PATH", new_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end

  defp setup_worktree_repo(root) do
    origin = Path.join(root, "origin.git")
    seed = Path.join(root, "seed_repo")
    source = Path.join(root, "source_repo")
    workspaces_root = Path.join(root, "workspaces")

    File.mkdir_p!(origin)
    git!(["init", "--bare"], origin)
    git!(["clone", origin, seed], root)

    git!(["config", "user.email", "test@test.com"], seed)
    git!(["config", "user.name", "Test"], seed)
    git!(["checkout", "-b", "main"], seed)

    File.write!(Path.join(seed, "README.md"), "# Seed")
    git!(["add", "."], seed)
    git!(["commit", "-m", "seed"], seed)
    git!(["push", "-u", "origin", "main"], seed)

    git!(["clone", origin, source], root)
    git!(["checkout", "main"], source)

    %{origin: origin, source: source, workspaces_root: workspaces_root}
  end

  defp git!(args, cwd) do
    {output, code} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

    if code != 0 do
      flunk("git #{Enum.join(args, " ")} failed in #{cwd}: #{String.trim(output)}")
    end

    output
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
        kind: :host,
        command: "devenv",
        processes: [],
        env: %{},
        ports: %{},
        port_offset_mod: 1000,
        start_timeout_ms: 120_000,
        stop_timeout_ms: 60_000
      },
      review: %{enabled: false, max_cycles: 1, agent: %{kind: agent.kind}},
      agent: agent,
      raw: %{}
    }
  end

  defp full_stack_runtime(profile, command, log_path) do
    processes =
      if profile == :checks_only do
        []
      else
        ["server"]
      end

    %{
      kind: :host,
      command: command,
      processes: processes,
      env: %{
        "FAKE_DEVENV_LOG" => log_path,
        "RUNTIME_SENTINEL" => "ok"
      },
      ports: %{"APP_PORT" => 4100},
      port_offset_mod: 1000,
      start_timeout_ms: 10_000,
      stop_timeout_ms: 10_000
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
      if [ -n "${FAKE_DEVENV_FAIL_DOWN_ONCE_FILE:-}" ]; then
        if [ ! -f "$FAKE_DEVENV_FAIL_DOWN_ONCE_FILE" ]; then
          touch "$FAKE_DEVENV_FAIL_DOWN_ONCE_FILE"
          echo "forced down failure" >&2
          exit 61
        fi
      fi

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

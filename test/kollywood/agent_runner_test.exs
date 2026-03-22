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

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{root: root, workspace_root: workspace_root, cli_path: cli_path, prompt_log: prompt_log}
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
             :run_finished
           ]
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
      agent: agent,
      raw: %{}
    }
  end
end

defmodule Kollywood.RunEvents.StoreTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.RunEvents

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_run_events_store_test_#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("KOLLYWOOD_HOME")
    kollywood_home = Path.join(root, ".kollywood-home")
    System.put_env("KOLLYWOOD_HOME", kollywood_home)

    File.mkdir_p!(root)

    slug = "run-events-store-#{System.unique_integer([:positive])}"

    config = %Config{
      workspace: %{root: root},
      tracker: %{path: nil, project_slug: slug}
    }

    issue = %{id: "US-RUN-EVENTS", identifier: "US-RUN-EVENTS", title: "Run events"}
    {:ok, context} = RunLogs.prepare_attempt(config, issue, nil)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("KOLLYWOOD_HOME")
        value -> System.put_env("KOLLYWOOD_HOME", value)
      end

      File.rm_rf!(root)
    end)

    %{context: context}
  end

  test "stores events with per-attempt sequence cursors", %{context: context} do
    assert :ok = RunLogs.append_event(context, %{type: :run_started})
    assert :ok = RunLogs.append_event(context, %{type: :turn_started, turn: 1})
    assert :ok = RunLogs.append_event(context, %{type: :turn_succeeded, turn: 1, output: "ok"})

    assert {:ok, true} =
             RunEvents.stream_exists?(context.project_slug, context.story_id, context.attempt)

    assert {:ok, first_page, first_cursor} =
             RunEvents.list_events(context.project_slug, context.story_id, context.attempt,
               since: 0,
               limit: 2
             )

    assert Enum.map(first_page, & &1["type"]) == ["run_started", "turn_started"]
    assert first_cursor == 2

    assert {:ok, second_page, second_cursor} =
             RunEvents.list_events(context.project_slug, context.story_id, context.attempt,
               since: first_cursor,
               limit: 2
             )

    assert Enum.map(second_page, & &1["type"]) == ["turn_succeeded"]
    assert second_cursor == 3
  end

  test "returns false for unknown stream", %{context: context} do
    assert {:ok, false} =
             RunEvents.stream_exists?(context.project_slug, context.story_id, context.attempt + 1)
  end
end

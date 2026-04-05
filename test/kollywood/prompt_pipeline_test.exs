defmodule Kollywood.PromptPipelineTest do
  use ExUnit.Case, async: true

  alias Kollywood.PromptPipeline

  test "build succeeds with args and runtime context" do
    template = "Issue {{ issue.identifier }} for {{ args.customer }} in {{ workspace_path }}"

    assert {:ok, prompt, settings} =
             PromptPipeline.build(template, %{"issue" => %{"identifier" => "ABC-123"}},
               prompt_args: %{"customer" => "acme"},
               runtime_context: %{workspace_path: "/tmp/ws"}
             )

    assert prompt =~ "Issue ABC-123 for acme in /tmp/ws"
    assert settings["required_args"] == ["customer"]
    assert settings["missing_args"] == []
  end

  test "build fails when required args are missing" do
    template = "Do {{ args.customer }} work"

    assert {:error, reason, settings} =
             PromptPipeline.build(template, %{}, prompt_args: %{})

    assert reason =~ "missing required prompt args"
    assert settings["missing_args"] == ["customer"]
  end

  test "settings_snapshot warns on unused args" do
    settings = PromptPipeline.settings_snapshot("Hello {{ issue.identifier }}", %{unused: "x"})

    assert settings["unused_args"] == ["unused"]
    assert length(settings["warnings"]) == 1
  end

  test "settings_snapshot reports reserved key collisions" do
    settings = PromptPipeline.settings_snapshot("Hello", %{workspace_path: "bad"})

    assert Enum.any?(settings["errors"], &String.contains?(&1, "reserved prompt args"))
    assert {:error, _} = PromptPipeline.validate_settings(settings)
  end
end

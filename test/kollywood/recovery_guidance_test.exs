defmodule Kollywood.RecoveryGuidanceTest do
  use ExUnit.Case, async: true

  alias Kollywood.RecoveryGuidance

  describe "parse/1" do
    test "extracts summary and commands from guidance text" do
      guidance_text =
        "push failed\nRecovery commands:\n  git status --short\n  git push -u origin kw/US-TEST"

      assert RecoveryGuidance.parse(guidance_text) == %{
               summary: "push failed",
               commands: ["git status --short", "git push -u origin kw/US-TEST"]
             }
    end

    test "returns nil when guidance marker is absent" do
      assert RecoveryGuidance.parse("plain failure reason") == nil
    end
  end

  describe "normalize/1" do
    test "normalizes map payload with string keys" do
      payload = %{
        "summary" => "sync failed",
        "commands" => ["git fetch --all --prune", "git reset --hard origin/main"]
      }

      assert RecoveryGuidance.normalize(payload) == %{
               summary: "sync failed",
               commands: ["git fetch --all --prune", "git reset --hard origin/main"]
             }
    end

    test "normalizes map payload with atom keys and trims entries" do
      payload = %{
        summary: "  merge failed  ",
        commands: ["  git status --short  ", "", "   "]
      }

      assert RecoveryGuidance.normalize(payload) == %{
               summary: "merge failed",
               commands: ["git status --short"]
             }
    end

    test "returns nil for incomplete map payload" do
      assert RecoveryGuidance.normalize(%{"summary" => "missing commands"}) == nil
      assert RecoveryGuidance.normalize(%{"commands" => ["git status"]}) == nil
    end
  end

  describe "text/1" do
    test "renders normalized guidance payload into display text" do
      guidance = %{
        summary: "workspace collision",
        commands: ["git worktree list --porcelain", "git worktree prune"]
      }

      assert RecoveryGuidance.text(guidance) ==
               "workspace collision\nRecovery commands:\n  git worktree list --porcelain\n  git worktree prune"
    end
  end
end

defmodule Kollywood.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias Kollywood.PromptBuilder

  test "renders template with issue variables" do
    template = ~S"Working on {{ issue.identifier }}: {{ issue.title }}"

    variables = PromptBuilder.build_variables(%{identifier: "ABC-123", title: "Fix bug"})
    assert {:ok, rendered} = PromptBuilder.render(template, variables)
    assert rendered == "Working on ABC-123: Fix bug"
  end

  test "renders template with attempt" do
    template = ~S"{% if attempt %}Retry #{{ attempt }}{% endif %}"

    variables = PromptBuilder.build_variables(%{identifier: "X-1"}, 3)
    assert {:ok, rendered} = PromptBuilder.render(template, variables)
    assert rendered =~ "Retry #3"
  end

  test "attempt is nil on first run" do
    template = ~S"{% if attempt %}retry{% else %}first{% endif %}"

    variables = PromptBuilder.build_variables(%{identifier: "X-1"})
    assert {:ok, rendered} = PromptBuilder.render(template, variables)
    assert rendered =~ "first"
  end

  test "handles nested issue fields" do
    template = ~S"{{ issue.description }}"

    variables = PromptBuilder.build_variables(%{description: "Some **markdown** text"})
    assert {:ok, rendered} = PromptBuilder.render(template, variables)
    assert rendered == "Some **markdown** text"
  end
end

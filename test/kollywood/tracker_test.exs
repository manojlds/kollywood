defmodule Kollywood.TrackerTest do
  use ExUnit.Case, async: true

  alias Kollywood.Tracker
  alias Kollywood.Tracker.Noop
  alias Kollywood.Tracker.PrdJson

  test "resolves prd_json tracker kinds" do
    assert Tracker.module_for_kind("prd_json") == PrdJson
    assert Tracker.module_for_kind("prd-json") == PrdJson
    assert Tracker.module_for_kind("local") == PrdJson
    assert Tracker.module_for_kind(:prd_json) == PrdJson
  end

  test "falls back to noop for unknown kinds" do
    assert Tracker.module_for_kind("linear") == Noop
    assert Tracker.module_for_kind("anything") == Noop
    assert Tracker.module_for_kind(nil) == Noop
  end
end

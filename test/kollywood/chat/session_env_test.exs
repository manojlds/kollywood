defmodule Kollywood.Chat.SessionEnvTest do
  use ExUnit.Case, async: true

  alias Kollywood.Chat.Session

  describe "ACP environment" do
    test "builds PATH with preferred user bin directories first" do
      env = Session.__test_acp_env__()
      path = env_value(env, "PATH")

      assert is_binary(path)

      entries = String.split(path, ":", trim: true)
      expected_local = Path.join(System.user_home(), ".local/bin")

      if File.dir?(expected_local) do
        assert hd(entries) == expected_local
      end
    end

    test "includes KOLLYWOOD_CLI when ~/.local/bin/kollywood exists" do
      env = Session.__test_acp_env__()
      cli_path = env_value(env, "KOLLYWOOD_CLI")
      expected = Path.join(System.user_home(), ".local/bin/kollywood")

      if File.exists?(expected) do
        assert cli_path == expected
      else
        assert is_nil(cli_path)
      end
    end
  end

  defp env_value(env, key) do
    env
    |> Enum.find_value(fn
      {^key, value} when is_binary(value) -> value
      _other -> nil
    end)
  end
end

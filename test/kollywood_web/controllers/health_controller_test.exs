defmodule KollywoodWeb.HealthControllerTest do
  use KollywoodWeb.ConnCase, async: true

  test "returns status and runtime metadata", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    assert %{
             "status" => "ok",
             "version" => version,
             "git_sha" => git_sha,
             "version_full" => version_full,
             "build_time" => build_time,
             "otp" => otp,
             "elixir" => elixir,
             "beam_pid" => beam_pid
           } = json_response(conn, 200)

    assert version == Kollywood.Version.version()
    assert git_sha == Kollywood.Version.git_sha()
    assert version_full == Kollywood.Version.full()
    assert build_time == Kollywood.Version.build_time()
    assert otp == List.to_string(:erlang.system_info(:otp_release))
    assert elixir == System.version()

    assert {beam_pid_int, ""} = Integer.parse(beam_pid)
    assert beam_pid_int > 0
  end
end

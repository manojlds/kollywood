defmodule KollywoodWeb.HealthController do
  use KollywoodWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      status: "ok",
      version: Kollywood.Version.version(),
      git_sha: Kollywood.Version.git_sha(),
      version_full: Kollywood.Version.full(),
      build_time: Kollywood.Version.build_time(),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      elixir: System.version(),
      beam_pid: :os.getpid() |> to_string()
    })
  end
end

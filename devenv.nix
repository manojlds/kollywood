{ pkgs, ... }:
let
  mix = "${pkgs.elixir}/bin/mix";
  curl = "${pkgs.curl}/bin/curl";
in
{
  packages = [
    pkgs.elixir
    pkgs.erlang
    pkgs.ffmpeg
  ];

  env = {
    MIX_ENV = "dev";
    PORT = "4000";
  };

  processes.server = {
    exec = ''
      BOOTSTRAP_STAMP=".devenv/state/kollywood-bootstrap.stamp"

      if [ ! -f "$BOOTSTRAP_STAMP" ] || [ "mix.lock" -nt "$BOOTSTRAP_STAMP" ] || [ ! -d "deps" ]; then
        echo "[devenv] Bootstrapping Kollywood deps..."
        ${mix} local.hex --force
        ${mix} local.rebar --force
        ${mix} setup
        mkdir -p .devenv/state
        touch "$BOOTSTRAP_STAMP"
      fi

      exec ${mix} phx.server
    '';

    ready = {
      exec = ''
        ${curl} -fsS "http://127.0.0.1:''${PORT:-4000}/"
      '';
      initial_delay = 1;
      period = 1;
      timeout = 1;
      failure_threshold = 30;
      success_threshold = 1;
    };
  };
}

import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kollywood start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kollywood, KollywoodWeb.Endpoint, server: true
end

config :kollywood, KollywoodWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

app_mode =
  case System.get_env("KOLLYWOOD_APP_MODE") do
    nil ->
      nil

    value ->
      case value |> String.trim() |> String.downcase() do
        "all" -> :all
        "web" -> :web
        "orchestrator" -> :orchestrator
        "worker" -> :worker
        _other -> :all
      end
  end

if app_mode do
  config :kollywood, app_mode: app_mode
end

case System.get_env("KOLLYWOOD_GLOBAL_MAX_CONCURRENT_AGENTS") do
  nil ->
    :ok

  value ->
    orchestrator_opts =
      case Application.get_env(:kollywood, :orchestrator, []) do
        opts when is_list(opts) -> opts
        _other -> []
      end

    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 ->
        config :kollywood,
          orchestrator: Keyword.put(orchestrator_opts, :global_max_concurrent_agents, parsed)

      _other ->
        IO.warn(
          "Ignoring invalid KOLLYWOOD_GLOBAL_MAX_CONCURRENT_AGENTS=#{inspect(value)}; expected a positive integer"
        )
    end
end

if config_env() != :test do
  kollywood_home =
    System.get_env("KOLLYWOOD_HOME") ||
      Path.join(System.user_home!(), ".kollywood")

  default_db_path = Path.join(Path.expand(kollywood_home), "kollywood.db")

  config :kollywood, Kollywood.Repo,
    database: System.get_env("KOLLYWOOD_DB_PATH", default_db_path),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :kollywood, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :kollywood, KollywoodWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kollywood, KollywoodWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kollywood, KollywoodWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :kollywood,
  generators: [timestamp_type: :utc_datetime],
  app_mode: :all,
  orchestrator_enabled: true,
  orchestrator_ephemeral_store: Kollywood.Orchestrator.EphemeralStore,
  orchestrator_retry_store: Kollywood.Orchestrator.RetryStore,
  orchestrator: [global_max_concurrent_agents: 5]

config :kollywood,
  ecto_repos: [Kollywood.Repo]

config :kollywood, Kollywood.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: ".kollywood/kollywood.db",
  pool_size: 5,
  busy_timeout: 5_000,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Configure the endpoint
config :kollywood, KollywoodWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KollywoodWeb.ErrorHTML, json: KollywoodWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Kollywood.PubSub,
  live_view: [signing_salt: "dW3+SpJC"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kollywood: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  kollywood: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

import Config

alias Contentoid.Downloads.Docker
alias Contentoid.Downloads.Janitor
alias Contentoid.Downloads.Queues

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :contentoid, Contentoid.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "contentoid_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Downloads talk to a fake Docker daemon (`Contentoid.FakeDocker`, through `Req.Test`), never a
  # real one. The socket is never opened.
  # We don't run a server during test. If one is required,
  # you can enable the server option below.
  pool_size: System.schedulers_online() * 2

config :contentoid, Contentoid.Settings, default_download_dir: Path.expand("../tmp/test-downloads", __DIR__)

config :contentoid, ContentoidWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "OJFUrlTfbLtWemBO5gwxfs52VnuGNg128osG4MCysn2cwiopFt4ewWZD+hTzayT3",
  server: false

config :contentoid, Docker, req_options: [plug: {Req.Test, Docker}]

# The tests run recovery themselves (`Contentoid.Downloads.recover_interrupted/0`).
config :contentoid, Janitor, enabled: false

# Jobs are run by the tests themselves (`Oban.Testing`), never by queues.
config :contentoid, Oban, testing: :manual

# Tests run jobs themselves (`Oban.Testing`), so no downloader gets a running queue.
config :contentoid, Queues, enabled: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

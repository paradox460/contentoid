# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

alias Contentoid.Schedules.Ticker

# Configure the endpoint
config :contentoid, ContentoidWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ContentoidWeb.ErrorHTML, json: ContentoidWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Contentoid.PubSub,
  live_view: [signing_salt: "Jka64SHB"]

# Downloads run as Oban jobs, one queue per downloader, started at runtime and sized to the downloader's
# concurrency (`Contentoid.Downloads.Queues`); the only static queue is the scheduler's, whose ticker
# runs due schedules every minute (`Contentoid.Schedules.Ticker`). A download can run for hours, so
# shutdown doesn't wait for it: after a second its job is stopped, its container removed
# (`Contentoid.Downloads.Janitor`), and the next boot resumes it.
config :contentoid, Oban,
  repo: Contentoid.Repo,
  queues: [scheduler: 1],
  # Process groups, not Postgres LISTEN/NOTIFY: downloader queues are started by signal right after
  # Oban boots (`Contentoid.Downloads.Queues.start_all/0`), before the Postgres notifier's listen
  # connection is up, which dropped them. Contentoid is one node, so local delivery is all it needs.
  notifier: Oban.Notifiers.PG,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron, crontab: [{"* * * * *", Ticker}]}
  ],
  shutdown_grace_period: 1_000

config :contentoid,
  ecto_repos: [Contentoid.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Schedules run in the time zone they're written for (`Contentoid.Schedules`).
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Icon strokes, in Lucide's 24-unit viewBox (Lucide's own is 2). See DESIGN.md.
config :iconex, lucide: [stroke_width: 1], sets: [:lucide]

# CLDR data for number and date formatting (localize). Every "modern"-coverage locale, downloaded
# into priv/localize/locales by `mix localize.download_locales` (mix setup, Dockerfile).
config :localize, otp_app: :contentoid, supported_locales: [:modern]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# ^ Environment specific config. This must remain at the bottom of this file so it overrides the

# Configure LiveView

# Use Jason for JSON parsing in Phoenix
# configuration defined above (a comment above it would be sorted onto the previous `config`).
# The attribute set on all root tags, used by Phoenix.LiveView.ColocatedCSS.
config :phoenix, :json_library, Jason

config :phoenix_live_view,
  root_tag_attribute: "phx-r"

import_config "#{config_env()}.exs"

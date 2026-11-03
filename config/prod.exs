import Config

# HTTPS enforcement is a runtime choice (`FORCE_SSL`, config/runtime.exs; `ContentoidWeb.ForceSSL`),
# not Phoenix's compile-time `:force_ssl`, so one image serves both behind a TLS proxy and on plain
# HTTP.

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.

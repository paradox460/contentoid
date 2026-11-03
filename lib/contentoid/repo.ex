defmodule Contentoid.Repo do
  use Ecto.Repo,
    otp_app: :contentoid,
    adapter: Ecto.Adapters.Postgres
end

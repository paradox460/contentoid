defmodule Contentoid.Repo.Migrations.AddOban do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Down to version 1 drops Oban's tables entirely.
  def down, do: Oban.Migration.down(version: 1)
end

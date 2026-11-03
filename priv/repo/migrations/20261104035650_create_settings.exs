defmodule Contentoid.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Nil: the configured default (dev/test only); none at all fails downloads that need it.
      add :download_dir, :text
      # Nil: detected (`Contentoid.Downloads.Docker.socket/0`).
      add :docker_socket, :text
      add :max_concurrent_downloads, :integer, null: false, default: 4
      add :log_lines, :integer, null: false, default: 200
      add :stop_grace_seconds, :integer, null: false, default: 2
      add :pull_timeout_minutes, :integer, null: false, default: 30

      timestamps(type: :utc_datetime)
    end

    # One row at most.
    create unique_index(:settings, ["(true)"], name: :settings_singleton_index)
  end
end

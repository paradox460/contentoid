defmodule Contentoid.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  def change do
    create table(:schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :url, :text, null: false
      # Nil: each run takes the scraper that matches the URL.
      add :scraper_id, references(:scrapers, type: :binary_id, on_delete: :nilify_all)
      add :cron, :string, null: false
      add :timezone, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :next_run_at, :utc_datetime
      add :last_run_at, :utc_datetime
      # Why the last run didn't start a download, if it didn't.
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:schedules, [:name])
    create index(:schedules, [:next_run_at], where: "enabled")

    alter table(:downloads) do
      add :schedule_id, references(:schedules, type: :binary_id, on_delete: :nilify_all)
      # A deferred download's start; nil starts it as soon as a slot is free.
      add :start_at, :utc_datetime
    end

    create index(:downloads, [:schedule_id])
  end
end

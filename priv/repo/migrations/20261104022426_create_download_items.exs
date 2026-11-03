defmodule Contentoid.Repo.Migrations.CreateDownloadItems do
  use Ecto.Migration

  def change do
    # What was actually downloaded: one row per finished file, with the URL of what it is.
    create table(:download_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :url, :text, null: false
      add :path, :text, null: false
      # The record outlives its download and scraper.
      add :download_id, references(:downloads, type: :binary_id, on_delete: :nilify_all)
      add :scraper_name, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:download_items, [:url])
    create index(:download_items, [:download_id])
    create index(:download_items, [:inserted_at, :id])
  end
end

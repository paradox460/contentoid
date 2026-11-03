defmodule Contentoid.Repo.Migrations.AddFilesToDownloaders do
  use Ecto.Migration

  def change do
    alter table(:downloaders) do
      # Files kept in Contentoid and put into the container, read-only (`Downloader.ConfigFile`).
      add :files, {:array, :map}, null: false, default: []
    end
  end
end

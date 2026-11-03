defmodule Contentoid.Repo.Migrations.DownloadsBelongToScrapers do
  use Ecto.Migration

  # Grabber keys and the slugs of the default scrapers that replace them.
  @grabbers %{"yt_dlp" => "yt-dlp", "gallery_dl" => "gallery-dl", "aria2c" => "aria2c"}

  def up do
    alter table(:downloads) do
      # A deleted scraper leaves its downloads behind, with its name.
      add :scraper_id, references(:scrapers, type: :binary_id, on_delete: :nilify_all)
      add :scraper_name, :string
    end

    create index(:downloads, [:scraper_id])

    flush()

    for {grabber, slug} <- @grabbers do
      execute("""
      UPDATE downloads SET scraper_id = scrapers.id, scraper_name = scrapers.name
      FROM scrapers WHERE scrapers.slug = '#{slug}' AND downloads.grabber = '#{grabber}'
      """)
    end

    alter table(:downloads) do
      remove :grabber
    end
  end

  def down do
    alter table(:downloads) do
      add :grabber, :string
    end

    flush()

    for {grabber, slug} <- @grabbers do
      execute("""
      UPDATE downloads SET grabber = '#{grabber}'
      FROM scrapers WHERE scrapers.slug = '#{slug}' AND downloads.scraper_id = scrapers.id
      """)
    end

    execute("UPDATE downloads SET grabber = 'yt_dlp' WHERE grabber IS NULL")

    alter table(:downloads) do
      modify :grabber, :string, null: false
      remove :scraper_id
      remove :scraper_name
    end
  end
end

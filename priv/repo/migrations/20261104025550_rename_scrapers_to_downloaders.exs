defmodule Contentoid.Repo.Migrations.RenameScrapersToDownloaders do
  @moduledoc """
  Scrapers are now called downloaders: the table, the columns pointing at it, the indexes and
  foreign keys Ecto's constraint errors are named after, and the Oban queues jobs wait in
  (`scraper-<id>` becomes `downloader-<id>`).
  """
  use Ecto.Migration

  @renames [
    {"INDEX scrapers_pkey", "downloaders_pkey"},
    {"INDEX scrapers_slug_index", "downloaders_slug_index"},
    {"INDEX scrapers_name_index", "downloaders_name_index"},
    {"INDEX downloads_scraper_id_index", "downloads_downloader_id_index"}
  ]

  def up do
    rename table(:scrapers), to: table(:downloaders)
    rename table(:downloads), :scraper_id, to: :downloader_id
    rename table(:downloads), :scraper_name, to: :downloader_name
    rename table(:download_items), :scraper_name, to: :downloader_name
    rename table(:schedules), :scraper_id, to: :downloader_id

    for {object, to} <- @renames, do: execute("ALTER #{object} RENAME TO #{to}")

    execute "ALTER TABLE downloads RENAME CONSTRAINT downloads_scraper_id_fkey TO downloads_downloader_id_fkey"

    execute "ALTER TABLE schedules RENAME CONSTRAINT schedules_scraper_id_fkey TO schedules_downloader_id_fkey"

    execute "UPDATE oban_jobs SET queue = 'downloader-' || substring(queue from 9) WHERE queue LIKE 'scraper-%'"
  end

  def down do
    execute "UPDATE oban_jobs SET queue = 'scraper-' || substring(queue from 12) WHERE queue LIKE 'downloader-%'"

    execute "ALTER TABLE schedules RENAME CONSTRAINT schedules_downloader_id_fkey TO schedules_scraper_id_fkey"

    execute "ALTER TABLE downloads RENAME CONSTRAINT downloads_downloader_id_fkey TO downloads_scraper_id_fkey"

    for {"INDEX " <> from, to} <- @renames, do: execute("ALTER INDEX #{to} RENAME TO #{from}")

    rename table(:schedules), :downloader_id, to: :scraper_id
    rename table(:download_items), :downloader_name, to: :scraper_name
    rename table(:downloads), :downloader_name, to: :scraper_name
    rename table(:downloads), :downloader_id, to: :scraper_id
    rename table(:downloaders), to: table(:scrapers)
  end
end

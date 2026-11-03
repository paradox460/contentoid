defmodule Contentoid.Repo.Migrations.AddArgumentDownloads do
  use Ecto.Migration

  # A downloader takes either a URL (matched by its pattern) or freeform arguments, given by a
  # schedule. An arguments download has no URL, and neither may a file it reports.
  def change do
    alter table(:downloaders) do
      add :input, :string, null: false, default: "url"
      modify :url_pattern, :text, null: true, from: {:text, null: false}
    end

    alter table(:downloads) do
      modify :url, :text, null: true, from: {:text, null: false}
      add :arguments, :text
    end

    alter table(:schedules) do
      modify :url, :text, null: true, from: {:text, null: false}
      add :arguments, :text
    end

    alter table(:download_items) do
      modify :url, :text, null: true, from: {:text, null: false}
    end
  end
end

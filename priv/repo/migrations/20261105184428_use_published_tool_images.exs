defmodule Contentoid.Repo.Migrations.UsePublishedToolImages do
  use Ecto.Migration

  @images [
    {"contentoid-yt-dlp:latest", "ghcr.io/paradox460/contentoid-yt-dlp:latest"},
    {"contentoid-aria2:latest", "ghcr.io/paradox460/contentoid-aria2:latest"},
    {"contentoid-czkawka:latest", "ghcr.io/paradox460/contentoid-czkawka:latest"}
  ]

  # Only rows still on the old local tag: an image someone changed stays theirs.
  def up do
    for {old, new} <- @images, table <- ~w(downloaders post_processors) do
      execute("UPDATE #{table} SET image = '#{new}' WHERE image = '#{old}'")
    end
  end

  def down do
    for {old, new} <- @images, table <- ~w(downloaders post_processors) do
      execute("UPDATE #{table} SET image = '#{old}' WHERE image = '#{new}'")
    end
  end
end

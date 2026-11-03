defmodule Contentoid.Repo.Migrations.DefaultGalleryDlReportsFileProgress do
  @moduledoc """
  The default gallery-dl downloader reports each file as it starts (`[contentoid:start]`), its
  progress (`[contentoid:progress]`, through gallery-dl's `output.mode` formats) and, for a post of
  several files, which of them it is (`[contentoid:total]`). Only a script still exactly as the
  previous migration left it is changed; an edited one is left alone, with a notice.
  """
  use Ecto.Migration

  require Logger

  def up, do: replace(items_only(), with_progress())
  def down, do: replace(with_progress(), items_only())

  defp replace(from, to) do
    %{num_rows: rows} =
      repo().query!(
        "UPDATE downloaders SET script = $1, updated_at = now() WHERE slug = 'gallery-dl' AND script = $2",
        [to, from]
      )

    if rows == 0,
      do:
        Logger.warning("Left the gallery-dl downloader's script alone: it isn't the default one")
  end

  defp items_only do
    ~S"""
    # gallery-dl prints each finished file and the URL it was fetched from in Contentoid's line protocol
    # (`--Print after:`); it reports no progress within a file. A gallery-dl config mounted at
    # /config/gallery-dl is picked up. The archive in the output directory records every file
    # downloaded, so a repeat run skips them.
    export HOME=/tmp XDG_CONFIG_HOME=/config
    exec gallery-dl --no-colors -d "$CONTENTOID_OUTPUT" \
      --download-archive "$CONTENTOID_OUTPUT/.gallery-dl-archive.sqlite3" \
      --Print 'after:[contentoid:item] {_url} {_path}' -- "$CONTENTOID_URL"
    """
  end

  defp with_progress do
    ~S"""
    # gallery-dl reports in Contentoid's line protocol: each file as it starts and its progress
    # (`output.mode` formats, from the first chunk: `downloader.progress=0`), which file of a post of
    # several it is (`--Print prepare:`; gallery-dl can't know a whole gallery's size), and each
    # finished file with the URL it was fetched from (`--Print after:`). A gallery-dl config mounted
    # at /config/gallery-dl is picked up. The archive in the output directory records every file
    # downloaded, so a repeat run skips them.
    export HOME=/tmp XDG_CONFIG_HOME=/config
    exec gallery-dl --no-colors -d "$CONTENTOID_OUTPUT" \
      --download-archive "$CONTENTOID_OUTPUT/.gallery-dl-archive.sqlite3" \
      -o downloader.progress=0 -o output.shorten=false \
      -o 'output.mode={"start": "[contentoid:start] {}\n", "success": "", "skip": "skipped {}\n", "progress": "[contentoid:progress] - {0}B, {1}B/s\n", "progress-total": "[contentoid:progress] {3}% {0}B of {2}B, {1}B/s\n"}' \
      --Print 'prepare:[contentoid:total] {num}/{count} in this post' \
      --Print 'after:[contentoid:item] {_url} {_path}' -- "$CONTENTOID_URL"
    """
  end
end

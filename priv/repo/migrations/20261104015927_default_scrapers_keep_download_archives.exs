defmodule Contentoid.Repo.Migrations.DefaultScrapersKeepDownloadArchives do
  @moduledoc """
  The default yt-dlp and gallery-dl scrapers keep a download archive in their output directory, so a
  repeat run (a schedule re-checking a channel or gallery) skips what's already downloaded.

  Only a script still exactly as the scrapers migration shipped it is changed; an edited one is left
  alone, with a notice. Down reverses it the same way.
  """
  use Ecto.Migration

  require Logger

  def up do
    replace("yt-dlp", yt_dlp_without(), yt_dlp_with())
    replace("gallery-dl", gallery_dl_without(), gallery_dl_with())
  end

  def down do
    replace("yt-dlp", yt_dlp_with(), yt_dlp_without())
    replace("gallery-dl", gallery_dl_with(), gallery_dl_without())
  end

  defp replace(slug, from, to) do
    %{num_rows: rows} =
      repo().query!(
        "UPDATE scrapers SET script = $1, updated_at = now() WHERE slug = $2 AND script = $3",
        [to, slug, from]
      )

    if rows == 0,
      do: Logger.warning("Left the #{slug} scraper's script alone: it isn't the default one")
  end

  defp yt_dlp_without do
    ~S"""
    # yt-dlp reports progress and each finished file through its own print templates, in Contentoid's
    # line protocol. A yt-dlp config mounted at /config/yt-dlp is picked up (XDG_CONFIG_HOME).
    export XDG_CONFIG_HOME=/config
    exec yt-dlp --newline --no-quiet --progress --color never \
      --progress-template 'download:[contentoid:progress] %(progress._percent_str)s %(progress._speed_str)s ETA %(progress._eta_str)s' \
      --print 'after_move:[contentoid:file] %(filepath)s' \
      -P "$CONTENTOID_OUTPUT" -- "$CONTENTOID_URL"
    """
  end

  defp yt_dlp_with do
    ~S"""
    # yt-dlp reports progress and each finished file through its own print templates, in Contentoid's
    # line protocol. A yt-dlp config mounted at /config/yt-dlp is picked up (XDG_CONFIG_HOME). The
    # archive in the output directory records every video downloaded, so a repeat run (a schedule
    # re-checking a channel) skips them.
    export XDG_CONFIG_HOME=/config
    exec yt-dlp --newline --no-quiet --progress --color never \
      --download-archive "$CONTENTOID_OUTPUT/.yt-dlp-archive.txt" \
      --progress-template 'download:[contentoid:progress] %(progress._percent_str)s %(progress._speed_str)s ETA %(progress._eta_str)s' \
      --print 'after_move:[contentoid:file] %(filepath)s' \
      -P "$CONTENTOID_OUTPUT" -- "$CONTENTOID_URL"
    """
  end

  defp gallery_dl_without do
    ~S"""
    # gallery-dl prints each finished file in Contentoid's line protocol (`--Print after:`); it reports
    # no progress within a file. A gallery-dl config mounted at /config/gallery-dl is picked up.
    export HOME=/tmp XDG_CONFIG_HOME=/config
    exec gallery-dl --no-colors -d "$CONTENTOID_OUTPUT" --Print 'after:[contentoid:file] {_path}' -- "$CONTENTOID_URL"
    """
  end

  defp gallery_dl_with do
    ~S"""
    # gallery-dl prints each finished file in Contentoid's line protocol (`--Print after:`); it reports
    # no progress within a file. A gallery-dl config mounted at /config/gallery-dl is picked up. The
    # archive in the output directory records every file downloaded, so a repeat run skips them.
    export HOME=/tmp XDG_CONFIG_HOME=/config
    exec gallery-dl --no-colors -d "$CONTENTOID_OUTPUT" \
      --download-archive "$CONTENTOID_OUTPUT/.gallery-dl-archive.sqlite3" \
      --Print 'after:[contentoid:file] {_path}' -- "$CONTENTOID_URL"
    """
  end
end

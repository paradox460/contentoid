defmodule Contentoid.Downloads.Item do
  @moduledoc """
  Something actually downloaded: one finished file and the URL of what it is (a video's own page
  from a playlist or channel, an image's file URL, or the download's URL when the script didn't
  say; none when an arguments download didn't say), recorded as the script reports it
  (`Contentoid.Downloads.Protocol`). Skipping what's
  already downloaded is left to each tool's own archive; this is the record.
  """
  use Contentoid.Schema

  alias Contentoid.Downloads.Download

  @type t :: %__MODULE__{}

  schema "download_items" do
    # Nil when an arguments download reports a file without one.
    field :url, :string
    # Host path of the file.
    field :path, :string
    # Deleted with it.
    belongs_to :download, Download
    field :downloader_name, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

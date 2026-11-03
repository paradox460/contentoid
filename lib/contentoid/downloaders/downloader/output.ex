defmodule Contentoid.Downloaders.Downloader.Output do
  @moduledoc """
  The downloader's output mount: the host directory (`source`) its files are written to, bound at
  `target` in the container (`$CONTENTOID_OUTPUT`). Created when a download starts.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Contentoid.Downloaders.Downloader

  @primary_key false
  embedded_schema do
    field :source, :string
    field :target, :string, default: "/downloads"
  end

  def changeset(output, attrs) do
    output
    |> cast(attrs, [:source, :target])
    |> validate_required([:source, :target])
    |> Downloader.validate_source()
    |> Downloader.validate_target()
  end
end

defmodule Contentoid.Downloaders.Downloader.Mount do
  @moduledoc """
  A host directory or file (`source`) bound at `target` in the container, such as a tool's config
  directory. Must exist on the host when a download starts.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Contentoid.Downloaders.Downloader

  @primary_key false
  embedded_schema do
    field :source, :string
    field :target, :string
    field :read_only, :boolean, default: true
  end

  def changeset(mount, attrs) do
    mount
    |> cast(attrs, [:source, :target, :read_only])
    |> validate_required([:source, :target])
    |> Downloader.validate_source()
    |> Downloader.validate_target()
  end
end

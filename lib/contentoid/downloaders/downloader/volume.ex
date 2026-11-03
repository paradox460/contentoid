defmodule Contentoid.Downloaders.Downloader.Volume do
  @moduledoc """
  A Docker named volume mounted at `target` in the container, such as a cache kept between
  downloads. Docker creates it on first use; downloaders may share one by name.
  """
  use Ecto.Schema
  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Changeset

  alias Contentoid.Downloaders.Downloader

  @primary_key false
  embedded_schema do
    field :name, :string
    field :target, :string
    field :read_only, :boolean, default: false
  end

  def changeset(volume, attrs) do
    volume
    |> cast(attrs, [:name, :target, :read_only])
    |> validate_required([:name, :target])
    # Docker's own rule for volume names.
    |> validate_format(:name, ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/,
      message: dgettext_noop("errors", "use letters, digits, _ . and -")
    )
    |> Downloader.validate_target()
  end
end

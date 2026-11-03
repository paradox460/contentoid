defmodule Contentoid.Downloaders.Downloader.ConfigFile do
  @moduledoc """
  A file kept in Contentoid and put into the downloader's container before its script starts, at
  `directory/name`, owned by root and read-only (mode 0444): a tool's config, a cookies file, a
  helper script. Missing parent directories are created (root, 0755).
  """
  use Ecto.Schema
  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Changeset

  # Enough for any config or cookies file; the downloader row holds them all.
  @max_bytes 1_048_576

  @primary_key false
  embedded_schema do
    field :name, :string
    field :directory, :string
    field :contents, :string, default: ""
  end

  @doc "Where the file goes in the container."
  def path(%__MODULE__{directory: directory, name: name}), do: Path.join(directory, name)

  def changeset(file, attrs) do
    file
    |> cast(attrs, [:name, :directory, :contents], empty_values: [])
    |> update_change(:name, &String.trim/1)
    |> update_change(:directory, &String.trim/1)
    # Browsers send textarea line ends as CRLF; files keep Unix ones.
    |> update_change(:contents, &String.replace(&1, "\r\n", "\n"))
    |> validate_required([:name, :directory])
    |> validate_format(:name, ~r{^[^/]+$}, message: dgettext_noop("errors", "is a file name, without /"))
    |> validate_exclusion(:name, [".", ".."])
    |> validate_length(:name, max: 255)
    |> validate_format(:directory, ~r{^/\S*$},
      message: dgettext_noop("errors", "must be an absolute path in the container")
    )
    |> validate_length(:contents,
      max: @max_bytes,
      count: :bytes,
      message: dgettext_noop("errors", "must be at most 1 MiB")
    )
  end
end

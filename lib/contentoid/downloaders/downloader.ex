defmodule Contentoid.Downloaders.Downloader do
  @moduledoc """
  A user-defined downloader: a shell script run in a Docker image to download what it's given.

  `input` says what that is. A `:url` downloader takes a URL: it claims the URLs its `url_pattern`
  matches and is offered on the download form. An `:arguments` downloader looks up its content
  itself and takes freeform arguments instead, from a schedule (`Contentoid.Schedules.Schedule`); it
  has no pattern and is never matched to a URL.

  The script runs as `/bin/sh -c SCRIPT contentoid URL` (so the URL is `$1`), or for arguments
  `/bin/sh -c SCRIPT contentoid ARG…`, the arguments split as a shell would (so they're `"$@"`).
  These are in its environment:

    * `CONTENTOID_URL` - the URL to download (URL downloads only)
    * `CONTENTOID_ARGUMENTS` - the arguments as written, unsplit (arguments downloads only)
    * `CONTENTOID_OUTPUT` - the output mount's path in the container; files must be written under it
    * `CONTENTOID_DOWNLOAD_ID` - the download's id

  It reports back on stdout or stderr with Contentoid's line protocol
  (`Contentoid.Downloads.Protocol`); every other line goes to the download's log. It must exit 0 on
  success.

  Mounts bind a host directory into the container: `source` is absolute, starts with `~`, or is
  relative to the download directory. The output mount is required and is where the files go;
  other mounts must exist on the host when a download starts. Volumes are Docker named volumes,
  created on first use. Files (`ConfigFile`) are kept here and put into the container, read-only,
  before the script starts: configuration that lives in Contentoid rather than on the host.

  When several enabled URL downloaders' `url_pattern`s match a URL, the highest `priority` wins.
  `concurrency` is how many of this downloader's downloads run at once (all downloaders together
  are held to the global limit as well, `Contentoid.Downloads.Slots`).
  """
  use Contentoid.Schema
  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Changeset

  alias Contentoid.Downloaders.Downloader.ConfigFile
  alias Contentoid.Downloaders.Downloader.Mount
  alias Contentoid.Downloaders.Downloader.Output
  alias Contentoid.Downloaders.Downloader.Volume
  alias Contentoid.Paths
  alias Contentoid.PostProcessors.Assignment

  @type t :: %__MODULE__{}

  schema "downloaders" do
    field :name, :string
    field :slug, :string
    field :input, Ecto.Enum, values: [:url, :arguments], default: :url
    # Nil for an arguments downloader.
    field :url_pattern, :string
    field :priority, :integer, default: 0
    field :enabled, :boolean, default: true
    field :concurrency, :integer, default: 2
    field :image, :string
    field :script, :string

    embeds_one :output, Output, on_replace: :update
    embeds_many :mounts, Mount, on_replace: :delete
    embeds_many :volumes, Volume, on_replace: :delete
    embeds_many :files, ConfigFile, on_replace: :delete

    # Each with its own arguments; in the order they were added.
    has_many :post_processor_assignments, Assignment, on_replace: :delete, preload_order: [asc: :id]

    timestamps(type: :utc_datetime)
  end

  @fields [:name, :slug, :input, :url_pattern, :priority, :enabled, :concurrency, :image, :script]

  @doc """
  Validates a downloader. A blank slug is made from the name; an arguments downloader's pattern is
  dropped. Mounts, volumes, files and post-processor assignments take `mounts_sort`/`mounts_drop`,
  `volumes_sort`/`volumes_drop`, `files_sort`/`files_drop` and
  `post_processor_assignments_sort`/`_drop` (`Phoenix.Component.inputs_for/1`); assignments must be
  preloaded when they're given.
  """
  def changeset(downloader, attrs) do
    downloader
    |> cast(attrs, @fields, empty_values: [])
    |> update_change(:name, &String.trim/1)
    |> update_change(:image, &String.trim/1)
    |> put_slug()
    |> validate_required([:name, :slug, :input, :priority, :concurrency, :image, :script])
    |> validate_url_pattern()
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/,
      message: dgettext_noop("errors", "use lowercase letters, digits and single dashes")
    )
    |> validate_length(:slug, max: 60)
    |> validate_number(:concurrency, greater_than: 0, less_than_or_equal_to: 32)
    |> cast_embed(:output, required: true)
    |> validate_container_fields()
    |> cast_assoc(:post_processor_assignments,
      with: &Assignment.changeset/2,
      sort_param: :post_processor_assignments_sort,
      drop_param: :post_processor_assignments_drop
    )
    |> then(&validate_container_paths(&1, &1 |> get_field(:output) |> List.wrap() |> Enum.map(fn o -> o.target end)))
    |> unique_constraint(:slug)
    |> unique_constraint(:name)
  end

  @doc ~s{A slug made from `name`: `slugify("My Downloader!")` is `"my-downloader"`.}
  def slugify(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfkd)
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc "The compiled `url_pattern`, or nil when it doesn't compile."
  def regex(%__MODULE__{url_pattern: pattern}) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> regex
      {:error, _reason} -> nil
    end
  end

  def regex(_downloader), do: nil

  defp put_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :name)} do
      {slug, name} when slug in [nil, ""] and is_binary(name) -> put_change(changeset, :slug, slugify(name))
      _other -> update_change(changeset, :slug, &String.trim/1)
    end
  end

  defp validate_url_pattern(changeset) do
    case get_field(changeset, :input) do
      :arguments ->
        put_change(changeset, :url_pattern, nil)

      _url ->
        changeset
        |> validate_required([:url_pattern])
        |> validate_change(:url_pattern, fn :url_pattern, pattern ->
          case Regex.compile(pattern) do
            {:ok, _regex} ->
              []

            {:error, {reason, at}} ->
              [
                url_pattern:
                  {dgettext_noop("errors", "isn't a valid regex: %{reason} at position %{at}"),
                   reason: to_string(reason), at: at}
              ]
          end
        end)
    end
  end

  @doc false
  # Shared with post-processors: the name, the image, and what's bound or put into the container.
  def validate_container_fields(changeset) do
    changeset
    |> validate_length(:name, max: 80)
    |> validate_format(:image, ~r/^\S+$/, message: dgettext_noop("errors", "must not contain spaces"))
    |> cast_embed(:mounts, sort_param: :mounts_sort, drop_param: :mounts_drop)
    |> cast_embed(:volumes, sort_param: :volumes_sort, drop_param: :volumes_drop)
    |> cast_embed(:files, sort_param: :files_sort, drop_param: :files_drop)
  end

  @doc false
  # Shared with post-processors. Two mounts, or a mount and a volume, on one container path would
  # shadow each other. A file put under a mount would land on the host or in the volume, not in the
  # container; and two files can't share a path. `reserved_targets` are mounts the owner always has.
  # A blank target (a row still being filled in) has its own error and takes no part.
  def validate_container_paths(changeset, reserved_targets) do
    targets =
      (reserved_targets ++ Enum.map(get_field(changeset, :mounts) ++ get_field(changeset, :volumes), & &1.target))
      |> Enum.filter(&is_binary/1)

    changeset =
      case targets -- Enum.uniq(targets) do
        [] ->
          changeset

        [target | _rest] ->
          add_error(changeset, :mounts, dgettext_noop("errors", "%{target} is mounted more than once"), target: target)
      end

    paths = changeset |> get_field(:files) |> Enum.filter(&(&1.name && &1.directory)) |> Enum.map(&ConfigFile.path/1)
    duplicate = List.first(paths -- Enum.uniq(paths))
    inside = Enum.find_value(paths, &under_target(&1, targets))

    case {duplicate, inside} do
      {nil, nil} ->
        changeset

      {nil, {path, target}} ->
        add_error(
          changeset,
          :files,
          dgettext_noop("errors", "%{path} is inside the mount at %{target}; files go in the container itself"),
          path: path,
          target: target
        )

      {duplicate, _inside} ->
        add_error(changeset, :files, dgettext_noop("errors", "%{path} is used by more than one file"), path: duplicate)
    end
  end

  defp under_target(path, targets) do
    Enum.find_value(targets, fn target ->
      if Paths.under?(path, target), do: {path, target}
    end)
  end

  @doc false
  # Shared by the embeds: a host path is absolute, starts with ~, or is relative to the download
  # directory without leaving it.
  def validate_source(changeset) do
    validate_change(changeset, :source, fn :source, source ->
      cond do
        String.starts_with?(source, ["/", "~/"]) or source == "~" -> []
        ".." in Path.split(source) -> [source: dgettext_noop("errors", "can't leave the download directory (no ..)")]
        true -> []
      end
    end)
  end

  @doc false
  def validate_target(changeset) do
    changeset
    |> validate_format(:target, ~r{^/\S*$},
      message: dgettext_noop("errors", "must be an absolute path in the container")
    )
    |> validate_exclusion(:target, ["/"], message: dgettext_noop("errors", "can't be the container's root"))
  end
end

defmodule Contentoid.PostProcessors.PostProcessor do
  @moduledoc """
  A user-defined post-processor: a shell script run in a Docker image after a download succeeds, to
  move files, transcode them, find duplicates or anything else. It's assigned to downloaders and to
  schedules (`Contentoid.PostProcessors.Assignment`), each assignment with arguments of its own; a
  download runs its downloader's and schedule's assignments of enabled post-processors, each set of
  arguments once, highest `priority` first (`Contentoid.PostProcessors.for_download/1`). `trigger`
  `:new_files` runs it only when the download has files; `:always` after every successful download.

  The script runs as `/bin/sh -c SCRIPT contentoid ARG…`: the assignment's arguments, split as a
  shell would, are `"$@"`. These are in its environment:

    * `CONTENTOID_FILES` - the download's current files, as paths in this container, one per line
    * `CONTENTOID_ARGUMENTS` - the assignment's arguments as written, unsplit
    * `CONTENTOID_OUTPUT` - `/contentoid/output`, the download's output directory, bound read-write
    * `CONTENTOID_DOWNLOAD_ID` - the download's id
    * `CONTENTOID_DOWNLOADER` - the download's downloader name
    * `CONTENTOID_URL`, or for an arguments download `CONTENTOID_DOWNLOAD_ARGUMENTS` (as written)
      and `CONTENTOID_DOWNLOAD_ARGV` (split as a shell would, one per line)
    * `CONTENTOID_MOUNTS` - host path, tab, container path, a line per bind (the output directory
      first, then the post-processor's and assignment's mounts), to take host paths as arguments

  It reports with the JSON line protocol (`Contentoid.Downloads.Protocol`): `moved` (`from`, `to`),
  `removed` (`path`), `file` (`path`, a new file, recorded with the download's URL unless it gives
  its own `url`), `progress` and `error`. It must exit 0 on success; otherwise the download fails
  and the post-processors after it are skipped.

  Mounts, volumes and files are as a downloader's (`Contentoid.Downloaders.Downloader`), but none
  may be under `/contentoid`. An assignment can add mounts of its own for its runs. A file reported
  outside every mount isn't passed to it.
  """
  use Contentoid.Schema
  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Changeset

  alias Contentoid.Downloaders.Downloader
  alias Contentoid.Downloaders.Downloader.ConfigFile
  alias Contentoid.Downloaders.Downloader.Mount
  alias Contentoid.Downloaders.Downloader.Volume
  alias Contentoid.Paths

  @type t :: %__MODULE__{}

  @output_target "/contentoid/output"

  schema "post_processors" do
    field :name, :string
    field :priority, :integer, default: 0
    field :enabled, :boolean, default: true
    field :trigger, Ecto.Enum, values: [:new_files, :always], default: :new_files
    field :image, :string
    field :script, :string

    embeds_many :mounts, Mount, on_replace: :delete
    embeds_many :volumes, Volume, on_replace: :delete
    embeds_many :files, ConfigFile, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc "The container path of the download's output directory."
  def output_target, do: @output_target

  @doc """
  Validates a post-processor. Mounts, volumes and files take `mounts_sort`/`mounts_drop`,
  `volumes_sort`/`volumes_drop` and `files_sort`/`files_drop` (`Phoenix.Component.inputs_for/1`).
  """
  def changeset(post_processor, attrs) do
    post_processor
    |> cast(attrs, [:name, :priority, :enabled, :trigger, :image, :script], empty_values: [])
    |> update_change(:name, &String.trim/1)
    |> update_change(:image, &String.trim/1)
    |> validate_required([:name, :priority, :trigger, :image, :script])
    |> Downloader.validate_container_fields()
    |> validate_reserved_targets()
    |> Downloader.validate_container_paths([@output_target])
    |> unique_constraint(:name)
  end

  defp validate_reserved_targets(changeset) do
    targets = Enum.map(get_field(changeset, :mounts) ++ get_field(changeset, :volumes), & &1.target)

    case Enum.find(targets, &reserved_target?/1) do
      nil ->
        changeset

      target ->
        add_error(changeset, :mounts, dgettext_noop("errors", "%{target} is inside /contentoid, which Contentoid uses"),
          target: target
        )
    end
  end

  @doc false
  # Shared with assignments' mounts: /contentoid is Contentoid's, for the output directory.
  def reserved_target?(target), do: is_binary(target) and Paths.under?(target, "/contentoid")
end

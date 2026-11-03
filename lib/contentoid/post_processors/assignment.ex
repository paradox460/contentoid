defmodule Contentoid.PostProcessors.Assignment do
  @moduledoc """
  A post-processor assigned to a downloader or a schedule (exactly one), with the `arguments` its
  script gets for that owner: freeform, split as a shell would (`Download.split_arguments/1`) and
  passed as `"$@"`; and `mounts` bound for that owner's runs in addition to the post-processor's
  own, e.g. a different destination directory per schedule. One post-processor can be assigned to
  an owner more than once, with different arguments or mounts. `priority`, when set, replaces the
  post-processor's own for ordering this owner's runs (higher first); nil keeps the post-processor's.

  Its mounts follow the post-processor's rules (`Contentoid.Downloaders.Downloader.Mount`, none
  under `/contentoid`), and can't reuse a container path the post-processor mounts already or cover
  one of its files.
  """
  use Contentoid.Schema
  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Changeset

  alias Contentoid.Downloaders.Downloader
  alias Contentoid.Downloaders.Downloader.ConfigFile
  alias Contentoid.Downloaders.Downloader.Mount
  alias Contentoid.Downloads.Download
  alias Contentoid.Paths
  alias Contentoid.PostProcessors.PostProcessor
  alias Contentoid.Repo
  alias Contentoid.Schedules.Schedule

  @type t :: %__MODULE__{}

  schema "post_processor_assignments" do
    belongs_to :post_processor, PostProcessor
    belongs_to :downloader, Downloader
    belongs_to :schedule, Schedule
    field :arguments, :string
    embeds_many :mounts, Mount, on_replace: :delete
    field :priority, :integer

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates what the owner's form sets: the post-processor, its arguments (blank is none), its
  priority (blank keeps the post-processor's) and mounts (`mounts_sort`/`mounts_drop`, as
  `Phoenix.Component.inputs_for/1` sends them).
  """
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:post_processor_id, :arguments, :priority])
    |> update_change(:arguments, &blank_to_nil/1)
    |> validate_required([:post_processor_id], message: dgettext_noop("errors", "pick a post-processor"))
    |> Download.validate_arguments(:arguments)
    |> cast_embed(:mounts, sort_param: :mounts_sort, drop_param: :mounts_drop)
    |> validate_mounts()
    |> assoc_constraint(:post_processor)
  end

  # Checked against the post-processor as it is now; one edited later to clash fails at its run,
  # when Docker refuses the duplicate mount point.
  defp validate_mounts(changeset) do
    own = changeset |> get_field(:mounts) |> Enum.map(& &1.target) |> Enum.filter(&is_binary/1)
    post_processor = (id = get_field(changeset, :post_processor_id)) && Repo.get(PostProcessor, id)

    {taken, files} =
      case post_processor do
        nil -> {[], []}
        pp -> {Enum.map(pp.mounts ++ pp.volumes, & &1.target), Enum.map(pp.files, &ConfigFile.path/1)}
      end

    covered = Enum.find_value(files, fn path -> Enum.find(own, &Paths.under?(path, &1)) && path end)

    cond do
      reserved = Enum.find(own, &PostProcessor.reserved_target?/1) ->
        add_error(changeset, :mounts, dgettext_noop("errors", "%{target} is inside /contentoid, which Contentoid uses"),
          target: reserved
        )

      already = Enum.find(own, &(&1 in taken)) ->
        add_error(changeset, :mounts, dgettext_noop("errors", "%{target} is mounted by the post-processor already"),
          target: already
        )

      twice = List.first(own -- Enum.uniq(own)) ->
        add_error(changeset, :mounts, dgettext_noop("errors", "%{target} is mounted more than once"), target: twice)

      covered ->
        add_error(changeset, :mounts, dgettext_noop("errors", "would cover the post-processor's file %{path}"),
          path: covered
        )

      true ->
        changeset
    end
  end

  @doc "The arguments as words, for the script's `\"$@\"`."
  @spec argv(t()) :: [String.t()]
  def argv(%__MODULE__{arguments: arguments}), do: Download.split_arguments(arguments)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(arguments) do
    case String.trim(arguments) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end

defmodule Contentoid.Downloads.Download do
  @moduledoc """
  One URL, or one set of arguments, handed to one downloader, and what came of it.

  A URL downloader's download has a `url`; an arguments downloader's (`Downloader.input`) has
  `arguments` instead, possibly none, and no URL. Only those and `downloader_id` are user input
  (`create_changeset/2`); status, progress, files, error and log are set by `Contentoid.Downloads`
  as the run goes. `downloader_name` keeps the downloader's name for when it's deleted
  (`downloader_id` is then nil).

  Status runs `queued` → `running` → `completed` | `failed`, and `queued`/`running` → `cancelled`;
  a retry puts a `failed` or `cancelled` download back to `queued`.

  `phase` is `download` until the downloader exits 0, then `post_processing` when post-processors
  (`Contentoid.PostProcessors.for_download/1`) apply; `output_dir` is then the output mount's host
  directory. A download in phase `post_processing` has already downloaded: a retry runs only
  post-processing, on its files.

  `steps` holds each post-processor run of the latest post-processing attempt, and `log` is only
  the downloader's output.
  """
  use Contentoid.Schema
  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Changeset

  alias Contentoid.Downloaders
  alias Contentoid.Downloaders.Downloader
  alias Contentoid.Downloads.Download.Step
  alias Contentoid.Schedules.Schedule

  @type t :: %__MODULE__{}

  @statuses [:queued, :running, :completed, :failed, :cancelled]

  schema "downloads" do
    # Nil for an arguments download.
    field :url, :string
    # Freeform, split as a shell would (`argv/1`); nil for a URL download.
    field :arguments, :string
    belongs_to :downloader, Downloader
    field :downloader_name, :string
    # The schedule that started it, if one did.
    belongs_to :schedule, Schedule
    # When a deferred download may start; nil starts it as soon as a slot is free.
    field :start_at, :utc_datetime
    # 0-9: a new or retried download goes into line after the last waiting one of the same or higher
    # priority (`position`); a schedule's, else 0.
    field :priority, :integer, default: 0
    # Its place in line while it waits to start (lower first); nil while deferred, running or
    # finished. Set by Contentoid.Downloads, never cast.
    field :position, :integer
    field :status, Ecto.Enum, values: @statuses, default: :queued
    # Fraction of the current file, 0.0 to 1.0; nil when the downloader can't tell.
    field :progress, :float
    field :progress_text, :string
    # The whole download's progress, when the tool can tell (a `total` message); `progress` is the
    # current file's.
    field :total_progress, :float
    field :total_text, :string
    # The file being downloaded now (a `start` message), as a host path.
    field :current_file, :string
    field :files, {:array, :string}, default: []
    embeds_one :error, Contentoid.Message, on_replace: :delete
    field :log, :string
    # Post-processing's runs (Step); `log` is the downloader's own output only.
    embeds_many :steps, Step, on_replace: :delete
    field :exit_status, :integer
    field :oban_job_id, :integer
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :phase, Ecto.Enum, values: [:download, :post_processing], default: :download
    field :output_dir, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Every status, in lifecycle order."
  def statuses, do: @statuses

  @doc """
  Validates a new download: an enabled downloader, whose name it keeps, and what it takes, an http,
  arguments downloader; optionally the schedule starting it, its priority and a time to start at.
  """
  def create_changeset(download, attrs) do
    changeset =
      download
      |> cast(attrs, [:url, :arguments, :downloader_id, :schedule_id, :priority, :start_at])
      |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 9)
      |> update_change(:url, &String.trim/1)
      |> update_change(:arguments, &String.trim/1)
      |> validate_required([:downloader_id],
        message: dgettext_noop("errors", "no enabled downloader matches this URL; pick one")
      )

    # Without a downloader there's only a URL to check.
    case changeset.valid? && Downloaders.get_downloader(get_field(changeset, :downloader_id)) do
      %Downloader{enabled: false, input: input} ->
        changeset |> add_error(:downloader_id, dgettext_noop("errors", "is disabled")) |> validate_input(input)

      %Downloader{input: input, name: name} ->
        changeset |> put_change(:downloader_name, name) |> validate_input(input)

      nil ->
        changeset |> add_error(:downloader_id, dgettext_noop("errors", "doesn't exist")) |> validate_input(:url)

      false ->
        validate_input(changeset, :url)
    end
  end

  @doc "Adds an error to `field` unless it holds an http, https or ftp URL with a host."
  def validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, url ->
      if downloadable_url?(url), do: [], else: [{field, dgettext_noop("errors", "must be an http, https or ftp URL")}]
    end)
  end

  @doc """
  Adds an error to `field` unless its arguments split (`split_arguments/1`): every quote is closed.
  Shared with post-processor assignments.
  """
  def validate_arguments(changeset, field) do
    validate_change(changeset, field, fn ^field, arguments ->
      case split(arguments) do
        {:ok, _argv} -> []
        :error -> [{field, dgettext_noop("errors", "have a quote that's never closed")}]
      end
    end)
  end

  @doc "The download's arguments as words (`split_arguments/1`)."
  @spec argv(t()) :: [String.t()]
  def argv(%__MODULE__{arguments: arguments}), do: split_arguments(arguments)

  @doc """
  Validated arguments split into words as a shell would, honouring quotes and backslashes but
  expanding nothing: `~s(--since "last week" a\\ b)` is `["--since", "last week", "a b"]`. None for
  nil.
  """
  @spec split_arguments(String.t() | nil) :: [String.t()]
  def split_arguments(nil), do: []

  def split_arguments(arguments) do
    {:ok, argv} = split(arguments)
    argv
  end

  defp split(arguments) do
    {:ok, OptionParser.split(arguments)}
  rescue
    # An unclosed quote.
    RuntimeError -> :error
  end

  defp validate_input(changeset, :url) do
    changeset
    |> validate_required([:url])
    |> validate_url(:url)
    |> validate_change(:arguments, fn :arguments, _arguments ->
      [arguments: dgettext_noop("errors", "aren't taken by a URL downloader")]
    end)
  end

  defp validate_input(changeset, :arguments) do
    changeset
    |> validate_change(:url, fn :url, _url ->
      [url: dgettext_noop("errors", "isn't taken by an arguments downloader")]
    end)
    |> validate_arguments(:arguments)
  end

  defp downloadable_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ~w(http https ftp) and host not in [nil, ""] -> true
      _ -> false
    end
  end
end

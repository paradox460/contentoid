defmodule Contentoid.Schedules.Schedule do
  @moduledoc """
  A URL downloaded again on a cron schedule (`Contentoid.Schedules.Cron`), in a time zone: a
  channel, playlist, profile or gallery whose new items each run picks up. Or, pinned to an
  arguments downloader (`Downloader.input`), freeform `arguments` (possibly none) for a downloader
  that looks up its content itself; only a schedule starts such a download.

  `downloader_id` pins the downloader; nil lets each run take the one that matches the URL, as the
  download form would. `next_run_at` is when it runs next (nil while disabled); `last_error` says why
  the last run started nothing, if it didn't.

  `priority` (0-9, higher first) is its downloads': waiting downloads start highest priority first,
  never stopping one already running. `jitter_seconds` delays each due run by a random time up to
  that long (entered as `jitter`, `h:m:s`), so schedules due together don't all start at once.
  """
  use Contentoid.Schema
  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Changeset

  alias Contentoid.Downloaders
  alias Contentoid.Downloaders.Downloader
  alias Contentoid.Downloads.Download
  alias Contentoid.PostProcessors.Assignment
  alias Contentoid.Schedules.Cron

  @type t :: %__MODULE__{}

  schema "schedules" do
    field :name, :string
    # Nil for an arguments schedule.
    field :url, :string
    # Nil for a URL schedule.
    field :arguments, :string
    belongs_to :downloader, Downloader
    field :cron, :string
    field :timezone, :string, default: "Etc/UTC"
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 0
    field :jitter_seconds, :integer, default: 0
    # The form's `h:m:s` for jitter_seconds.
    field :jitter, :string, virtual: true
    field :next_run_at, :utc_datetime
    field :last_run_at, :utc_datetime
    embeds_one :last_error, Contentoid.Message, on_replace: :delete

    # Each with its own arguments; in the order they were added.
    has_many :post_processor_assignments, Assignment, on_replace: :delete, preload_order: [asc: :id]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates what the user sets: name, URL or arguments, downloader, cron expression, time zone,
  enabled, priority (0-9), jitter (`h:m:s`, `m:s` or seconds; blank is none) and post-processor
  assignments (`post_processor_assignments_sort`/`_drop`, as `Phoenix.Component.inputs_for/1` sends
  them; preloaded when given). Which of URL and arguments it takes follows the downloader; the other
  is dropped.
  """
  def changeset(schedule, attrs) do
    schedule
    |> with_jitter_text()
    |> cast(attrs, [:name, :url, :arguments, :downloader_id, :cron, :timezone, :enabled, :priority, :jitter])
    |> update_change(:name, &trim/1)
    |> update_change(:url, &trim/1)
    |> update_change(:arguments, &trim/1)
    |> update_change(:cron, &trim/1)
    |> update_change(:timezone, &trim/1)
    |> validate_required([:name, :cron, :timezone, :priority])
    |> validate_length(:name, max: 80)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 9)
    |> put_jitter()
    |> validate_input()
    |> validate_change(:cron, fn :cron, cron ->
      case Cron.parse(cron) do
        {:ok, _cron} -> []
        {:error, reason} -> [cron: reason]
      end
    end)
    |> validate_change(:timezone, fn :timezone, timezone ->
      if Cron.valid_timezone?(timezone),
        do: [],
        else: [timezone: dgettext_noop("errors", "isn't a time zone (e.g. America/Denver)")]
    end)
    |> foreign_key_constraint(:downloader_id)
    |> cast_assoc(:post_processor_assignments,
      with: &Assignment.changeset/2,
      sort_param: :post_processor_assignments_sort,
      drop_param: :post_processor_assignments_drop
    )
    |> unique_constraint(:name)
  end

  # A field cleared to nil is a change too.
  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)

  # The form shows the saved jitter as text, blank when there's none, so clearing the field (cast to
  # nil) is a change only from a real value.
  defp with_jitter_text(%{jitter: nil, jitter_seconds: seconds} = schedule) when seconds > 0,
    do: %{schedule | jitter: format_duration(seconds)}

  defp with_jitter_text(schedule), do: schedule

  defp put_jitter(changeset) do
    case fetch_change(changeset, :jitter) do
      {:ok, jitter} ->
        case parse_duration(jitter) do
          {:ok, seconds} ->
            put_change(changeset, :jitter_seconds, seconds)

          :error ->
            add_error(changeset, :jitter, dgettext_noop("errors", "must be h:m:s, e.g. 0:30:00 for half an hour"))
        end

      :error ->
        changeset
    end
  end

  @doc """
  Seconds in a duration: `h:m:s`, `m:s` or plain seconds, minutes and seconds under 60 after the
  first part. Blank or nil is 0.
  """
  @spec parse_duration(String.t() | nil) :: {:ok, non_neg_integer()} | :error
  def parse_duration(nil), do: {:ok, 0}

  def parse_duration(text) do
    case String.trim(text) do
      "" -> {:ok, 0}
      trimmed -> trimmed |> String.split(":") |> seconds()
    end
  end

  defp seconds([first | rest] = parts) when length(parts) <= 3 do
    with [first | rest] <- Enum.map([first | rest], &non_negative/1),
         false <- Enum.member?([first | rest], nil),
         true <- Enum.all?(rest, &(&1 < 60)) do
      {:ok, Enum.reduce(rest, first, &(&2 * 60 + &1))}
    else
      _invalid -> :error
    end
  end

  defp seconds(_too_many), do: :error

  defp non_negative(part) do
    case Integer.parse(part) do
      {n, ""} when n >= 0 -> n
      _not_a_number -> nil
    end
  end

  @doc "Seconds as `h:mm:ss`."
  @spec format_duration(non_neg_integer()) :: String.t()
  def format_duration(seconds) do
    pad = &(&1 |> Integer.to_string() |> String.pad_leading(2, "0"))
    "#{div(seconds, 3600)}:#{seconds |> rem(3600) |> div(60) |> pad.()}:#{pad.(rem(seconds, 60))}"
  end

  defp validate_input(changeset) do
    case downloader_input(get_field(changeset, :downloader_id)) do
      :arguments ->
        changeset |> put_change(:url, nil) |> Download.validate_arguments(:arguments)

      :url ->
        changeset |> put_change(:arguments, nil) |> validate_required([:url]) |> Download.validate_url(:url)
    end
  end

  # Unpinned is matched by URL; a missing downloader fails the foreign key.
  defp downloader_input(nil), do: :url

  defp downloader_input(id) do
    case Downloaders.get_downloader(id) do
      %Downloader{input: input} -> input
      nil -> :url
    end
  end
end

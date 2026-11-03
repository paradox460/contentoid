defmodule Contentoid.Schedules do
  @moduledoc """
  Schedules (`Contentoid.Schedules.Schedule`): URLs, or an arguments downloader's arguments,
  downloaded again on a cron schedule.

  A run starts an ordinary download (`Contentoid.Downloads.create_download/1`) tagged with the
  schedule and at its priority, using its downloader or, when it has none, the one that matches the
  URL. A due run with a jitter is deferred by a random time up to it (the download waits queued
  until then); `run_now/1` starts one by hand, at once. A run is skipped while the schedule's
  previous download is still queued (a delayed run included) or running, and the reason kept in
  `last_error`.

  `run_due/1` runs every enabled schedule whose `next_run_at` has passed, then sets the next run
  from now: a schedule that missed several run times while Contentoid was down runs once, then
  carries on. It's called every minute (`Contentoid.Schedules.Ticker`).

  Every change is broadcast to `subscribe/0`rs as `{:schedules, :changed}`.
  """

  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Query

  alias Contentoid.Downloads
  alias Contentoid.Downloads.Download
  alias Contentoid.Message
  alias Contentoid.Repo
  alias Contentoid.Schedules.Cron
  alias Contentoid.Schedules.Schedule
  alias ContentoidWeb.Messages

  require Logger

  @topic "schedules"

  def subscribe, do: Phoenix.PubSub.subscribe(Contentoid.PubSub, @topic)

  @doc "Every schedule by name, with its downloader."
  def list_schedules do
    Schedule |> order_by(:name) |> preload(:downloader) |> Repo.all()
  end

  def get_schedule!(id), do: Schedule |> preload([:downloader, :post_processor_assignments]) |> Repo.get!(id)
  def get_schedule(id), do: Repo.get(Schedule, id)

  @doc "Each schedule's latest download, keyed by schedule id."
  @spec latest_downloads([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => Download.t()}
  def latest_downloads(schedule_ids) do
    from(d in Download,
      where: d.schedule_id in ^schedule_ids,
      distinct: d.schedule_id,
      order_by: [asc: d.schedule_id, desc: d.inserted_at, desc: d.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.schedule_id, &1})
  end

  def change_schedule(%Schedule{} = schedule, attrs \\ %{}), do: Schedule.changeset(schedule, attrs)

  def create_schedule(attrs) do
    %Schedule{} |> Schedule.changeset(attrs) |> put_next_run() |> Repo.insert() |> changed()
  end

  @doc """
  Updates a schedule; a new cron, time zone or enabling it counts the next run from now.
  `attrs` `post_processor_assignments`, when given, replaces its post-processor assignments
  (`Contentoid.PostProcessors.Assignment`).
  """
  def update_schedule(%Schedule{} = schedule, attrs) do
    schedule
    |> Repo.preload(:post_processor_assignments)
    |> Schedule.changeset(attrs)
    |> put_next_run()
    |> Repo.update()
    |> changed()
  end

  @doc "Deletes a schedule. Its downloads stay, no longer tagged with it."
  def delete_schedule(%Schedule{} = schedule), do: schedule |> Repo.delete() |> changed()

  @doc """
  Runs a schedule now, outside its timing, which is left as it was. Returns the download, or why
  there is none.
  """
  @spec run_now(Schedule.t()) :: {:ok, Download.t()} | {:error, Message.t()}
  def run_now(%Schedule{} = schedule) do
    result = start_run(schedule, nil)
    record_run(schedule, result, schedule.next_run_at)
    result
  end

  @doc "Runs every enabled schedule due at `now`. Returns how many ran."
  @spec run_due(DateTime.t()) :: non_neg_integer()
  def run_due(now \\ DateTime.utc_now(:second)) do
    due = Repo.all(from s in Schedule, where: s.enabled and s.next_run_at <= ^now, order_by: s.next_run_at)

    for schedule <- due do
      result = start_run(schedule, delayed_start(schedule, now))

      with {:error, reason} <- result,
           do: Logger.info("Schedule #{schedule.name} started nothing: #{Messages.message_text(reason)}")

      record_run(schedule, result, Cron.next_after(schedule.cron, schedule.timezone, now))
    end

    length(due)
  end

  @doc "The next `count` run times of `cron` in `timezone`, or nil when either is invalid."
  @spec preview(String.t() | nil, String.t() | nil, pos_integer()) :: [DateTime.t()] | nil
  def preview(cron, timezone, count \\ 3)

  def preview(cron, timezone, count) when is_binary(cron) and is_binary(timezone) do
    with {:ok, parsed} <- Cron.parse(cron),
         true <- Cron.valid_timezone?(timezone) do
      Cron.upcoming(parsed, timezone, DateTime.utc_now(), count)
    else
      _invalid -> nil
    end
  end

  def preview(_cron, _timezone, _count), do: nil

  # A random time within the schedule's jitter after `now`, or nil to start at once.
  defp delayed_start(%Schedule{jitter_seconds: jitter}, now) when jitter > 0,
    do: DateTime.add(now, Enum.random(0..jitter))

  defp delayed_start(_schedule, _now), do: nil

  defp start_run(%Schedule{} = schedule, start_at) do
    in_progress? =
      Repo.exists?(from d in Download, where: d.schedule_id == ^schedule.id and d.status in [:queued, :running])

    if in_progress? do
      {:error, Message.new(gettext_noop("skipped: the previous run is still queued or running"))}
    else
      case Downloads.create_download(%{
             url: schedule.url,
             arguments: schedule.arguments,
             downloader_id: schedule.downloader_id,
             schedule_id: schedule.id,
             priority: schedule.priority,
             start_at: start_at
           }) do
        {:ok, download} -> {:ok, download}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_reason(changeset)}
        {:error, reason} -> {:error, Message.text(inspect(reason))}
      end
    end
  end

  # The first error is enough to say why.
  defp changeset_reason(%Ecto.Changeset{errors: [{field, {message, opts}} | _rest]}),
    do: Message.new(gettext_noop("%{field}: %{error}"), field: field, error: Message.error(message, opts))

  defp changeset_reason(%Ecto.Changeset{}), do: Message.new(gettext_noop("the download is invalid"))

  defp record_run(schedule, result, next_run_at) do
    error =
      case result do
        {:error, reason} -> reason
        _ok -> nil
      end

    schedule
    |> Ecto.Changeset.change(last_run_at: DateTime.utc_now(:second), last_error: error, next_run_at: next_run_at)
    |> Repo.update!()
    |> then(&changed({:ok, &1}))
  end

  # Counted from now whenever what decides it changes; nil while disabled.
  defp put_next_run(%Ecto.Changeset{valid?: true} = changeset) do
    timing_changed? = Enum.any?([:cron, :timezone, :enabled], &Map.has_key?(changeset.changes, &1))
    new? = changeset.data.__meta__.state == :built

    cond do
      not Ecto.Changeset.get_field(changeset, :enabled) ->
        Ecto.Changeset.put_change(changeset, :next_run_at, nil)

      new? or timing_changed? ->
        next =
          Cron.next_after(
            Ecto.Changeset.get_field(changeset, :cron),
            Ecto.Changeset.get_field(changeset, :timezone),
            DateTime.utc_now()
          )

        Ecto.Changeset.put_change(changeset, :next_run_at, next)

      true ->
        changeset
    end
  end

  defp put_next_run(changeset), do: changeset

  defp changed({:ok, _schedule} = result) do
    Phoenix.PubSub.broadcast(Contentoid.PubSub, @topic, {:schedules, :changed})
    result
  end

  defp changed(error), do: error
end

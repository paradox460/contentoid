defmodule Contentoid.Schedules.Cron do
  @moduledoc """
  Cron expressions for schedules: standard five fields (`minute hour day month weekday`), plus
  `@hourly`, `@daily`, `@weekly`, `@monthly` and `@yearly`, evaluated in a time zone.

  Run times are worked out in local wall-clock time (`crontab`) and turned into instants here, so
  daylight saving behaves like cron does: a time that doesn't exist (the skipped hour in spring) runs
  when the gap ends, and a time that happens twice (the repeated hour in autumn) runs once, the
  first time.
  """
  use Gettext, backend: ContentoidWeb.Gettext

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @doc """
  Parses `expression`, or explains why it can't: an "errors"-domain msgid and its bindings, as a
  changeset error takes them. Crontab's own explanations are English text with no bindings.
  """
  @spec parse(String.t()) :: {:ok, CronExpression.t()} | {:error, {String.t(), keyword()}}
  def parse(expression) do
    case Parser.parse(String.trim(expression)) do
      {:ok, %CronExpression{reboot: true}} -> {:error, {dgettext_noop("errors", "@reboot isn't a schedule"), []}}
      {:ok, cron} -> {:ok, cron}
      {:error, reason} -> {:error, {reason, []}}
    end
  end

  @doc "Whether `timezone` is a time zone this app knows (IANA names, e.g. `America/Denver`)."
  @spec valid_timezone?(String.t()) :: boolean()
  def valid_timezone?(timezone), do: match?({:ok, _now}, DateTime.now(timezone))

  @doc "The first run strictly after `from` (UTC), as a UTC `DateTime` to the second."
  @spec next_after(CronExpression.t() | String.t(), String.t(), DateTime.t()) :: DateTime.t()
  def next_after(expression, timezone, from) when is_binary(expression) do
    {:ok, cron} = parse(expression)
    next_after(cron, timezone, from)
  end

  def next_after(%CronExpression{} = cron, timezone, %DateTime{} = from) do
    local = from |> DateTime.shift_zone!(timezone) |> DateTime.to_naive()
    # The next whole minute: crontab answers "at or after", and a run is never at `from` itself.
    start = %{NaiveDateTime.add(local, 60) | second: 0, microsecond: {0, 0}}
    {:ok, naive} = Scheduler.get_next_run_date(cron, start)

    case DateTime.from_naive(naive, timezone) do
      {:ok, at} -> utc(at)
      {:gap, _before, just_after} -> utc(just_after)
      {:ambiguous, first, second} -> first |> utc() |> later_than(from, utc(second))
    end
  end

  @doc "The next `count` runs after `from` (UTC), in `timezone`."
  @spec upcoming(CronExpression.t(), String.t(), DateTime.t(), pos_integer()) :: [DateTime.t()]
  def upcoming(%CronExpression{} = cron, timezone, from, count) do
    cron
    |> next_after(timezone, from)
    |> Stream.iterate(&next_after(cron, timezone, &1))
    |> Enum.take(count)
    |> Enum.map(&DateTime.shift_zone!(&1, timezone))
  end

  # The repeated hour's first pass can lie behind `from` when it's computed during the second pass.
  defp later_than(first, from, second), do: if(DateTime.after?(first, from), do: first, else: second)

  defp utc(at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
end

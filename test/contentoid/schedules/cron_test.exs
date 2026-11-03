defmodule Contentoid.Schedules.CronTest do
  use ExUnit.Case, async: true

  alias Contentoid.Schedules.Cron

  # 2026: US clocks spring forward on 8 March at 02:00 and fall back on 1 November at 02:00.
  @denver "America/Denver"

  defp cron(expression) do
    {:ok, cron} = Cron.parse(expression)
    cron
  end

  defp local(at), do: at |> DateTime.shift_zone!(@denver) |> Calendar.strftime("%Y-%m-%d %H:%M %Z")

  test "runs in the schedule's time zone" do
    assert Cron.next_after(cron("0 3 * * *"), @denver, ~U[2026-06-01 12:00:00Z]) == ~U[2026-06-02 09:00:00Z]
  end

  test "a run is strictly after the given time, never at it" do
    assert Cron.next_after(cron("30 * * * *"), "Etc/UTC", ~U[2026-06-01 06:30:00Z]) == ~U[2026-06-01 07:30:00Z]
    assert Cron.next_after(cron("30 * * * *"), "Etc/UTC", ~U[2026-06-01 06:29:59Z]) == ~U[2026-06-01 06:30:00Z]
  end

  test "a time skipped by the spring change runs when the gap ends" do
    runs = cron("30 2 * * *") |> Cron.upcoming(@denver, ~U[2026-03-07 19:00:00Z], 2) |> Enum.map(&local/1)
    assert runs == ["2026-03-08 03:00 MDT", "2026-03-09 02:30 MDT"]
  end

  test "a time repeated by the autumn change runs once" do
    hourly = cron("30 * * * *") |> Cron.upcoming(@denver, ~U[2026-11-01 06:00:00Z], 3) |> Enum.map(&local/1)
    assert hourly == ["2026-11-01 00:30 MDT", "2026-11-01 01:30 MDT", "2026-11-01 02:30 MST"]

    daily = cron("30 1 * * *") |> Cron.upcoming(@denver, ~U[2026-10-31 12:00:00Z], 2) |> Enum.map(&local/1)
    assert daily == ["2026-11-01 01:30 MDT", "2026-11-02 01:30 MST"]
  end

  # Counted from inside the repeated hour's second pass, its first pass is already behind.
  test "never returns a time before the one given" do
    assert Cron.next_after(cron("30 1 * * *"), @denver, ~U[2026-11-01 08:10:00Z]) == ~U[2026-11-01 08:30:00Z]
  end

  test "parse/1 explains what's wrong and rejects @reboot" do
    assert {:error, {"Can't parse 61 as minute.", []}} = Cron.parse("61 * * * *")
    assert {:error, {"@reboot isn't a schedule", []}} = Cron.parse("@reboot")
    assert {:ok, _cron} = Cron.parse(" @weekly ")
  end
end

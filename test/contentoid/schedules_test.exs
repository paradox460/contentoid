defmodule Contentoid.SchedulesTest do
  use Contentoid.DataCase, async: true
  use Oban.Testing, repo: Contentoid.Repo

  import Contentoid.DownloadsFixtures
  import ContentoidWeb.Messages

  alias Contentoid.Downloads
  alias Contentoid.Downloads.Download
  alias Contentoid.Downloads.Worker
  alias Contentoid.Message
  alias Contentoid.Schedules
  alias Contentoid.Schedules.Schedule

  # Makes a schedule due as if its run time passed `ago` seconds back.
  defp due(schedule, ago \\ 60) do
    Repo.update!(Ecto.Changeset.change(schedule, next_run_at: DateTime.add(DateTime.utc_now(:second), -ago)))
  end

  describe "create_schedule/1" do
    test "sets the next run from now, in the schedule's time zone" do
      schedule = schedule_fixture(%{cron: "0 3 * * *", timezone: "America/Denver"})

      assert DateTime.after?(schedule.next_run_at, DateTime.utc_now())
      assert %{hour: 3, minute: 0} = DateTime.shift_zone!(schedule.next_run_at, "America/Denver")
    end

    test "a disabled schedule has no next run" do
      assert %Schedule{next_run_at: nil} = schedule_fixture(%{enabled: false})
    end

    test "rejects a bad cron expression, time zone or URL" do
      assert {:error, changeset} =
               Schedules.create_schedule(%{name: "x", url: "file:///etc", cron: "0 25 * * *", timezone: "Mars/Olympus"})

      assert %{cron: [_], timezone: [_], url: ["must be an http, https or ftp URL"]} = errors_on(changeset)
    end
  end

  describe "update_schedule/2" do
    test "a new cron expression counts the next run from now; a new name doesn't move it" do
      schedule = due(schedule_fixture())

      {:ok, renamed} = Schedules.update_schedule(schedule, %{name: "Renamed"})
      assert renamed.next_run_at == schedule.next_run_at

      {:ok, retimed} = Schedules.update_schedule(renamed, %{cron: "@hourly"})
      assert DateTime.after?(retimed.next_run_at, DateTime.utc_now())
    end

    test "re-enabling counts from now, so the time it was off isn't caught up" do
      schedule = schedule_fixture()
      {:ok, off} = Schedules.update_schedule(schedule, %{enabled: false})
      assert off.next_run_at == nil

      {:ok, on} = Schedules.update_schedule(off, %{enabled: true})
      assert DateTime.after?(on.next_run_at, DateTime.utc_now())
    end
  end

  describe "run_due/1" do
    test "starts a download for each due schedule, tagged with it" do
      downloader = downloader_fixture()
      schedule = due(schedule_fixture(%{downloader_id: downloader.id}))
      _later = schedule_fixture()

      assert Schedules.run_due() == 1

      assert [%Download{schedule_id: schedule_id, downloader_id: downloader_id, url: url}] = Downloads.list_queue()
      assert {schedule_id, downloader_id, url} == {schedule.id, downloader.id, schedule.url}
      assert %Schedule{last_error: nil, last_run_at: %DateTime{}} = Schedules.get_schedule(schedule.id)
    end

    test "a due run starts within the jitter, at the schedule's priority; Run now starts at once" do
      downloader = downloader_fixture()
      schedule = due(schedule_fixture(%{downloader_id: downloader.id, jitter: "0:30:00", priority: 7}))
      before = DateTime.utc_now(:second)

      assert Schedules.run_due(before) == 1
      assert [%Download{priority: 7, start_at: start_at} = delayed] = Downloads.list_queue()
      assert DateTime.compare(start_at, before) != :lt
      assert DateTime.diff(start_at, before) <= 30 * 60
      # Its job waits until then, ahead of a lower-priority one when both may run.
      assert_enqueued(worker: Worker, args: %{download_id: delayed.id}, priority: 2)

      Downloads.cancel_download(delayed)
      assert {:ok, %Download{start_at: nil, priority: 7}} = Schedules.run_now(schedule)
    end

    test "after missing several run times, runs once and then counts from now" do
      schedule = due(schedule_fixture(%{cron: "@hourly"}), 5 * 3600)

      assert Schedules.run_due() == 1
      assert Schedules.run_due() == 0

      assert [_one] = Downloads.list_queue()
      assert DateTime.after?(Schedules.get_schedule(schedule.id).next_run_at, DateTime.utc_now())
    end

    test "without a pinned downloader, takes the one that matches the URL" do
      downloader = downloader_fixture(%{url_pattern: "^https://subs\\.test/", priority: 5_000_001})
      due(schedule_fixture(%{url: "https://subs.test/u/1"}))

      Schedules.run_due()

      assert [%Download{downloader_id: downloader_id}] = Downloads.list_queue()
      assert downloader_id == downloader.id
    end

    test "skips a run while the previous one is still in flight, saying why" do
      schedule = due(schedule_fixture())
      Schedules.run_due()

      schedule = due(Schedules.get_schedule(schedule.id))
      Schedules.run_due()

      assert [_only_the_first] = Downloads.list_queue()

      assert %Schedule{last_error: %Message{msgid: "skipped: the previous run is still queued or running"}} =
               Schedules.get_schedule(schedule.id)
    end

    test "keeps why a run started nothing" do
      # No default downloader takes an ftp URL without a file extension.
      schedule = due(schedule_fixture(%{url: "ftp://nomatch.test/dir"}))

      Schedules.run_due()

      assert %Schedule{last_error: %Message{} = error} = Schedules.get_schedule(schedule.id)
      assert message_text(error) == "downloader_id: no enabled downloader matches this URL; pick one"
    end

    test "leaves disabled schedules alone" do
      schedule = schedule_fixture(%{enabled: false})
      Repo.update!(Ecto.Changeset.change(schedule, next_run_at: ~U[2026-01-01 00:00:00Z]))

      assert Schedules.run_due() == 0
    end
  end

  describe "priority and jitter" do
    test "jitter takes h:m:s, m:s or seconds, and shows as h:mm:ss" do
      for {text, seconds} <- [{"1:30:05", 5405}, {"10:00", 600}, {"45", 45}, {" ", 0}, {"", 0}] do
        assert Schedule.parse_duration(text) == {:ok, seconds}, text
      end

      for text <- ["1:60:00", "1:2:3:4", "-5", "1h", "1::2"] do
        assert Schedule.parse_duration(text) == :error, text
      end

      assert Schedule.format_duration(5405) == "1:30:05"
    end

    test "a schedule's jitter is saved as seconds, shown again, and cleared by a blank" do
      schedule = schedule_fixture(%{jitter: "0:15:00"})
      assert schedule.jitter_seconds == 900
      assert Schedules.change_schedule(schedule).data.jitter == "0:15:00"

      {:ok, cleared} = Schedules.update_schedule(schedule, %{"jitter" => ""})
      assert cleared.jitter_seconds == 0
    end

    test "rejects a priority outside 0-9 and a malformed jitter" do
      assert {:error, changeset} =
               Schedules.create_schedule(%{
                 name: "x",
                 url: "https://e.test/x",
                 cron: "@daily",
                 priority: 10,
                 jitter: "1:99"
               })

      assert %{priority: [_], jitter: ["must be h:m:s, e.g. 0:30:00 for half an hour"]} = errors_on(changeset)
    end
  end

  test "run_now/1 runs outside the timing, which stays as it was" do
    schedule = schedule_fixture()

    assert {:ok, %Download{schedule_id: id}} = Schedules.run_now(schedule)
    assert id == schedule.id
    assert Schedules.get_schedule(schedule.id).next_run_at == schedule.next_run_at
  end

  describe "arguments schedules" do
    test "run_now/1 starts a download of the arguments, with no URL" do
      downloader = downloader_fixture(%{input: :arguments})
      schedule = schedule_fixture(%{url: nil, downloader_id: downloader.id, arguments: ~s(--feed "new music")})

      assert {:ok, %Download{url: nil, arguments: ~s(--feed "new music"), schedule_id: id}} =
               Schedules.run_now(schedule)

      assert id == schedule.id
      assert %Schedule{last_error: nil} = Schedules.get_schedule(schedule.id)
    end

    test "take what the pinned downloader takes, dropping the other" do
      arguments = downloader_fixture(%{input: :arguments})
      schedule = schedule_fixture()

      {:ok, switched} = Schedules.update_schedule(schedule, %{downloader_id: arguments.id, arguments: "--all"})
      assert %Schedule{url: nil, arguments: "--all"} = switched

      {:ok, back} = Schedules.update_schedule(switched, %{downloader_id: nil, url: "https://example.com/c"})
      assert %Schedule{url: "https://example.com/c", arguments: nil} = back

      assert {:error, changeset} = Schedules.update_schedule(back, %{downloader_id: nil, url: nil})
      assert %{url: ["can't be blank"]} = errors_on(changeset)
    end

    test "reject an unclosed quote" do
      downloader = downloader_fixture(%{input: :arguments})

      assert {:error, changeset} =
               Schedules.create_schedule(%{
                 name: "x",
                 downloader_id: downloader.id,
                 arguments: ~s(--q 'open),
                 cron: "@daily",
                 timezone: "Etc/UTC"
               })

      assert %{arguments: ["have a quote that's never closed"]} = errors_on(changeset)
    end
  end

  test "deleting a schedule keeps its downloads" do
    schedule = schedule_fixture()
    {:ok, download} = Schedules.run_now(schedule)

    {:ok, _deleted} = Schedules.delete_schedule(schedule)

    assert %Download{schedule_id: nil} = Downloads.get_download!(download.id)
  end
end

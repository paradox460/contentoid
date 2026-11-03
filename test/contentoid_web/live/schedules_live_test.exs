defmodule ContentoidWeb.SchedulesLiveTest do
  use ContentoidWeb.ConnCase, async: true

  import Contentoid.DownloadsFixtures
  import Phoenix.LiveViewTest

  alias Contentoid.Downloads
  alias Contentoid.Schedules

  setup %{conn: conn} do
    %{conn: put_connect_params(conn, %{"timezone" => "America/Denver"})}
  end

  test "creates a schedule in the viewer's time zone, previewing its runs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/schedules/new")
    assert has_element?(view, ~s(input[name="schedule[timezone]"][value="America/Denver"]))

    view |> form("#schedule-form", schedule: %{cron: "0 9 * * 1-5"}) |> render_change()
    # Each run, shown in the schedule's zone, is 09:00 on a weekday there.
    runs =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#schedule-preview time")
      |> LazyHTML.attribute("datetime")

    assert [_ | _] = runs

    for run <- runs do
      {:ok, at, _offset} = DateTime.from_iso8601(run)
      local = DateTime.shift_zone!(at, "America/Denver")
      assert local.hour == 9
      assert Date.day_of_week(local) in 1..5
    end

    assert has_element?(view, "#schedule-preview time[data-time-zone='America/Denver']")

    {:ok, _view, html} =
      view
      |> form("#schedule-form",
        schedule: %{name: "Weekday videos", url: "https://example.com/c/weekday", cron: "0 9 * * 1-5"}
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/schedules")

    assert html =~ "Saved Weekday videos."
    assert [%{timezone: "America/Denver", next_run_at: %DateTime{}}] = Schedules.list_schedules()
  end

  test "says what's wrong with a cron expression", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/schedules/new")

    html = view |> form("#schedule-form", schedule: %{cron: "0 25 * * *"}) |> render_change()

    assert html =~ "Can&#39;t parse 25 as hour."
    refute has_element?(view, "#schedule-preview")
  end

  test "lists schedules with next runs in the viewer's time zone, and switches them off", %{conn: conn} do
    schedule = schedule_fixture(%{cron: "0 3 * * *", timezone: "Etc/UTC"})
    {:ok, view, _html} = live(conn, ~p"/schedules")

    assert has_element?(view, "#schedules-#{schedule.id} time[datetime='#{DateTime.to_iso8601(schedule.next_run_at)}']")

    view |> element("#schedules-#{schedule.id} button", "On") |> render_click()
    refute Schedules.get_schedule(schedule.id).enabled
    assert has_element?(view, "#schedules-#{schedule.id}", "off")
  end

  test "runs a schedule now and links its download", %{conn: conn} do
    schedule = schedule_fixture()
    {:ok, view, _html} = live(conn, ~p"/schedules")

    view |> element("#schedules-#{schedule.id} button", "Run now") |> render_click()

    [download] = Downloads.list_queue()
    assert download.schedule_id == schedule.id
    assert has_element?(view, ~s(#schedules-#{schedule.id} a[href="/downloads/#{download.id}"]), "Queued")
  end

  test "the last run follows its download's status, not its progress", %{conn: conn} do
    schedule = schedule_fixture()
    {:ok, view, _html} = live(conn, ~p"/schedules")
    {:ok, download} = Schedules.run_now(schedule)
    last_run = ~s(#schedules-#{schedule.id} a[href="/downloads/#{download.id}"])
    assert has_element?(view, last_run, "Queued")

    {:ok, running} = Downloads.mark_running(download)
    assert has_element?(view, last_run, "Running")

    Downloads.record_progress(running, progress: 0.5)
    assert has_element?(view, last_run, "Running")

    Downloads.finish(running, status: :completed, exit_status: 0)
    assert has_element?(view, last_run, "Completed")
  end

  test "picking an arguments downloader swaps the URL for arguments", %{conn: conn} do
    downloader = downloader_fixture(%{input: :arguments})
    {:ok, view, _html} = live(conn, ~p"/schedules/new")
    assert has_element?(view, ~s(input[name="schedule[url]"]))

    view |> form("#schedule-form", schedule: %{downloader_id: downloader.id}) |> render_change()
    refute has_element?(view, ~s(input[name="schedule[url]"]))

    {:ok, _view, _html} =
      view
      |> form("#schedule-form", schedule: %{name: "Feeds", downloader_id: downloader.id, arguments: "--all"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/schedules")

    assert [%{url: nil, arguments: "--all"}] = Schedules.list_schedules()
  end

  test "runs an arguments schedule now", %{conn: conn} do
    downloader = downloader_fixture(%{input: :arguments})
    schedule = schedule_fixture(%{url: nil, downloader_id: downloader.id, arguments: "--all"})
    {:ok, view, _html} = live(conn, ~p"/schedules")
    assert has_element?(view, "#schedules-#{schedule.id} code", "--all")

    view |> element("#schedules-#{schedule.id} button", "Run now") |> render_click()

    [download] = Downloads.list_queue()
    assert {download.url, download.arguments} == {nil, "--all"}
    assert has_element?(view, ~s(#schedules-#{schedule.id} a[href="/downloads/#{download.id}"]), "Queued")
  end

  test "deletes a schedule", %{conn: conn} do
    schedule = schedule_fixture()
    {:ok, view, _html} = live(conn, ~p"/schedules")

    view |> element("#schedules-#{schedule.id} button", "Delete") |> render_click()

    refute has_element?(view, "#schedules-#{schedule.id}")
    assert Schedules.list_schedules() == []
  end

  test "assigns a post-processor with arguments to a schedule", %{conn: conn} do
    post_processor = post_processor_fixture()
    schedule = schedule_fixture()
    {:ok, view, _html} = live(conn, ~p"/schedules/#{schedule}/edit")

    view |> element("#schedule-form") |> render_change(%{schedule: %{post_processor_assignments_sort: ["new"]}})

    {:ok, _view, _html} =
      view
      |> form("#schedule-form",
        schedule: %{
          post_processor_assignments: %{"0" => %{post_processor_id: post_processor.id, arguments: "--only mp4"}}
        }
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/schedules")

    assert [%{post_processor_id: id, arguments: "--only mp4"}] =
             Schedules.get_schedule!(schedule.id).post_processor_assignments

    assert id == post_processor.id
  end

  test "gives an assigned post-processor mounts of its own on a schedule", %{conn: conn} do
    post_processor = post_processor_fixture()
    schedule = schedule_fixture()
    {:ok, view, _html} = live(conn, ~p"/schedules/#{schedule}/edit")

    # "Add post-processor", then that row's "Add mount".
    view |> element("#schedule-form") |> render_change(%{schedule: %{post_processor_assignments_sort: ["new"]}})

    view
    |> element("#schedule-form")
    |> render_change(%{schedule: %{post_processor_assignments: %{"0" => %{mounts_sort: ["new"]}}}})

    assert has_element?(view, ~s(input[name="schedule[post_processor_assignments][0][mounts][0][source]"]))

    {:ok, _view, _html} =
      view
      |> form("#schedule-form",
        schedule: %{
          post_processor_assignments: %{
            "0" => %{
              post_processor_id: post_processor.id,
              mounts: %{"0" => %{source: "/mnt/Media/Films", target: "/dest", read_only: false}}
            }
          }
        }
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/schedules")

    assert [%{mounts: [%{source: "/mnt/Media/Films", target: "/dest", read_only: false}]}] =
             Schedules.get_schedule!(schedule.id).post_processor_assignments
  end
end

defmodule ContentoidWeb.DownloadsLiveTest do
  # Docker is `Contentoid.FakeDocker`, shared with the LiveView process; the download directory is
  # shared. Hence not async.
  use ContentoidWeb.ConnCase, async: false
  use Oban.Testing, repo: Contentoid.Repo

  import Contentoid.DownloadsFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Contentoid.Downloaders
  alias Contentoid.Downloads
  alias Contentoid.Downloads.Download
  alias Contentoid.Downloads.Download.Step
  alias Contentoid.Downloads.Queues
  alias Contentoid.Downloads.Slots
  alias Contentoid.Downloads.Worker
  alias Contentoid.FakeDocker
  alias Contentoid.Repo

  setup do
    Req.Test.set_req_test_to_shared()
    reset_download_dir()
    FakeDocker.start()
    :ok
  end

  test "says when Docker isn't answering", %{conn: conn} do
    FakeDocker.start(down?: true)
    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert has_element?(view, "#docker-problem", "Docker isn't answering")
  end

  test "the app opens on the downloads page, marked current in the navigation", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/downloads"

    {:ok, view, _html} = live(conn, ~p"/downloads")
    assert has_element?(view, ~s(#app-nav a[href="/downloads"][aria-current="page"]), "Downloads")
    refute has_element?(view, "#app-nav a[aria-current='page']", "Downloaders")
  end

  test "shows no notice when Docker answers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/downloads")
    refute has_element?(view, "#docker-problem")
  end

  test "queues a URL with the chosen downloader and lists it", %{conn: conn} do
    downloader = downloader_fixture(%{name: "Example videos"})
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view
    |> form("#download-form", download: %{url: "https://example.com/watch?v=1", downloader_id: downloader.id})
    |> render_submit()

    [download] = Downloads.list_queue()
    assert_enqueued(worker: Worker, args: %{download_id: download.id}, queue: Queues.name(downloader))
    assert has_element?(view, "#downloads-#{download.id}", "https://example.com/watch?v=1")
    assert has_element?(view, "#downloads-#{download.id}", "Example videos")
    assert has_element?(view, "#downloads-#{download.id}", "Queued")
  end

  # Submitted before the URL's change event picked one.
  test "queues a URL submitted with no downloader picked, using the matching one", %{conn: conn} do
    downloader = downloader_fixture(%{url_pattern: "^https://submit\\.test/", priority: 4_000_001})
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view
    |> form("#download-form", download: %{url: "https://submit.test/v", downloader_id: ""})
    |> render_submit()

    assert [%{downloader_id: downloader_id}] = Downloads.list_queue()
    assert downloader_id == downloader.id
  end

  test "queues one download per line, in order, each matched on its own", %{conn: conn} do
    videos = downloader_fixture(%{url_pattern: "^https://videos\\.test/", priority: 4_000_002})
    files = downloader_fixture(%{url_pattern: "^https://files\\.test/", priority: 4_000_003})
    {:ok, view, _html} = live(conn, ~p"/downloads")

    urls = "https://videos.test/a\n\n  https://files.test/b  \r\nhttps://videos.test/c\n"
    view |> form("#download-form", download: %{url: urls}) |> render_change()
    # The lines match different downloaders, so none is pre-chosen.
    refute has_element?(view, "#download-form select option[selected]")

    view |> form("#download-form", download: %{url: urls}) |> render_submit()

    assert [a, b, c] = Downloads.list_queue()
    assert {a.url, a.downloader_id} == {"https://videos.test/a", videos.id}
    assert {b.url, b.downloader_id} == {"https://files.test/b", files.id}
    assert {c.url, c.downloader_id} == {"https://videos.test/c", videos.id}
    assert render(view) =~ "Queued 3 downloads."
  end

  # No downloader picked: a line that isn't a URL only says so, not also that nothing matches it.
  test "queues nothing when a line is wrong, and says which", %{conn: conn} do
    downloader_fixture(%{url_pattern: "^https://example\\.com/", priority: 4_000_004})
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view
    |> form("#download-form", download: %{url: "https://example.com/a\nexample.com/b\n\nftp:/c", downloader_id: ""})
    |> render_submit()

    assert Downloads.list_queue() == []
    assert has_element?(view, "#download-form", "line 2: must be an http, https or ftp URL")
    assert has_element?(view, "#download-form", "line 4: must be an http, https or ftp URL")
    refute has_element?(view, "#download-form", "line 1:")
    refute has_element?(view, "#download-form", "no enabled downloader matches")
  end

  test "defers a download to a start time read in the viewer's time zone", %{conn: conn} do
    downloader = downloader_fixture()
    conn = put_connect_params(conn, %{"timezone" => "America/Denver"})
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view
    |> form("#download-form", download: %{url: "https://example.com/later", downloader_id: downloader.id})
    |> render_submit(%{start_at_local: "2099-01-15T03:00"})

    # 03:00 in Denver in January (MST, UTC-7).
    assert [%{start_at: ~U[2099-01-15 10:00:00Z]} = download] = Downloads.list_queue()
    assert has_element?(view, "#downloads-#{download.id} time[datetime='2099-01-15T10:00:00Z']")
  end

  test "shows why a URL is rejected", %{conn: conn} do
    downloader = downloader_fixture()
    {:ok, view, _html} = live(conn, ~p"/downloads")

    html =
      view
      |> form("#download-form", download: %{url: "ftp:/nohost", downloader_id: downloader.id})
      |> render_submit()

    assert html =~ "must be an http, https or ftp URL"
    assert Downloads.list_queue() == []
  end

  test "suggests the matching downloader from the URL until one is picked", %{conn: conn} do
    videos = downloader_fixture(%{url_pattern: "^https://videos\\.test/", priority: 2_000_001})
    files = downloader_fixture(%{url_pattern: "\\.zip$", priority: 2_000_002})
    {:ok, view, _html} = live(conn, ~p"/downloads")

    change = fn target, url, downloader_id ->
      render_change(view, "validate", %{
        "_target" => ["download", target],
        "download" => %{"url" => url, "downloader_id" => downloader_id}
      })
    end

    change.("url", "https://videos.test/a.zip", "")
    assert has_element?(view, ~s(#download-form option[value="#{files.id}"][selected]))

    change.("url", "https://videos.test/watch", files.id)
    assert has_element?(view, ~s(#download-form option[value="#{videos.id}"][selected]))

    change.("downloader_id", "https://videos.test/watch", files.id)
    change.("url", "https://videos.test/other", files.id)
    assert has_element?(view, ~s(#download-form option[value="#{files.id}"][selected]))
  end

  test "offers only enabled downloaders, and follows downloader changes", %{conn: conn} do
    downloader = downloader_fixture(%{name: "Soon off"})
    {:ok, view, _html} = live(conn, ~p"/downloads")
    assert has_element?(view, ~s(#download-form option[value="#{downloader.id}"]))

    {:ok, _disabled} = Downloaders.update_downloader(downloader, %{enabled: false})

    refute has_element?(view, ~s(#download-form option[value="#{downloader.id}"]))
  end

  test "updates a listed download as it changes", %{conn: conn} do
    download = download_fixture()
    {:ok, view, _html} = live(conn, ~p"/downloads")

    {:ok, running} = Downloads.mark_running(download)
    Downloads.record_progress(running, progress: 0.42, progress_text: "1.0 MiB/s · ETA 0:10")

    assert render(view) =~ "42%"
    assert has_element?(view, "#downloads-#{download.id}", "1.0 MiB/s · ETA 0:10")
  end

  test "formats progress in the browser's locale", %{conn: conn} do
    download = download_fixture()
    conn = put_req_header(conn, "accept-language", "de")
    {:ok, view, _html} = live(conn, ~p"/downloads")

    {:ok, running} = Downloads.mark_running(download)
    Downloads.record_progress(running, progress: 0.42)

    # German puts a no-break space before the percent sign.
    assert has_element?(view, "#downloads-#{download.id}", "42\u00A0%")
  end

  test "shows a bar for the whole download beside the current file's, when there's a total", %{conn: conn} do
    {:ok, running} = Downloads.mark_running(download_fixture())
    {:ok, view, _html} = live(conn, ~p"/downloads/#{running}")
    row = "#downloads-#{running.id}"

    Downloads.record_progress(running, progress: 0.4, current_file: "/pics/post/03.jpg")
    assert has_element?(view, "#{row} progress[aria-label='Current file: 40%']")
    refute has_element?(view, "#{row} .download-progress--total")

    Downloads.record_progress(running, total_progress: 0.25, total_text: "3 of 12 in this post")
    assert has_element?(view, "#{row} progress[aria-label='Total: 25%']")
    assert has_element?(view, "#{row} .download-progress--total", "3 of 12 in this post")
    # The file's name is in the open download only; the row has no room for it.
    assert has_element?(view, "#download-#{running.id} .download-current-file", "03.jpg")
    refute has_element?(view, "#{row} .download-current-file")
  end

  test "an open download lists its files with their URLs, as they finish", %{conn: conn} do
    {:ok, running} = Downloads.mark_running(download_fixture())
    {:ok, view, _html} = live(conn, ~p"/downloads/#{running}")

    Downloads.record_item(running, "https://videos.test/watch?v=1", "/lib/one.mp4")
    Downloads.record_progress(running, files: ["/lib/one.mp4"])

    assert has_element?(view, ~s(#download-#{running.id} a[href="https://videos.test/watch?v=1"]))
    assert has_element?(view, "#download-#{running.id}", "/lib/one.mp4")
  end

  test "opens a download with its error and log, and retries it", %{conn: conn} do
    failed = failed_download_fixture(%{}, "ERROR: gone")
    {:ok, view, _html} = live(conn, ~p"/downloads/#{failed}")

    assert has_element?(view, "#download-#{failed.id} .download-error", "ERROR: gone")
    assert has_element?(view, "#download-#{failed.id} .download-log", "first line")

    view |> element("#download-#{failed.id} button", "Retry") |> render_click()

    assert %{status: :queued} = Downloads.get_download!(failed.id)
    assert has_element?(view, "#download-#{failed.id}", "Queued")
  end

  test "shows the downloader's log and each post-processor's under its own heading", %{conn: conn} do
    {:ok, running} = Downloads.mark_running(download_fixture())
    Downloads.record_progress(running, phase: :post_processing, log: "fetched video.mp4")

    steps = [
      %Step{
        name: "Move",
        status: :succeeded,
        started_at: ~U[2026-11-05 10:00:00Z],
        finished_at: ~U[2026-11-05 10:00:42Z],
        exit_status: 0,
        log: "moved video.mp4"
      },
      %Step{
        name: "Transcode",
        status: :failed,
        started_at: ~U[2026-11-05 10:00:42Z],
        finished_at: ~U[2026-11-05 10:01:00Z],
        exit_status: 1,
        log: "ffmpeg failed"
      },
      %Step{name: "Dedupe", status: :pending}
    ]

    Downloads.finish(running, status: :failed, error: Contentoid.Message.text("ffmpeg failed"), steps: steps)
    {:ok, view, _html} = live(conn, ~p"/downloads/#{running}")
    id = running.id

    assert has_element?(view, "#download-#{id}-step-download-succeeded .download-log", "fetched video.mp4")
    assert has_element?(view, "#download-#{id}-step-0-succeeded", "Move")
    refute has_element?(view, "#download-#{id}-step-0-succeeded[open]")
    assert has_element?(view, "#download-#{id}-step-1-failed[open] .download-log", "ffmpeg failed")
    # A finished download's pending step never ran.
    assert has_element?(view, "#download-#{id}-step-2-skipped", "Dedupe")
  end

  test "a download that failed in post-processing offers to retry only that", %{conn: conn} do
    failed = failed_download_fixture()
    Repo.update_all(from(d in Download, where: d.id == ^failed.id), set: [phase: :post_processing])
    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert has_element?(view, "#finished-downloads-#{failed.id} button", "Retry post-processing")
  end

  test "cancels a queued download, moving it to the finished table", %{conn: conn} do
    download = download_fixture()
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view |> element("#downloads-#{download.id} button", "Cancel") |> render_click()

    assert %{status: :cancelled} = Downloads.get_download!(download.id)
    refute has_element?(view, "#downloads-#{download.id}")
    assert has_element?(view, "#finished-downloads-#{download.id}", "Cancelled")
  end

  test "lists the running downloads first, then the queued ones in the order they run", %{conn: conn} do
    downloader = downloader_fixture()
    first = download_fixture(%{downloader_id: downloader.id})
    deferred = download_fixture(%{downloader_id: downloader.id, start_at: ~U[2099-01-01 00:00:00Z]})
    second = download_fixture(%{downloader_id: downloader.id})
    {:ok, running} = Downloads.mark_running(download_fixture(%{downloader_id: downloader.id}))
    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert queue_order(view) == Enum.map([running, first, second, deferred], &"downloads-#{&1.id}")

    # Finished, it leaves the queue; retried, it goes back in behind what was already waiting.
    Downloads.finish(running, status: :failed, error: Contentoid.Message.text("gone"))
    assert has_element?(view, "#finished-downloads-#{running.id}", "Failed")
    assert queue_order(view) == Enum.map([first, second, deferred], &"downloads-#{&1.id}")

    view |> element("#finished-downloads-#{running.id} button", "Retry") |> render_click()
    refute has_element?(view, "#finished-downloads-#{running.id}")
    assert queue_order(view) == Enum.map([first, second, running, deferred], &"downloads-#{&1.id}")
  end

  test "pauses and resumes the queue, saved and applied to the slots", %{conn: conn} do
    on_exit(fn -> Downloads.resume_queue() end)
    {:ok, view, _html} = live(conn, ~p"/downloads")
    refute has_element?(view, "#queue-paused")

    view |> element("#queue-pause") |> render_click()
    assert has_element?(view, "#queue-paused")
    assert has_element?(view, "#queue-pause", "Resume queue")
    assert Slots.info().paused
    assert Downloads.queue_paused?()

    view |> element("#queue-pause") |> render_click()
    refute has_element?(view, "#queue-paused")
    refute Slots.info().paused
    refute Downloads.queue_paused?()
  end

  test "a drop reorders the waiting downloads; a deferred one has no grip", %{conn: conn} do
    downloader = downloader_fixture()
    [a, b, c] = for _ <- 1..3, do: download_fixture(%{downloader_id: downloader.id})
    deferred = download_fixture(%{downloader_id: downloader.id, start_at: ~U[2099-01-01 00:00:00Z]})
    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert has_element?(view, "#downloads-#{a.id} [data-drag-handle]")
    refute has_element?(view, "#downloads-#{deferred.id} [data-drag-handle]")

    view |> element("#downloads") |> render_hook("reorder_queue", %{"ids" => [c.id, a.id, b.id]})
    assert queue_order(view) == Enum.map([c, a, b, deferred], &"downloads-#{&1.id}")

    view |> element("#downloads") |> render_hook("reorder_queue", %{"ids" => [deferred.id, a.id]})
    assert render(view) =~ "The queue changed while you dragged"
    assert queue_order(view) == Enum.map([c, a, b, deferred], &"downloads-#{&1.id}")
  end

  test "start now moves a deferred download to the front of the line", %{conn: conn} do
    downloader = downloader_fixture()
    waiting = download_fixture(%{downloader_id: downloader.id})
    deferred = download_fixture(%{downloader_id: downloader.id, start_at: ~U[2099-01-01 00:00:00Z]})
    {:ok, view, _html} = live(conn, ~p"/downloads")
    assert has_element?(view, "#downloads-#{deferred.id}", "Starts")

    view |> element("#downloads-#{deferred.id} button", "Start now") |> render_click()

    assert queue_order(view) == Enum.map([deferred, waiting], &"downloads-#{&1.id}")
    refute has_element?(view, "#downloads-#{deferred.id}", "Starts")
  end

  test "changes a deferred download's start time from its panel", %{conn: conn} do
    deferred = download_fixture(%{start_at: ~U[2099-01-01 00:00:00Z]})
    {:ok, view, _html} = live(conn, ~p"/downloads/#{deferred}")
    refute has_element?(view, "#download-#{deferred.id} a", "Edit start")

    html = view |> form("#start-at-form", %{"start_at_local" => "2099-02-01T03:00"}) |> render_submit()

    assert html =~ "Start time changed."
    assert Downloads.get_download!(deferred.id).start_at == ~U[2099-02-01 03:00:00Z]
  end

  defp queue_order(view) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#downloads > tr") |> LazyHTML.attribute("id")
  end

  test "deletes an open finished download, closing it and dropping its row", %{conn: conn} do
    failed = failed_download_fixture()
    {:ok, view, _html} = live(conn, ~p"/downloads/#{failed}")

    view |> element("#download-#{failed.id} button", "Delete") |> render_click()

    assert_patch(view, ~p"/downloads")
    assert has_element?(view, "#flash-info", "Deleted the download.")
    assert nil == Downloads.get_download(failed.id)
    refute has_element?(view, "#download-#{failed.id}")
    refute has_element?(view, "#finished-downloads-#{failed.id}")
  end

  test "offers no delete for a download in flight", %{conn: conn} do
    download = download_fixture()
    {:ok, view, _html} = live(conn, ~p"/downloads")

    refute has_element?(view, "#downloads-#{download.id} button", "Delete")
  end

  test "deletes every finished download, closing the open one and keeping the ones in flight", %{conn: conn} do
    queued = download_fixture()
    failed = failed_download_fixture()
    {:ok, view, _html} = live(conn, ~p"/downloads/#{failed}")

    view |> element("#delete-finished") |> render_click()

    assert_patch(view, ~p"/downloads")
    assert has_element?(view, "#flash-info", "Deleted 1 finished download.")
    refute has_element?(view, "#finished-downloads-#{failed.id}")
    assert has_element?(view, "#downloads-#{queued.id}")
  end

  test "a deleted download's link returns to the list", %{conn: conn} do
    failed = failed_download_fixture()
    {:ok, _deleted} = Downloads.delete_download(failed)

    assert {:error, {:live_redirect, %{to: "/downloads", flash: %{"error" => "That download was deleted."}}}} =
             live(conn, ~p"/downloads/#{failed}")
  end
end

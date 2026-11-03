defmodule Contentoid.DownloadsTest do
  use Contentoid.DataCase, async: true
  use Oban.Testing, repo: Contentoid.Repo

  import Contentoid.DownloadsFixtures

  alias Contentoid.Downloaders
  alias Contentoid.Downloads
  alias Contentoid.Downloads.Download
  alias Contentoid.Downloads.Queues
  alias Contentoid.Downloads.Worker
  alias Contentoid.Message

  test "a failure's message is kept to translate when shown" do
    {:ok, running} = Downloads.mark_running(download_fixture())
    error = Message.new("exited with status %{status}", status: 3)

    Downloads.finish(running, status: :failed, error: error)

    assert %Download{error: ^error} = Downloads.get_download!(running.id)
    assert ContentoidWeb.Messages.message_text(error) == "exited with status 3"
  end

  describe "create_downloads/1" do
    test "queues each in order, or none when one is invalid" do
      downloader = downloader_fixture()
      urls = for name <- ~w(a b c), do: "https://example.com/#{name}"

      assert {:ok, downloads} =
               Downloads.create_downloads(for url <- urls, do: %{url: url, downloader_id: downloader.id})

      assert Enum.map(downloads, & &1.url) == urls
      # The queue runs them in the order given.
      assert Enum.map(downloads, & &1.id) == Enum.map(Downloads.list_queue(), & &1.id)
      for download <- downloads, do: assert_enqueued(worker: Worker, args: %{download_id: download.id})

      before = length(Downloads.list_queue())

      assert {:error, 1, changeset} =
               Downloads.create_downloads([
                 %{url: "https://example.com/d", downloader_id: downloader.id},
                 %{url: "not a url", downloader_id: downloader.id}
               ])

      assert %{url: [_message]} = errors_on(changeset)
      assert length(Downloads.list_queue()) == before
    end
  end

  describe "list_queue/1" do
    # Never preempting: a running download stays first whatever arrives after it.
    test "lists running ones first, then those that may start by priority, then deferred ones by time" do
      downloader = downloader_fixture()
      queue = fn attrs -> download_fixture(Map.put(attrs, :downloader_id, downloader.id)) end

      {:ok, running} = Downloads.mark_running(queue.(%{priority: 0}))
      normal = queue.(%{})
      urgent = queue.(%{priority: 9})
      later = queue.(%{priority: 9, start_at: DateTime.add(DateTime.utc_now(:second), 3600)})
      soon = queue.(%{start_at: DateTime.add(DateTime.utc_now(:second), 60)})
      urgent_too = queue.(%{priority: 9})

      assert Enum.map(Downloads.list_queue(), & &1.id) ==
               Enum.map([running, urgent, urgent_too, normal, soon, later], & &1.id)

      # Oban runs a queue's lowest job priority first: 9 - the download's.
      assert_enqueued(worker: Worker, args: %{download_id: urgent.id}, priority: 0)
      assert_enqueued(worker: Worker, args: %{download_id: normal.id}, priority: 9)
    end
  end

  describe "create_download/1" do
    test "queues a job in its downloader's queue and keeps the downloader's name" do
      downloader = downloader_fixture(%{name: "Videos"})
      {:ok, download} = Downloads.create_download(%{url: " https://example.com/a.zip ", downloader_id: downloader.id})

      assert %Download{status: :queued, url: "https://example.com/a.zip", downloader_name: "Videos"} = download
      assert_enqueued(worker: Worker, queue: Queues.name(downloader), args: %{download_id: download.id})
      assert %Oban.Job{id: job_id} = Repo.get!(Oban.Job, download.oban_job_id)
      assert job_id == download.oban_job_id
    end

    test "accepts only http, https and ftp URLs with a host" do
      downloader = downloader_fixture()

      for url <- ["file:///etc/passwd", "javascript:alert(1)", "example.com/video", "https://", ""] do
        assert {:error, changeset} = Downloads.create_download(%{url: url, downloader_id: downloader.id})
        assert %{url: [_message]} = errors_on(changeset), "accepted #{inspect(url)}"
      end

      refute_enqueued(worker: Worker)
    end

    test "requires an existing, enabled downloader" do
      disabled = downloader_fixture(%{enabled: false})

      assert {:error, changeset} = Downloads.create_download(%{url: "https://example.com", downloader_id: disabled.id})
      assert %{downloader_id: ["is disabled"]} = errors_on(changeset)

      assert {:error, changeset} =
               Downloads.create_download(%{url: "https://example.com", downloader_id: Contentoid.Schema.generate_id()})

      assert %{downloader_id: ["doesn't exist"]} = errors_on(changeset)
    end

    test "without a downloader, takes the highest-priority enabled one whose pattern matches" do
      _low = downloader_fixture(%{url_pattern: "^https://pick\\.test/", priority: 3_000_001})
      high = downloader_fixture(%{url_pattern: "^https://pick\\.test/", priority: 3_000_002})
      _disabled = downloader_fixture(%{url_pattern: "^https://pick\\.test/", priority: 3_000_003, enabled: false})

      # String keys and a blank pick, as the form sends them.
      {:ok, download} = Downloads.create_download(%{"url" => " https://pick.test/v ", "downloader_id" => ""})
      assert download.downloader_id == high.id
    end

    test "without a downloader and with no pattern matching, says so" do
      # No default takes an ftp URL without a file extension.
      assert {:error, changeset} = Downloads.create_download(%{url: "ftp://nomatch.test/dir"})
      assert %{downloader_id: ["no enabled downloader matches this URL; pick one"]} = errors_on(changeset)
    end

    test "an arguments downloader takes arguments, or none, and no URL" do
      downloader = downloader_fixture(%{input: :arguments})

      {:ok, download} = Downloads.create_download(%{downloader_id: downloader.id, arguments: " --all "})
      assert %Download{url: nil, arguments: "--all", status: :queued} = download

      assert {:ok, %Download{url: nil, arguments: nil}} = Downloads.create_download(%{downloader_id: downloader.id})

      assert {:error, changeset} =
               Downloads.create_download(%{downloader_id: downloader.id, url: "https://example.com/v"})

      assert %{url: ["isn't taken by an arguments downloader"]} = errors_on(changeset)

      assert {:error, changeset} = Downloads.create_download(%{downloader_id: downloader.id, arguments: ~s(--q "open)})
      assert %{arguments: ["have a quote that's never closed"]} = errors_on(changeset)
    end

    test "a URL downloader takes no arguments" do
      downloader = downloader_fixture()

      assert {:error, changeset} =
               Downloads.create_download(%{downloader_id: downloader.id, url: "https://example.com/v", arguments: "-x"})

      assert %{arguments: ["aren't taken by a URL downloader"]} = errors_on(changeset)
    end
  end

  describe "cancel_download/1" do
    test "cancels a queued download and its job" do
      download = download_fixture()

      assert {:ok, %Download{status: :cancelled, finished_at: %DateTime{}}} = Downloads.cancel_download(download)
      assert %Oban.Job{state: "cancelled"} = Repo.get!(Oban.Job, download.oban_job_id)
    end

    test "refuses a download that already finished" do
      download = failed_download_fixture()
      assert {:error, :not_cancellable} = Downloads.cancel_download(download)
    end

    test "is not undone by the run it cancelled finishing afterwards" do
      {:ok, running} = Downloads.mark_running(download_fixture())
      {:ok, _cancelled} = Downloads.cancel_download(running)

      assert nil == Downloads.finish(running, status: :completed, files: ["/x"])
      assert nil == Downloads.record_progress(running, progress: 0.5)
      assert %Download{status: :cancelled, files: []} = Downloads.get_download!(running.id)
    end
  end

  describe "mark_running/1" do
    test "doesn't start a download cancelled while it was queued" do
      download = download_fixture()
      {:ok, _cancelled} = Downloads.cancel_download(download)

      assert {:error, :not_queued} = Downloads.mark_running(download)
    end
  end

  describe "deferred downloads" do
    test "a future start time schedules the job then and keeps the download queued" do
      start_at = DateTime.add(DateTime.utc_now(:second), 3600)
      download = download_fixture(%{start_at: start_at})

      assert Downloads.deferred?(download)
      assert %Oban.Job{state: "scheduled", scheduled_at: scheduled_at} = Repo.get!(Oban.Job, download.oban_job_id)
      assert DateTime.compare(DateTime.truncate(scheduled_at, :second), start_at) == :eq
    end

    test "a start time already past starts it now" do
      download = download_fixture(%{start_at: DateTime.add(DateTime.utc_now(:second), -60)})

      refute Downloads.deferred?(download)
      assert %Oban.Job{state: "available"} = Repo.get!(Oban.Job, download.oban_job_id)
    end

    test "retrying a deferred download starts it now" do
      download = download_fixture(%{start_at: DateTime.add(DateTime.utc_now(:second), 3600)})
      {:ok, cancelled} = Downloads.cancel_download(download)

      {:ok, retried} = Downloads.retry_download(cancelled)

      assert retried.start_at == nil
      assert %Oban.Job{state: "available"} = Repo.get!(Oban.Job, retried.oban_job_id)
    end
  end

  describe "retry_download/1" do
    test "queues a failed download from scratch with a new job" do
      failed = failed_download_fixture()

      assert {:ok, %Download{status: :queued, error: nil, log: nil, exit_status: nil} = retried} =
               Downloads.retry_download(failed)

      assert retried.oban_job_id != failed.oban_job_id
      assert_enqueued(worker: Worker, args: %{download_id: failed.id}, queue: Queues.name(failed.downloader_id))
    end

    test "refuses a download that is queued or running" do
      assert {:error, :not_retryable} = Downloads.retry_download(download_fixture())
    end

    test "refuses a download whose downloader was deleted, which keeps its name" do
      downloader = downloader_fixture(%{name: "Gone"})
      failed = failed_download_fixture(%{downloader_id: downloader.id})
      {:ok, _deleted} = Downloaders.delete_downloader(downloader)

      orphan = Downloads.get_download!(failed.id)
      assert %Download{downloader_id: nil, downloader_name: "Gone"} = orphan
      assert {:error, :not_retryable} = Downloads.retry_download(orphan)
    end
  end

  describe "delete_download/1" do
    test "deletes a finished download with its items, and broadcasts it" do
      {:ok, running} = Downloads.mark_running(download_fixture())
      item = Downloads.record_item(running, "https://example.com/video", "/out/video.mp4")
      completed = Downloads.finish(running, status: :completed, files: ["/out/video.mp4"])
      other_item = Downloads.record_item(download_fixture(), "https://example.com/other", "/out/other.mp4")
      Downloads.subscribe()
      Downloads.subscribe_items()

      assert {:ok, %Download{id: id}} = Downloads.delete_download(completed)

      assert_receive {:downloads_deleted, [^id]}
      assert_receive {:items_deleted, [^id]}
      assert nil == Downloads.get_download(id)
      assert nil == Repo.get(Downloads.Item, item.id)
      assert Repo.get(Downloads.Item, other_item.id)
    end

    test "refuses a download that is queued or running" do
      queued = download_fixture()
      {:ok, running} = Downloads.mark_running(download_fixture())

      assert {:error, :not_finished} = Downloads.delete_download(queued)
      assert {:error, :not_finished} = Downloads.delete_download(running)
      assert Downloads.get_download(queued.id)
      assert Downloads.get_download(running.id)
    end

    # The caller's struct may predate a retry.
    test "refuses a download retried since it was read" do
      failed = failed_download_fixture()
      {:ok, _retried} = Downloads.retry_download(failed)

      assert {:error, :not_finished} = Downloads.delete_download(failed)
    end
  end

  describe "delete_finished_downloads/0" do
    test "deletes every completed, failed and cancelled download, and nothing in flight" do
      queued = download_fixture()
      {:ok, running} = Downloads.mark_running(download_fixture())
      {:ok, cancelled} = Downloads.cancel_download(download_fixture())
      failed = failed_download_fixture()
      {:ok, to_complete} = Downloads.mark_running(download_fixture())
      completed = Downloads.finish(to_complete, status: :completed)
      Downloads.subscribe()

      ids = Downloads.delete_finished_downloads()

      assert Enum.sort(ids) == Enum.sort([cancelled.id, failed.id, completed.id])
      assert_receive {:downloads_deleted, ^ids}
      assert [running.id, queued.id] == Enum.map(Downloads.list_queue(), & &1.id)
    end

    test "with none finished, deletes nothing and broadcasts nothing" do
      download_fixture()
      Downloads.subscribe()

      assert [] == Downloads.delete_finished_downloads()
      # The topic is shared with async tests deleting their own downloads; this one would be empty.
      refute_receive {:downloads_deleted, []}
    end
  end

  describe "recover_interrupted/0" do
    test "requeues downloads left running with a fresh job and discards their stuck jobs" do
      {:ok, running} = Downloads.mark_running(download_fixture())
      Repo.update_all(where(Oban.Job, id: ^running.oban_job_id), set: [state: "executing"])
      untouched = download_fixture(%{url: "https://example.com/other"})

      assert {:ok, %{downloads: 1}} = Downloads.recover_interrupted()

      requeued = Downloads.get_download!(running.id)
      assert %Download{status: :queued, started_at: nil} = requeued
      assert requeued.oban_job_id != running.oban_job_id
      queue = Queues.name(running.downloader_id)
      assert %Oban.Job{state: "available", queue: ^queue} = Repo.get!(Oban.Job, requeued.oban_job_id)
      assert %Oban.Job{state: "discarded"} = Repo.get!(Oban.Job, running.oban_job_id)
      assert Downloads.get_download!(untouched.id).oban_job_id == untouched.oban_job_id
    end

    # Its job was executing, waiting for a global slot, when the VM stopped.
    test "requeues a queued download whose job was already taken" do
      download = download_fixture()
      Repo.update_all(where(Oban.Job, id: ^download.oban_job_id), set: [state: "executing"])

      assert {:ok, %{downloads: 1}} = Downloads.recover_interrupted()
      assert Downloads.get_download!(download.id).oban_job_id != download.oban_job_id
    end
  end

  describe "the line" do
    setup do
      downloader = downloader_fixture()
      %{queue: fn attrs -> download_fixture(Map.put(attrs, :downloader_id, downloader.id)) end}
    end

    test "a new download goes after the last waiting one of the same or higher priority; a drag stands",
         %{queue: queue} do
      a = queue.(%{})
      b = queue.(%{})
      c = queue.(%{priority: 9})
      assert queue_ids() == ids([c, a, b])

      assert :ok = Downloads.reorder_queue([b.id, c.id, a.id])
      assert queue_ids() == ids([b, c, a])

      d = queue.(%{priority: 5})
      assert queue_ids() == ids([b, c, d, a])
    end

    test "reordering with a running or deferred download's id is stale and changes nothing", %{queue: queue} do
      a = queue.(%{})
      b = queue.(%{})
      {:ok, running} = Downloads.mark_running(queue.(%{}))
      deferred = queue.(%{start_at: DateTime.add(DateTime.utc_now(:second), 3600)})
      before = queue_ids()

      assert {:error, :stale} = Downloads.reorder_queue([b.id, running.id, a.id])
      assert {:error, :stale} = Downloads.reorder_queue([deferred.id, b.id, a.id])
      assert {:error, :stale} = Downloads.reorder_queue([b.id, b.id])
      assert queue_ids() == before
    end

    test "start now moves a deferred download to the front and makes its job available", %{queue: queue} do
      a = queue.(%{})
      b = queue.(%{})
      deferred = queue.(%{start_at: DateTime.add(DateTime.utc_now(:second), 3600)})

      assert {:ok, %Download{start_at: nil}} = Downloads.start_download_now(deferred)
      assert queue_ids() == ids([deferred, a, b])
      assert %Oban.Job{state: "available"} = Repo.get!(Oban.Job, deferred.oban_job_id)

      assert {:error, :not_deferred} = Downloads.start_download_now(Downloads.get_download!(deferred.id))
    end

    test "reschedule moves a deferred download's start time and its job's; only to the future", %{queue: queue} do
      start_at = DateTime.add(DateTime.utc_now(:second), 3600)
      deferred = queue.(%{start_at: start_at})
      later = DateTime.add(start_at, 7200)

      assert {:ok, %Download{start_at: ^later}} = Downloads.reschedule_download(deferred, later)
      assert DateTime.truncate(Repo.get!(Oban.Job, deferred.oban_job_id).scheduled_at, :second) == later

      assert {:error, :not_future} =
               Downloads.reschedule_download(deferred, DateTime.add(DateTime.utc_now(), -60))

      assert {:error, :not_deferred} = Downloads.reschedule_download(queue.(%{}), later)
    end

    test "a download whose start time came takes its priority's place", %{queue: queue} do
      a = queue.(%{priority: 5})
      b = queue.(%{})
      due = queue.(%{priority: 5, start_at: DateTime.add(DateTime.utc_now(:second), 3600)})
      assert due.position == nil

      Repo.update_all(where(Download, id: ^due.id), set: [start_at: DateTime.add(DateTime.utc_now(:second), -1)])
      placed = Downloads.take_place_in_line(Downloads.get_download!(due.id))

      assert placed.position == Downloads.get_download!(a.id).position + 1
      assert queue_ids() == ids([a, due, b])
    end
  end

  describe "removing Downloaded records" do
    test "delete_items/1 removes the matching records; delete_item/1 one; both broadcast" do
      download = download_fixture()
      video = Downloads.record_item(download, "https://videos.test/a", "/lib/a.mp4")
      image = Downloads.record_item(download, "https://images.test/b.jpg", "/lib/b.jpg")
      Downloads.subscribe_items()

      assert Downloads.delete_items("VIDEOS") == [video.id]
      assert_receive {:items_removed, [id]} when id == video.id
      assert Enum.map(Downloads.list_items(), & &1.id) == [image.id]

      assert :ok = Downloads.delete_item(image.id)
      assert_receive {:items_removed, [id]} when id == image.id
      assert {:error, :not_found} = Downloads.delete_item(image.id)
      assert {:error, :not_found} = Downloads.delete_item("not-a-uuid")
      assert Downloads.delete_items(nil) == []
      refute_receive {:items_removed, _ids}
    end
  end

  defp queue_ids, do: Enum.map(Downloads.list_queue(), & &1.id)
  defp ids(downloads), do: Enum.map(downloads, & &1.id)

  test "every change is broadcast" do
    Downloads.subscribe()
    download = download_fixture()

    assert_receive {:download, %Download{id: id, status: :queued}} when id == download.id
    {:ok, _cancelled} = Downloads.cancel_download(download)
    assert_receive {:download, %Download{id: ^id, status: :cancelled}}
  end
end

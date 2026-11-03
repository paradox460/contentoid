defmodule Contentoid.Downloads.Worker do
  @moduledoc """
  The Oban job behind a download; it runs in its downloader's queue (`Contentoid.Downloads.Queues`),
  which hands jobs out at once (or at a deferred download's start time). The job then takes its
  place in line (`Contentoid.Downloads.take_place_in_line/1`) and waits for a slot
  (`Contentoid.Downloads.Slots`), which holds it to its downloader's concurrency, the global limit
  and the queue's pause, and serves waiters in line order. The download stays `queued` while it
  waits.

  A downloader disabled while its job waited for a slot (pausing a queue doesn't stop a job it already
  handed out) gets the job snoozed: its paused queue then holds it until the downloader is enabled.

  One attempt only: the tools retry network errors themselves, and a failure that survives that (a
  removed video, an unsupported URL) won't pass on a second try. Retrying is the user's call
  (`Contentoid.Downloads.retry_download/1`). Snoozing doesn't use up the attempt.
  """
  use Oban.Worker, max_attempts: 1

  alias Contentoid.Downloaders
  alias Contentoid.Downloads
  alias Contentoid.Downloads.Runner
  alias Contentoid.Downloads.Slots

  @snooze_seconds 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"download_id" => id}}) do
    case Downloads.get_download!(id) do
      %{status: :queued} = download ->
        download = Downloads.take_place_in_line(download)
        downloader = Downloaders.get_downloader(download.downloader_id)

        waiter = %{
          download_id: download.id,
          downloader_id: download.downloader_id,
          concurrency: (downloader && downloader.concurrency) || 1
        }

        with_slot(waiter, fn -> run_if_enabled(download) end)

      _cancelled ->
        {:cancel, "download is no longer queued"}
    end
  end

  defp run_if_enabled(download) do
    case Downloaders.get_downloader(download.downloader_id) do
      %{enabled: false} -> {:snooze, @snooze_seconds}
      _enabled_or_deleted -> run(download)
    end
  end

  # Claimed only once a slot is free: cancelling it meanwhile is still a cancel of a queued download.
  defp run(download) do
    case Downloads.mark_running(download) do
      {:ok, running} -> Runner.run(running)
      {:error, :not_queued} -> {:cancel, "download is no longer queued"}
    end
  end

  defp with_slot(waiter, fun) do
    :ok = Slots.acquire(waiter)

    try do
      fun.()
    after
      Slots.release()
    end
  end
end

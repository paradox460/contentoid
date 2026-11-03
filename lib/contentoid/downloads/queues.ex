defmodule Contentoid.Downloads.Queues do
  @moduledoc """
  One Oban queue per downloader, `downloader-<id>`, with a fixed large limit (1 000): it hands
  jobs out at once, and `Contentoid.Downloads.Slots` holds them to the downloader's concurrency, the
  global limit, the pause and the line order. The limit only bounds how many of a downloader's jobs
  wait in Slots at once; beyond it, the rest wait in Oban's own order. The queues stay for deferral
  (a job's `scheduled_at`) and for pausing a disabled downloader.

  Oban's queues are static config, so these are started at runtime: for every enabled downloader once
  Oban is up (`start_all/0`, run by a child after Oban), then kept in step as downloaders change
  (`sync/1`, `stop/1`). A disabled downloader's queue is paused, not stopped: its running downloads
  finish, its queued ones wait until it's enabled again. A deleted downloader's queue is stopped; it
  has nothing left to run (`Contentoid.Downloaders.delete_downloader/1`).

  Off in the tests (`config :contentoid, Contentoid.Downloads.Queues, enabled: false`), which run
  jobs themselves.
  """

  alias Contentoid.Downloaders
  alias Contentoid.Downloaders.Downloader

  @limit 1_000

  @doc "The queue a downloader's downloads run in."
  def name(%Downloader{id: id}), do: name(id)
  def name(downloader_id) when is_binary(downloader_id), do: "downloader-#{downloader_id}"

  @doc "Starts the queue of every enabled downloader."
  def start_all do
    if enabled?(), do: Enum.each(Downloaders.list_enabled_downloaders(), &sync/1)
    :ok
  end

  @doc "Starts, resizes, resumes or pauses the downloader's queue to match it."
  def sync(%Downloader{} = downloader) do
    if enabled?() do
      queue = name(downloader)

      case {downloader.enabled, Oban.check_queue(queue: queue)} do
        {true, nil} ->
          Oban.start_queue(queue: queue, limit: @limit, local_only: true)

        {true, state} ->
          if state.limit != @limit, do: Oban.scale_queue(queue: queue, limit: @limit, local_only: true)

          if state.paused, do: Oban.resume_queue(queue: queue, local_only: true)

        {false, nil} ->
          :ok

        {false, _state} ->
          Oban.pause_queue(queue: queue, local_only: true)
      end
    end

    :ok
  end

  @doc "Stops the downloader's queue, if it's running."
  def stop(%Downloader{} = downloader) do
    queue = name(downloader)
    if enabled?() and Oban.check_queue(queue: queue), do: Oban.stop_queue(queue: queue, local_only: true)
    :ok
  end

  defp enabled?, do: Keyword.get(Application.get_env(:contentoid, __MODULE__, []), :enabled, true)
end

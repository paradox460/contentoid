defmodule Contentoid.Downloads do
  @moduledoc """
  Downloads: queueing a URL (or a schedule's arguments) for a downloader, following its run,
  cancelling, retrying and deleting it.

  Each download runs as an Oban job (`Contentoid.Downloads.Worker`) in its downloader's queue
  (`Contentoid.Downloads.Queues`), which hands it out at once, or at its start time when deferred.
  The job then waits for a slot (`Contentoid.Downloads.Slots`), which holds downloads to their
  downloader's concurrency, the global limit and the queue's pause (`pause_queue/0`), and serves
  them in line order. Every change is broadcast as `{:download, %Download{}}` to `subscribe/0`rs,
  every deletion as `{:downloads_deleted, ids}`, a pause or resume as `{:queue_paused, boolean}` and
  a change to the line's order as `:queue_reordered`.

  The line is `Download.position`, set only here: a download gets one when it may start (on
  creation or retry, or when its start time comes, `take_place_in_line/1`), after the last waiting
  one of the same or higher priority, and loses it when it starts. Dragging (`reorder_queue/1`)
  and `start_download_now/1` move downloads in it. Nothing locks the line: two writes at once may
  give two downloads the same position, and such ties go by priority, higher first, then
  creation, then id (`line_order/1`).

  Writes made on behalf of a running download (`record_progress/2`, `finish/2`) apply only while it
  is still `running`, so a cancellation is never overwritten by the run it cancelled.
  """

  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Query

  alias Contentoid.Downloaders
  alias Contentoid.Downloads.Download
  alias Contentoid.Downloads.Item
  alias Contentoid.Downloads.Queues
  alias Contentoid.Downloads.Slots
  alias Contentoid.Downloads.Worker
  alias Contentoid.Message
  alias Contentoid.Repo
  alias Contentoid.Settings
  alias Ecto.Multi

  @topic "downloads"
  @items_topic "download_items"

  # Statuses a download's run never leaves on its own; only these may be deleted.
  @finished [:completed, :failed, :cancelled]

  @doc """
  Subscribes the caller to `{:download, %Download{}}` messages for every download,
  `{:downloads_deleted, ids}` for every deletion, `{:queue_paused, boolean}` when the queue is
  paused or resumed and `:queue_reordered` when downloads move in line.
  """
  def subscribe, do: Phoenix.PubSub.subscribe(Contentoid.PubSub, @topic)

  @doc """
  Subscribes the caller to `{:item, %Item{}}` messages, one per file recorded,
  `{:items_deleted, download_ids}` when deleted downloads take their items with them and
  `{:items_removed, item_ids}` when records are removed (`delete_item/1`, `delete_items/1`).
  """
  def subscribe_items, do: Phoenix.PubSub.subscribe(Contentoid.PubSub, @items_topic)

  @doc """
  The queued and running downloads in the order they run: running ones first, the longest-running
  at the top; then those that may start now, in line order (`position`): a new one takes its
  priority's place, after the last waiting one of the same or higher priority, and any can be
  dragged elsewhere (`reorder_queue/1`); then deferred ones by their start time. A downloader at
  its own concurrency holds its downloads back while those behind them start.
  """
  @spec list_queue(pos_integer()) :: [Download.t()]
  def list_queue(limit \\ 200) do
    # Deferred as `deferred?/1` says: by the download's start time, on this clock.
    now = DateTime.utc_now()

    Repo.all(
      from d in Download,
        left_join: j in Oban.Job,
        on: j.id == d.oban_job_id,
        where: d.status in [:queued, :running],
        order_by: [
          asc: fragment("CASE WHEN ? = 'running' THEN 0 WHEN ? > ? THEN 2 ELSE 1 END", d.status, d.start_at, ^now),
          asc_nulls_last: d.started_at,
          asc_nulls_last: d.position,
          # Priority orders only those that may start; deferred ones go by their start time.
          desc: fragment("CASE WHEN ? > ? THEN 0 ELSE ? END", d.start_at, ^now, d.priority),
          asc_nulls_last: d.start_at,
          asc_nulls_last: j.scheduled_at,
          asc: j.id,
          asc: d.id
        ],
        limit: ^limit
    )
  end

  @doc "The finished downloads (completed, failed or cancelled), the most recently finished first."
  @spec list_finished(pos_integer()) :: [Download.t()]
  def list_finished(limit \\ 200) do
    Download
    |> where([d], d.status in ^@finished)
    |> order_by(desc_nulls_last: :finished_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Whether `download` is finished: completed, failed or cancelled."
  def finished?(%Download{status: status}), do: status in @finished

  def get_download!(id), do: Repo.get!(Download, id)

  def get_download(id), do: Repo.get(Download, id)

  @doc """
  Queues a download of `attrs` `url` with the downloader `attrs` `downloader_id`, or, when none is given,
  with the highest-priority enabled URL downloader whose pattern matches the URL (`Downloaders.match/1`).
  An arguments downloader is always given, with `attrs` `arguments` instead of a URL. A future
  `start_at` defers it: it stays queued until then.
  """
  def create_download(attrs) do
    case create_downloads([attrs]) do
      {:ok, [download]} -> {:ok, download}
      {:error, 0, changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Queues a download for each of `attrs_list`, as `create_download/1` would, in order: all of them,
  or none when any is invalid (`{:error, index, changeset}`, the first invalid one).
  """
  @spec create_downloads([map()]) ::
          {:ok, [Download.t()]} | {:error, non_neg_integer(), Ecto.Changeset.t()} | {:error, term()}
  def create_downloads(attrs_list) do
    attrs_list
    |> Enum.with_index()
    |> Enum.reduce(Multi.new(), fn {attrs, index}, multi ->
      multi
      |> Multi.insert({:inserted, index}, change_new_download(attrs))
      |> place(index)
      |> enqueue(index)
    end)
    |> transact(length(attrs_list))
  end

  @doc """
  The changeset `create_download/1` inserts for `attrs`, the downloader matched from the URL when
  none is given; for checking a download before queueing it.
  """
  def change_new_download(attrs), do: Download.create_changeset(%Download{}, with_matched_downloader(attrs))

  # Attrs come with string keys from a form and atom keys from code.
  defp with_matched_downloader(attrs) do
    {url_key, downloader_key} =
      if Map.has_key?(attrs, "url"), do: {"url", "downloader_id"}, else: {:url, :downloader_id}

    with url when is_binary(url) <- Map.get(attrs, url_key),
         true <- Map.get(attrs, downloader_key) in [nil, ""],
         %{id: id} <- Downloaders.match(String.trim(url)) do
      Map.put(attrs, downloader_key, id)
    else
      _picked_or_no_match -> attrs
    end
  end

  @doc "Cancels a queued or running download; a running downloader's container is removed."
  def cancel_download(%Download{status: status} = download) when status in [:queued, :running] do
    if download.oban_job_id, do: Oban.cancel_job(download.oban_job_id)

    download
    |> where_status([:queued, :running])
    |> update_one(status: :cancelled, finished_at: now())
    |> case do
      nil -> {:error, :not_cancellable}
      cancelled -> {:ok, cancelled}
    end
  end

  def cancel_download(%Download{}), do: {:error, :not_cancellable}

  @doc """
  Queues a failed or cancelled download again, from scratch (the downloader resumes partial files), to
  start now even if it was deferred. Not when its downloader was deleted. A download that failed or
  stopped in post-processing (`Download.phase`) re-runs only post-processing, on the files it has.
  """
  def retry_download(%Download{status: status, downloader_id: downloader_id} = download)
      when status in [:failed, :cancelled] and is_binary(downloader_id) do
    Multi.new()
    |> Multi.update(
      {:inserted, 0},
      Ecto.Changeset.change(download, Keyword.put(reset(download, :queued), :start_at, nil))
    )
    |> place(0)
    |> enqueue(0)
    |> transact(1)
    |> case do
      {:ok, [queued]} -> {:ok, queued}
      {:error, 0, changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  def retry_download(%Download{}), do: {:error, :not_retryable}

  @doc """
  Deletes a finished (completed, failed or cancelled) download's record and its items (the database
  cascades); its files stay on disk.
  """
  def delete_download(%Download{} = download) do
    download
    |> where_status(@finished)
    |> select([d], d)
    |> Repo.delete_all()
    |> case do
      {1, [deleted]} ->
        broadcast_deleted([deleted.id])
        {:ok, deleted}

      {0, []} ->
        {:error, :not_finished}
    end
  end

  @doc "Deletes every finished download's record, as `delete_download/1` does; returns their ids."
  @spec delete_finished_downloads() :: [Ecto.UUID.t()]
  def delete_finished_downloads do
    {count, ids} = Download |> where([d], d.status in ^@finished) |> select([d], d.id) |> Repo.delete_all()
    if count > 0, do: broadcast_deleted(ids)
    ids
  end

  @doc "Whether a queued download is waiting for its start time."
  def deferred?(%Download{status: :queued, start_at: %DateTime{} = start_at}),
    do: DateTime.after?(start_at, DateTime.utc_now())

  def deferred?(%Download{}), do: false

  @doc false
  # Slots' serving order for the waiting downloads `ids`: line order. An id that isn't found goes last.
  @spec line_order([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def line_order(ids) do
    found =
      Repo.all(
        from d in Download,
          where: d.id in ^ids,
          order_by: [asc_nulls_last: d.position, desc: d.priority, asc: d.inserted_at, asc: d.id],
          select: d.id
      )

    found ++ (ids -- found)
  end

  @doc false
  # Run by the worker before it waits for a slot: a download that became due (deferred until now)
  # or lost its place (interrupted while running) gets a place by its priority.
  @spec take_place_in_line(Download.t()) :: Download.t()
  def take_place_in_line(%Download{position: position} = download) when not is_nil(position), do: download

  def take_place_in_line(%Download{} = download) do
    if deferred?(download) do
      download
    else
      {:ok, placed} = Repo.transact(fn -> {:ok, place_in_line(download, :by_priority)} end)
      broadcast_reordered()
      placed
    end
  end

  @doc "Moves a deferred download to the front of the line, to start at the next free slot."
  @spec start_download_now(Download.t()) :: {:ok, Download.t()} | {:error, :not_deferred}
  def start_download_now(%Download{status: :queued, oban_job_id: job_id} = download) when is_integer(job_id) do
    Repo.transact(fn ->
      job = from(j in Oban.Job, where: j.id == ^job_id and j.state == "scheduled")
      queued = select(where_status(download, [:queued]), [d], d)

      # Oban's stager hands a now-available job to its queue within about a second.
      with {1, _} <- Repo.update_all(job, set: [state: "available", scheduled_at: DateTime.utc_now()]),
           {1, [started]} <- Repo.update_all(queued, set: [start_at: nil, updated_at: now()]) do
        {:ok, place_in_line(started, :front)}
      else
        _ -> {:error, :not_deferred}
      end
    end)
    |> broadcast_moved()
  end

  def start_download_now(%Download{}), do: {:error, :not_deferred}

  @doc "Changes a deferred download's start time to `start_at`, which must be in the future."
  @spec reschedule_download(Download.t(), DateTime.t()) :: {:ok, Download.t()} | {:error, :not_future | :not_deferred}
  def reschedule_download(%Download{} = download, %DateTime{} = start_at) do
    if DateTime.after?(start_at, DateTime.utc_now()) do
      start_at = DateTime.truncate(start_at, :second)

      Repo.transact(fn ->
        job = from(j in Oban.Job, where: j.id == ^download.oban_job_id and j.state == "scheduled")
        queued = select(where_status(download, [:queued]), [d], d)

        with false <- is_nil(download.oban_job_id),
             {1, _} <- Repo.update_all(job, set: [scheduled_at: start_at]),
             {1, [rescheduled]} <- Repo.update_all(queued, set: [start_at: start_at, updated_at: now()]) do
          {:ok, rescheduled}
        else
          _ -> {:error, :not_deferred}
        end
      end)
      |> broadcast_moved()
    else
      {:error, :not_future}
    end
  end

  @doc """
  Reorders the waiting downloads: `ids` (waiting, not deferred, no duplicates) take the places
  those downloads hold now, in the given order; other waiting downloads keep theirs. Every waiting
  download is then numbered 0..n-1.
  """
  @spec reorder_queue([Ecto.UUID.t()]) :: :ok | {:error, :stale}
  def reorder_queue(ids) when is_list(ids) do
    Repo.transact(fn ->
      line = waiting_ids()
      moved = MapSet.new(ids)

      if MapSet.size(moved) == length(ids) and MapSet.subset?(moved, MapSet.new(line)) do
        {new_line, []} =
          Enum.map_reduce(line, ids, fn id, rest ->
            if MapSet.member?(moved, id), do: {hd(rest), tl(rest)}, else: {id, rest}
          end)

        for {id, index} <- Enum.with_index(new_line) do
          Repo.update_all(from(d in Download, where: d.id == ^id), set: [position: index])
        end

        {:ok, :ok}
      else
        {:error, :stale}
      end
    end)
    |> case do
      {:ok, :ok} ->
        broadcast_reordered()
        :ok

      error ->
        error
    end
  end

  @doc "Whether the queue is paused (`pause_queue/0`)."
  @spec queue_paused?() :: boolean()
  def queue_paused?, do: Settings.get_settings().queue_paused

  @doc "Pauses the queue: running downloads finish; nothing new starts until `resume_queue/0`."
  @spec pause_queue() :: :ok | {:error, Ecto.Changeset.t()}
  def pause_queue, do: set_queue_paused(true)

  @doc "Resumes the queue: waiting downloads start in line order as slots allow."
  @spec resume_queue() :: :ok | {:error, Ecto.Changeset.t()}
  def resume_queue, do: set_queue_paused(false)

  defp set_queue_paused(paused) do
    with {:ok, _setting} <- Settings.put_queue_paused(paused) do
      Slots.set_paused(paused)
      Phoenix.PubSub.broadcast(Contentoid.PubSub, @topic, {:queue_paused, paused})
      :ok
    end
  end

  @doc false
  # The worker claims a queued download; anything else (cancelled while queued) is left alone.
  def mark_running(%Download{} = download) do
    download
    |> where_status([:queued])
    |> update_one(Keyword.merge(reset(download, :running), started_at: now(), position: nil))
    |> case do
      nil -> {:error, :not_queued}
      running -> {:ok, running}
    end
  end

  @doc false
  # One finished file of a run, with the URL of what it is (`Contentoid.Downloads.Item`).
  def record_item(%Download{} = download, url, path) do
    item =
      Repo.insert!(%Item{url: url, path: path, download_id: download.id, downloader_name: download.downloader_name})

    Phoenix.PubSub.broadcast(Contentoid.PubSub, @items_topic, {:item, item})
    item
  end

  @doc false
  # A post-processor moved the file at `old_path` to `new_path`.
  def move_items(%Download{id: id}, old_path, new_path) do
    Repo.update_all(from(i in Item, where: i.download_id == ^id and i.path == ^old_path), set: [path: new_path])
  end

  @doc """
  What's been downloaded, newest first: every finished file with its URL. `search` keeps the ones
  whose URL contains it (any case).
  """
  @spec list_items(String.t() | nil, pos_integer()) :: [Item.t()]
  def list_items(search \\ nil, limit \\ 200) do
    Item
    |> url_containing(search)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "A download's items, in the order they finished."
  def list_download_items(%Download{id: id}) do
    Item |> where(download_id: ^id) |> order_by(asc: :inserted_at, asc: :id) |> Repo.all()
  end

  @doc "Removes one Downloaded record (its file stays on disk)."
  @spec delete_item(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def delete_item(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {1, ids} <- Item |> where([i], i.id == ^id) |> select([i], i.id) |> Repo.delete_all() do
      broadcast_items_removed(ids)
      :ok
    else
      _not_found -> {:error, :not_found}
    end
  end

  @doc """
  Removes every Downloaded record whose URL contains `search` (all of them when it's blank), as
  `list_items/2` matches; returns their ids. Files stay on disk.
  """
  @spec delete_items(String.t() | nil) :: [Ecto.UUID.t()]
  def delete_items(search) do
    {count, ids} = Item |> url_containing(search) |> select([i], i.id) |> Repo.delete_all()
    if count > 0, do: broadcast_items_removed(ids)
    ids
  end

  defp url_containing(query, search) when search in [nil, ""], do: query

  defp url_containing(query, search) do
    escaped = String.replace(search, ~r/[\\%_]/, &"\\#{&1}")
    where(query, [i], ilike(i.url, ^"%#{escaped}%"))
  end

  @doc false
  # `changes`: any of `progress`, `progress_text`, `total_progress`, `total_text`, `current_file`,
  # `files`, `phase`, `output_dir`, `log`.
  def record_progress(%Download{} = download, changes) do
    fields = [:progress, :progress_text, :total_progress, :total_text, :current_file, :files, :phase, :output_dir, :log]

    download
    |> where_status([:running])
    |> update_one(Keyword.take(changes, fields))
  end

  @doc false
  # `changes`: `status` (`:completed` or `:failed`) plus any of `progress`, `progress_text`, `files`,
  # `error`, `log`, `exit_status`. The run's total and current file are only for while it runs.
  def finish(%Download{} = download, changes) do
    fields = [:status, :progress, :progress_text, :files, :error, :log, :exit_status]
    ended = [finished_at: now(), total_progress: nil, total_text: nil, current_file: nil]

    download
    |> where_status([:running])
    |> update_one(Keyword.take(changes, fields) ++ ended)
  end

  @doc false
  # Run once at boot, before Oban starts its queues (`Contentoid.Downloads.Janitor`). Contentoid runs
  # on one node, so a download still queued or running whose job isn't waiting to run was
  # interrupted by the VM stopping, gracefully or not: its runner was killed with it (or, still
  # queued, it was waiting for a global slot), and its job may be stuck `executing`. Stuck jobs are
  # discarded and each interrupted download is queued again with a fresh job; the downloader resumes
  # from its partial files, or one interrupted in post-processing re-runs only post-processing, with
  # its files. Jobs go in through the Repo because Oban isn't running yet.
  def recover_interrupted do
    Repo.transact(fn ->
      Oban.Job
      |> where([j], j.state == "executing" and j.worker == ^inspect(Worker))
      |> Repo.update_all(set: [state: "discarded", discarded_at: DateTime.utc_now()])

      waiting = ~w(available scheduled retryable)

      downloads =
        Repo.all(
          from d in Download,
            left_join: j in Oban.Job,
            on: j.id == d.oban_job_id,
            where: d.status in [:queued, :running] and (is_nil(j.id) or j.state not in ^waiting)
        )

      # Deleting a downloader waits for its downloads, so this is only a guard.
      {requeue, orphaned} = Enum.split_with(downloads, & &1.downloader_id)

      for download <- requeue do
        job = Repo.insert!(Worker.new(%{download_id: download.id}, job_options(download)))
        download |> Ecto.Changeset.change(Keyword.put(reset(download, :queued), :oban_job_id, job.id)) |> Repo.update!()
      end

      for download <- orphaned do
        download
        |> Ecto.Changeset.change(
          status: :failed,
          error: Message.new(gettext_noop("its downloader was deleted")),
          finished_at: now()
        )
        |> Repo.update!()
      end

      {:ok, %{downloads: length(requeue)}}
    end)
  end

  # Steps keyed by `index`, so several downloads go in one transaction. The download to place is
  # `{:inserted, index}`.
  defp place(multi, index) do
    Multi.run(multi, {:download, index}, fn _repo, %{{:inserted, ^index} => download} ->
      {:ok, place_in_line(download, :by_priority)}
    end)
  end

  defp enqueue(multi, index) do
    multi
    |> Oban.insert({:job, index}, fn %{{:download, ^index} => download} ->
      options = job_options(download)
      options = if deferred?(download), do: [scheduled_at: download.start_at] ++ options, else: options
      Worker.new(%{download_id: download.id}, options)
    end)
    |> Multi.update({:queued, index}, fn %{{:download, ^index} => download, {:job, ^index} => job} ->
      Ecto.Changeset.change(download, oban_job_id: job.id)
    end)
  end

  # Oban runs a queue's jobs lowest `priority` first (0-9), so a download's 0-9, higher first, is
  # inverted.
  defp job_options(download), do: [queue: Queues.name(download.downloader_id), priority: 9 - download.priority]

  # Broadcast only once committed, in order.
  defp transact(multi, count) do
    case Repo.transact(multi) do
      {:ok, changes} -> {:ok, for(index <- 0..(count - 1)//1, do: broadcast(changes[{:queued, index}]))}
      {:error, {:inserted, index}, %Ecto.Changeset{} = changeset, _changes} -> {:error, index, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp waiting_query, do: from(d in Download, where: d.status == :queued and not is_nil(d.position))

  # Gives `download` a place in line, shifting those behind it, unless it's deferred: `:front`
  # before every waiting download, `:by_priority` after the last waiting one of the same or higher
  # priority, else first. Runs inside the caller's transaction; returns the placed download.
  defp place_in_line(%Download{} = download, mode) do
    if deferred?(download) do
      download
    else
      others = where(waiting_query(), [d], d.id != ^download.id)
      first = Repo.one(from d in others, select: min(d.position))

      position =
        case mode do
          :front ->
            first || 0

          :by_priority ->
            last = Repo.one(from d in others, where: d.priority >= ^download.priority, select: max(d.position))
            if last, do: last + 1, else: first || 0
        end

      Repo.update_all(where(others, [d], d.position >= ^position), inc: [position: 1])

      {1, [placed]} =
        Repo.update_all(from(d in Download, where: d.id == ^download.id, select: d), set: [position: position])

      placed
    end
  end

  # Every queued download that isn't deferred, in line order.
  defp waiting_ids do
    now = DateTime.utc_now()

    Repo.all(
      from d in Download,
        where: d.status == :queued and (is_nil(d.start_at) or d.start_at <= ^now),
        order_by: [asc_nulls_last: d.position, desc: d.priority, asc: d.inserted_at, asc: d.id],
        select: d.id
    )
  end

  # The fields a fresh run starts from. One that got to post-processing keeps its files, log, output
  # directory and phase, so it starts at post-processing again and appends to the log.
  defp reset(%Download{phase: :post_processing}, status) do
    [
      status: status,
      progress: nil,
      progress_text: nil,
      total_progress: nil,
      total_text: nil,
      current_file: nil,
      error: nil,
      exit_status: nil,
      started_at: nil,
      finished_at: nil
    ]
  end

  defp reset(%Download{}, status) do
    [
      status: status,
      progress: nil,
      progress_text: nil,
      total_progress: nil,
      total_text: nil,
      current_file: nil,
      files: [],
      error: nil,
      log: nil,
      exit_status: nil,
      started_at: nil,
      finished_at: nil
    ]
  end

  defp where_status(%Download{id: id}, statuses) do
    where(Download, [d], d.id == ^id and d.status in ^statuses)
  end

  # Applies `set` to the one row `query` matches, broadcasts it and returns it; nil when no row
  # matches (the download moved on).
  defp update_one(query, set) do
    set = Keyword.put(set, :updated_at, now())

    case Repo.update_all(select(query, [d], d), set: set) do
      {1, [download]} -> broadcast(download)
      {0, []} -> nil
    end
  end

  defp broadcast(%Download{} = download) do
    Phoenix.PubSub.broadcast(Contentoid.PubSub, @topic, {:download, download})
    download
  end

  defp broadcast_moved({:ok, %Download{} = download}) do
    broadcast(download)
    broadcast_reordered()
    {:ok, download}
  end

  defp broadcast_moved(error), do: error

  defp broadcast_reordered, do: Phoenix.PubSub.broadcast(Contentoid.PubSub, @topic, :queue_reordered)

  defp broadcast_items_removed(ids) do
    Phoenix.PubSub.broadcast(Contentoid.PubSub, @items_topic, {:items_removed, ids})
  end

  defp broadcast_deleted(ids) do
    Phoenix.PubSub.broadcast(Contentoid.PubSub, @topic, {:downloads_deleted, ids})
    Phoenix.PubSub.broadcast(Contentoid.PubSub, @items_topic, {:items_deleted, ids})
  end

  defp now, do: DateTime.utc_now(:second)
end

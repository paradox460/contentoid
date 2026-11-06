defmodule ContentoidWeb.DownloadsLive do
  @moduledoc """
  Downloads: queue URLs for a downloader, follow every download live, open one for its files and log,
  cancel, retry or delete it, or delete every finished one. Downloads a schedule started with an
  arguments downloader's arguments are listed too, but can't be queued here.

  Two tables: the queue (`Downloads.list_queue/1`), running downloads first and then queued ones in
  the order they run, and the finished downloads (`Downloads.list_finished/1`), the most recently
  finished first. A download moves from one to the other as it finishes, and back when retried.

  The queue can be paused and resumed (`Downloads.pause_queue/0`): running downloads finish, nothing
  new starts. Waiting downloads are dragged by their grip to reorder them (`Downloads.reorder_queue/1`);
  a deferred one can start now, at the front of the line, or get another start time.

  The URL field takes one URL per line, each queued as its own download, in order, all of them or
  none when any line is wrong (every wrong line is reported). Blank lines are skipped.

  The downloader is pre-chosen from the URLs (`Contentoid.Downloaders.match/2`) until the user picks
  one themselves; after that their choice stands until the form is submitted. Lines matching
  different downloaders leave it blank, and each URL then goes to its own match. The choice is among
  the enabled URL downloaders, refreshed when downloaders change.
  """
  use ContentoidWeb, :live_view

  alias Contentoid.Downloaders
  alias Contentoid.Downloads
  alias Contentoid.Downloads.Docker
  alias Contentoid.Downloads.Download
  alias Contentoid.Downloads.Download.Step
  alias Contentoid.Schedules
  alias ContentoidWeb.Timezone

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Downloads.subscribe()
      Downloaders.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: gettext("Downloads"), downloader_chosen?: false, start_at_local: "")
     |> assign(docker_problem: connected?(socket) && docker_problem())
     |> assign_downloaders()
     |> assign_form(%{})
     |> assign(queue_reload_pending?: false, queue_paused: Downloads.queue_paused?())
     |> load_queue()
     |> stream_configure(:finished_downloads, dom_id: &"finished-downloads-#{&1.id}")
     |> load_finished()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Downloads.get_download(id) do
      # Deleted, e.g. followed from a stale link on the Downloaded page.
      nil ->
        {:noreply, socket |> put_flash(:error, gettext("That download was deleted.")) |> push_patch(to: ~p"/downloads")}

      download ->
        schedule = download.schedule_id && Schedules.get_schedule(download.schedule_id)

        {:noreply,
         assign(socket,
           download: download,
           items: Downloads.list_download_items(download),
           schedule: schedule,
           page_title: gettext("Download · %{downloader}", downloader: download.downloader_name)
         )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, download: nil, items: [], schedule: nil, page_title: gettext("Downloads"))}
  end

  @impl true
  def handle_event("validate", %{"download" => params} = event, socket) do
    chosen? = socket.assigns.downloader_chosen? or event["_target"] == ["download", "downloader_id"]
    params = if chosen?, do: params, else: suggest_downloader(params)

    {:noreply,
     socket
     |> assign(downloader_chosen?: chosen?, start_at_local: event["start_at_local"] || "")
     |> assign_form(params)}
  end

  def handle_event("save", %{"download" => params} = event, socket) do
    local = event["start_at_local"] || ""
    lines = url_lines(params["url"])

    with {:ok, start_at} <- start_at(local, socket.assigns.timezone),
         [_ | _] <- lines,
         attrs =
           for(
             {_line, url} <- lines,
             do: %{"url" => url, "downloader_id" => params["downloader_id"], "start_at" => start_at}
           ),
         {:ok, downloads} <- Downloads.create_downloads(attrs) do
      socket =
        socket
        |> assign(downloader_chosen?: false, start_at_local: "")
        |> assign_form(%{"downloader_id" => params["downloader_id"]})

      {:noreply,
       case length(downloads) do
         1 ->
           socket

         count ->
           put_flash(
             socket,
             :info,
             ngettext("Queued %{number} download.", "Queued %{number} downloads.", count, number: number(count))
           )
       end}
    else
      :invalid_start ->
        {:noreply,
         socket
         |> assign(start_at_local: local)
         |> put_flash(:error, gettext("That start time isn't a valid date and time."))}

      [] ->
        {:noreply,
         socket
         |> assign(start_at_local: local)
         |> assign_form(params, url: {dgettext_noop("errors", "enter a URL"), []})}

      {:error, _index, %Ecto.Changeset{}} ->
        errors = line_errors(lines, params["downloader_id"])
        {:noreply, socket |> assign(start_at_local: local) |> assign_form(params, errors)}

      {:error, %Contentoid.Message{} = reason} ->
        {:noreply, socket |> assign(start_at_local: local) |> put_flash(:error, message_text(reason))}

      {:error, _reason} ->
        {:noreply, socket |> assign(start_at_local: local) |> put_flash(:error, gettext("Nothing was queued."))}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    id
    |> Downloads.get_download!()
    |> Downloads.cancel_download()
    |> case do
      {:ok, _download} ->
        {:noreply, socket}

      {:error, :not_cancellable} ->
        {:noreply, put_flash(socket, :error, gettext("That download has already finished."))}
    end
  end

  def handle_event("retry", %{"id" => id}, socket) do
    id
    |> Downloads.get_download!()
    |> Downloads.retry_download()
    |> case do
      {:ok, _download} -> {:noreply, socket}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, gettext("That download can't be retried."))}
    end
  end

  # Each closes the open download if it deleted it, in the same callback as its flash: a patch keeps
  # only the flash its own callback set.
  def handle_event("delete", %{"id" => id}, socket) do
    id
    |> Downloads.get_download!()
    |> Downloads.delete_download()
    |> case do
      {:ok, download} ->
        {:noreply, socket |> put_flash(:info, gettext("Deleted the download.")) |> close_deleted([download.id])}

      {:error, :not_finished} ->
        {:noreply, put_flash(socket, :error, gettext("Only a finished download can be deleted."))}
    end
  end

  def handle_event("delete_finished", _params, socket) do
    ids = Downloads.delete_finished_downloads()

    message =
      case length(ids) do
        0 ->
          gettext("No finished downloads to delete.")

        count ->
          ngettext("Deleted %{number} finished download.", "Deleted %{number} finished downloads.", count,
            number: number(count)
          )
      end

    {:noreply, socket |> put_flash(:info, message) |> close_deleted(ids)}
  end

  def handle_event("pause_queue", _params, socket), do: set_queue_paused(socket, Downloads.pause_queue(), true)
  def handle_event("resume_queue", _params, socket), do: set_queue_paused(socket, Downloads.resume_queue(), false)

  def handle_event("start_now", %{"id" => id}, socket) do
    id
    |> Downloads.get_download!()
    |> Downloads.start_download_now()
    |> case do
      {:ok, _download} -> {:noreply, socket}
      {:error, :not_deferred} -> {:noreply, put_flash(socket, :error, not_deferred_message())}
    end
  end

  def handle_event("reschedule", %{"download_id" => id, "start_at_local" => local}, socket) do
    case start_at(local, socket.assigns.timezone) do
      {:ok, nil} ->
        {:noreply, put_flash(socket, :error, gettext("Pick a start time."))}

      :invalid_start ->
        {:noreply, put_flash(socket, :error, gettext("That start time isn't a valid date and time."))}

      {:ok, at} ->
        id
        |> Downloads.get_download!()
        |> Downloads.reschedule_download(at)
        |> case do
          {:ok, _download} ->
            {:noreply, put_flash(socket, :info, gettext("Start time changed."))}

          {:error, :not_future} ->
            {:noreply, put_flash(socket, :error, gettext("Pick a time in the future, or use Start now."))}

          {:error, :not_deferred} ->
            {:noreply, put_flash(socket, :error, not_deferred_message())}
        end
    end
  end

  def handle_event("reorder_queue", %{"ids" => ids}, socket) when is_list(ids) do
    case Downloads.reorder_queue(ids) do
      :ok ->
        {:noreply, load_queue(socket)}

      {:error, :stale} ->
        {:noreply,
         socket |> put_flash(:error, gettext("The queue changed while you dragged; try again.")) |> load_queue()}
    end
  end

  defp set_queue_paused(socket, :ok, paused), do: {:noreply, assign(socket, queue_paused: paused)}

  defp set_queue_paused(socket, {:error, _changeset}, _paused),
    do: {:noreply, put_flash(socket, :error, gettext("Couldn't save that: try again."))}

  defp not_deferred_message, do: gettext("That download is no longer waiting for its start time.")

  @impl true
  def handle_info({:download, %Download{} = download}, socket) do
    socket = list_change(socket, download)

    case socket.assigns.download do
      # Its items are read again only when its files changed (added, moved or removed).
      %Download{id: id, files: files} when id == download.id and files != download.files ->
        {:noreply, assign(socket, download: download, items: Downloads.list_download_items(download))}

      %Download{id: id} when id == download.id ->
        {:noreply, assign(socket, download: download)}

      _other ->
        {:noreply, socket}
    end
  end

  # Listed again rather than deleted row by row: one deletion can take many, and older downloads move
  # into the listed window. The open download is still open here only when it was deleted elsewhere
  # (another tab).
  def handle_info({:downloads_deleted, ids}, socket) do
    socket = load_finished(socket)

    socket =
      if open_in?(socket, ids), do: put_flash(socket, :info, gettext("That download was deleted.")), else: socket

    {:noreply, close_deleted(socket, ids)}
  end

  def handle_info({:downloaders, :changed}, socket), do: {:noreply, assign_downloaders(socket)}

  def handle_info(:reload_queue, socket), do: {:noreply, socket |> assign(queue_reload_pending?: false) |> load_queue()}

  def handle_info(:queue_reordered, socket), do: {:noreply, request_queue_reload(socket)}

  def handle_info({:queue_paused, paused}, socket), do: {:noreply, assign(socket, queue_paused: paused)}

  # A finished download moves from the queue to the top of the finished table. A queued or running
  # one that only made progress is updated in place; anything that can move it in the queue (new,
  # started, retried) lists the queue again.
  defp list_change(socket, download) do
    cond do
      Downloads.finished?(download) ->
        socket
        |> stream_delete(:downloads, download)
        |> assign(queue_statuses: Map.delete(socket.assigns.queue_statuses, download.id), finished?: true)
        |> stream_insert(:finished_downloads, download, at: 0)

      socket.assigns.queue_statuses[download.id] == download.status ->
        stream_insert(socket, :downloads, download)

      true ->
        socket |> stream_delete(:finished_downloads, download) |> request_queue_reload()
    end
  end

  # Lists the queue again once for a burst of changes: the reload is a message behind the ones
  # already waiting.
  defp request_queue_reload(%{assigns: %{queue_reload_pending?: true}} = socket), do: socket

  defp request_queue_reload(socket) do
    send(self(), :reload_queue)
    assign(socket, queue_reload_pending?: true)
  end

  defp load_queue(socket) do
    queue = Downloads.list_queue()

    socket
    |> assign(queue_statuses: Map.new(queue, &{&1.id, &1.status}))
    |> stream(:downloads, queue, reset: true)
  end

  defp load_finished(socket) do
    finished = Downloads.list_finished()
    socket |> assign(finished?: finished != []) |> stream(:finished_downloads, finished, reset: true)
  end

  # The optional start time, typed in the viewer's time zone.
  defp start_at("", _timezone), do: {:ok, nil}

  defp start_at(local, timezone) do
    case Timezone.parse_local(local, timezone) do
      {:ok, start_at} -> {:ok, start_at}
      :error -> :invalid_start
    end
  end

  defp close_deleted(socket, ids) do
    if open_in?(socket, ids), do: push_patch(socket, to: ~p"/downloads"), else: socket
  end

  defp open_in?(%{assigns: %{download: %Download{id: id}}}, ids), do: id in ids
  defp open_in?(_socket, _ids), do: false

  # `{line number, URL}` for each line with a URL on it; blank lines skipped.
  defp url_lines(nil), do: []

  defp url_lines(text) do
    for {line, number} <- text |> String.split(["\r\n", "\n"]) |> Enum.with_index(1),
        url = String.trim(line),
        url != "",
        do: {number, url}
  end

  # The downloader every line matches, or none when they match different ones (or none).
  defp suggest_downloader(params) do
    downloaders = Downloaders.list_enabled_downloaders(input: :url)

    params["url"]
    |> url_lines()
    |> Enum.map(fn {_line, url} -> Downloaders.match(url, downloaders) end)
    |> Enum.uniq()
    |> case do
      [%{id: id}] -> Map.put(params, "downloader_id", id)
      _none_or_several -> Map.put(params, "downloader_id", "")
    end
  end

  # Every line's problems: on the URL field, numbered when there are several lines. A URL nothing
  # matches is that URL's problem, unless it isn't a URL at all, which is all it says then; a picked
  # downloader's own (it's disabled) is said once, on its field.
  defp line_errors(lines, downloader_id) do
    numbered? = match?([_, _ | _], lines)
    picked? = downloader_id not in [nil, ""]

    errors =
      for {line, url} <- lines,
          changeset = Downloads.change_new_download(%{"url" => url, "downloader_id" => downloader_id}),
          {field, {message, opts}} <-
            Keyword.take(changeset.errors, [:url]) |> then(&if(&1 == [], do: changeset.errors, else: &1)) do
        field = if field == :downloader_id and not picked?, do: :url, else: field

        if field == :url and numbered? do
          {field,
           {dgettext_noop("errors", "line %{line}: %{message}"),
            line: number(line), message: ContentoidWeb.CoreComponents.translate_error({message, opts})}}
        else
          {field, {message, opts}}
        end
      end

    Enum.uniq(errors)
  end

  defp assign_form(socket, params, errors \\ []),
    do: assign(socket, form: to_form(params, as: :download, errors: errors))

  defp assign_downloaders(socket) do
    assign(socket,
      downloader_options:
        for(downloader <- Downloaders.list_enabled_downloaders(input: :url), do: {downloader.name, downloader.id})
    )
  end

  # Why downloads can't run right now, if they can't.
  defp docker_problem do
    case Docker.ping() do
      :ok -> nil
      {:error, message} -> message_text(message)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: the rules reach into `<.table>`, `<.form>` and `<.lucide>`, whose roots
      carry `phx-r`. Everything sits inside `#downloads-page`, a scope root, so plain class
      selectors match as its descendants.
    --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      .downloads-notice {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        margin: 0 0 var(--size-4);
        max-inline-size: none;
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--destructive);
      }

      .downloads-paused {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        margin: 0 0 var(--size-2);
        max-inline-size: none;
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--warning);
      }

      .downloads-paused .iconex {
        color: var(--warning);
      }

      .download-start-form {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      .download-form {
        display: grid;
        grid-template-columns: minmax(0, 1fr) 14rem 14rem auto;
        align-items: end;
        gap: var(--size-3);
        margin-block-end: var(--size-5);
      }

      .download-form label {
        display: grid;
        gap: var(--size-1);
      }

      .download-form label > span {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      /* One height for the downloader select, the start time and the button, which line up in a row. */
      .download-form :is(input.input, select.input, .button) {
        block-size: 2.5rem;
      }

      /*
       * The URLs grow a line at a time from the row's height, up to ten lines, then scroll. An
       * explicit block-size would defeat field-sizing; without field-sizing support it stays one
       * row tall and scrolls.
       */
      .download-form textarea.input {
        field-sizing: content;
        min-block-size: 2.5rem;
        max-block-size: 10lh;
        resize: vertical;
        white-space: pre;
        overflow-x: auto;
      }

      section:scope {
        container-type: inline-size;
      }

      /* Too narrow for every column, a table scrolls sideways in its section instead of the page. */
      .downloads-section {
        overflow-x: auto;
      }

      /* An empty table says so in a line above it instead; it stays in the DOM for rows to stream into. */
      .downloads-section table:not(:has(tbody > tr)) {
        display: none;
      }

      .downloads-section + .downloads-section {
        margin-block-start: var(--size-6);
      }

      .downloads-section-head {
        display: flex;
        align-items: baseline;
        gap: var(--size-3);
        margin-block-end: var(--size-2);
      }

      .downloads-section-head h2 {
        margin: 0;
        max-inline-size: none;
        font-size: var(--font-size-2);
      }

      .downloads-section-note,
      .downloads-empty {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      /* "Delete finished" sits at the far end of its heading row. */
      .downloads-section-head .button {
        margin-inline-start: auto;
      }

      .downloads-empty {
        margin: 0 0 var(--size-2);
        max-inline-size: none;
      }

      .downloads-time {
        white-space: nowrap;
      }

      .download-status {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        white-space: nowrap;
      }

      .download-status--queued .iconex,
      .download-status--cancelled .iconex {
        color: var(--muted-foreground);
      }

      .download-status--running .iconex {
        color: var(--primary);
      }

      .download-status--completed .iconex {
        color: var(--success);
      }

      .download-status--failed .iconex {
        color: var(--destructive);
      }

      /*
       * At most 48ch, and at most 30% of the page section (the container below), so a row with
       * two actions and a timestamp still fits beside it.
       */
      .download-url {
        display: block;
        max-inline-size: min(48ch, 30cqi);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .download-progress {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        white-space: nowrap;
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .download-progress-rows {
        display: grid;
        gap: var(--size-1);
      }

      /* "Total" and "File" line up, so the two bars start at one edge. */
      .download-progress-label {
        min-inline-size: 5ch;
      }

      .download-current-file {
        min-inline-size: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        color: var(--foreground);
      }

      progress {
        appearance: none;
        inline-size: 8rem;
        block-size: 0.5rem;
        border: 1px solid var(--border-strong);
        background: var(--surface-1);
      }

      progress::-webkit-progress-bar {
        background: var(--surface-1);
      }

      progress::-webkit-progress-value {
        background: var(--primary);
      }

      progress::-moz-progress-bar {
        background: var(--primary);
      }

      .download-detail {
        display: grid;
        gap: var(--size-3);
        margin-block-end: var(--size-5);
        padding: var(--size-3);
        background: var(--surface-2);
        border: 1px solid var(--border);
      }

      .download-detail-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-3);
      }

      .download-detail h2 {
        margin: 0;
        max-inline-size: none;
        font-size: var(--font-size-2);
        overflow-wrap: anywhere;
      }

      /* The heading shows all of the URL or arguments, wrapped. */
      .download-detail h2 .download-url {
        max-inline-size: none;
        white-space: normal;
      }

      .download-muted {
        color: var(--muted-foreground);
      }

      .download-detail dl {
        display: grid;
        grid-template-columns: max-content minmax(0, 1fr);
        gap: var(--size-1) var(--size-4);
        margin: 0;
      }

      /* Normalize spaces every `dt` after the first, which drops it below its `dd` in this grid. */
      .download-detail dt {
        margin: 0;
        max-inline-size: none;
        color: var(--muted-foreground);
      }

      .download-detail dd {
        margin: 0;
        max-inline-size: none;
        overflow-wrap: anywhere;
      }

      .download-error {
        margin: 0;
        max-inline-size: none;
        padding-inline-start: var(--size-2);
        border-inline-start: 1px solid var(--destructive);
      }

      .download-files {
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .download-files li {
        display: grid;
        max-inline-size: none;
        padding: 0;
        overflow-wrap: anywhere;
      }

      .download-file-path {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .download-log {
        margin: 0;
        max-block-size: 24rem;
        overflow: auto;
        padding: var(--size-2);
        font-size: var(--font-size-0);
        background: var(--surface-1);
        border: 1px solid var(--border);
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .download-steps {
        display: grid;
        border: 1px solid var(--border);
        background: var(--surface-1);
      }

      /* Open Props' normalize pads and fills details and summary; a step is flat. */
      .download-step {
        padding: 0;
        background: none;
      }

      .download-step + .download-step {
        border-block-start: 1px solid var(--border);
      }

      .download-step-summary {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-1) var(--size-2);
      }

      summary.download-step-summary {
        margin: 0;
        background: none;
        cursor: pointer;
      }

      .download-step-status {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        font-weight: 700;
        overflow-wrap: anywhere;
      }

      .download-step-status--pending .iconex,
      .download-step-status--skipped .iconex,
      .download-step-status--cancelled .iconex {
        color: var(--muted-foreground);
      }

      .download-step-status--running .iconex {
        color: var(--primary);
      }

      .download-step-status--succeeded .iconex {
        color: var(--success);
      }

      .download-step-status--failed .iconex {
        color: var(--destructive);
      }

      .download-step-time {
        margin-inline-start: auto;
        color: var(--muted-foreground);
      }

      .download-step .download-log {
        max-inline-size: none;
        border: none;
        border-block-start: 1px solid var(--border);
      }

      .download-step-empty {
        margin: 0;
        max-inline-size: none;
        padding: var(--size-1) var(--size-2);
        border-block-start: 1px solid var(--border);
      }

      @media (--phone) {
        .download-form {
          grid-template-columns: minmax(0, 1fr);
        }

        .download-url {
          max-inline-size: 24ch;
        }
      }
    </style>
    <Layouts.app flash={@flash} active={:downloads}>
      <section id="downloads-page">
        <.header>
          {gettext("Downloads")}
          <:subtitle>
            {gettext("Each URL goes to one downloader, which runs it in its own container.")}
          </:subtitle>
        </.header>

        <p :if={@docker_problem} id="docker-problem" class="downloads-notice" role="alert">
          <.lucide name="triangle-alert" /> {@docker_problem}
        </p>

        <.form
          for={@form}
          id="download-form"
          class="download-form"
          phx-change="validate"
          phx-submit="save"
        >
          <.input
            field={@form[:url]}
            type="textarea"
            label={gettext("URLs, one per line (⌘/Ctrl+Enter to queue)")}
            placeholder="https://…"
            autocomplete="off"
            spellcheck="false"
            rows="1"
            phx-debounce="300"
            phx-hook=".SubmitOnModEnter"
            required
          />
          <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnModEnter">
            // Enter adds a line; ⌘/Ctrl+Enter queues them, as Enter did when this was one URL.
            export default {
              mounted() {
                this.el.addEventListener("keydown", (event) => {
                  if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
                    event.preventDefault();
                    this.el.form.requestSubmit();
                  }
                });
              },
            };
          </script>
          <.input
            field={@form[:downloader_id]}
            type="select"
            label={gettext("Downloader")}
            options={@downloader_options}
            prompt={gettext("Match each URL")}
          />
          <.input
            name="start_at_local"
            value={@start_at_local}
            type="datetime-local"
            label={gettext("Start at (optional)")}
          />
          <.button variant="primary" type="submit">
            <.lucide name="download" /> {gettext("Download")}
          </.button>
        </.form>

        <.download_detail
          :if={@download}
          download={@download}
          items={@items}
          schedule={@schedule}
          timezone={@timezone}
        />

        <section
          id="download-queue"
          class="downloads-section"
          aria-labelledby="download-queue-heading"
        >
          <div class="downloads-section-head">
            <h2 id="download-queue-heading">{gettext("Queue")}</h2>
            <span class="downloads-section-note">
              {gettext("Running first, then what runs next. Drag a waiting download to reorder.")}
            </span>
            <.button
              id="queue-pause"
              size="sm"
              phx-click={if(@queue_paused, do: "resume_queue", else: "pause_queue")}
            >
              <.lucide :if={@queue_paused} name="play" /><.lucide :if={!@queue_paused} name="pause" />
              {if(@queue_paused, do: gettext("Resume queue"), else: gettext("Pause queue"))}
            </.button>
          </div>
          <p :if={@queue_paused} id="queue-paused" class="downloads-paused" role="status">
            <.lucide name="pause" />
            {gettext("Paused: running downloads finish, nothing new starts until you resume.")}
          </p>
          <p :if={@queue_statuses == %{}} id="queue-empty" class="downloads-empty">
            {gettext("Nothing queued.")}
          </p>
          <.download_table id="downloads" rows={@streams.downloads} />
        </section>

        <section id="finished" class="downloads-section" aria-labelledby="finished-heading">
          <div class="downloads-section-head">
            <h2 id="finished-heading">{gettext("Finished")}</h2>
            <span class="downloads-section-note">{gettext("Most recent first")}</span>
            <.button
              :if={@finished?}
              id="delete-finished"
              size="sm"
              danger
              phx-click="delete_finished"
              data-confirm={
                gettext(
                  "Delete every finished download, with its entries on the Downloaded page? Their files stay on disk."
                )
              }
            >
              {gettext("Delete finished")}
            </.button>
          </div>
          <p :if={!@finished?} id="finished-empty" class="downloads-empty">
            {gettext("Nothing finished yet.")}
          </p>
          <.download_table
            id="finished-downloads"
            rows={@streams.finished_downloads}
            finished
          />
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :download, Download, required: true
  attr :items, :list, required: true, doc: "its files with their URLs (`Contentoid.Downloads.Item`)"
  attr :schedule, :any, default: nil, doc: "the schedule that started it, if one did"
  attr :timezone, :string, required: true

  defp download_detail(assigns) do
    ~H"""
    <section id={"download-#{@download.id}"} class="download-detail" aria-label={gettext("Download")}>
      <div class="download-detail-head">
        <h2><.target download={@download} /></h2>
        <div class="download-detail-head">
          <.actions download={@download} edit_start={false} />
          <.button size="sm" patch={~p"/downloads"} aria-label={gettext("Close")}>
            <.lucide name="x" />
          </.button>
        </div>
      </div>

      <dl>
        <dt>{gettext("Status")}</dt>
        <dd><.status status={@download.status} /></dd>
        <dt>{gettext("Downloader")}</dt>
        <dd>{@download.downloader_name}</dd>
        <dt :if={@download.phase == :post_processing}>{gettext("Stage")}</dt>
        <dd :if={@download.phase == :post_processing}>{gettext("Post-processing")}</dd>
        <dt :if={@schedule}>{gettext("Schedule")}</dt>
        <dd :if={@schedule}>
          <.link navigate={~p"/schedules/#{@schedule}/edit"}>{@schedule.name}</.link>
        </dd>
        <dt>{gettext("Queued")}</dt>
        <dd><.local_time id="download-queued-at" at={@download.inserted_at} /></dd>
        <dt :if={Downloads.deferred?(@download)}>{gettext("Starts")}</dt>
        <dd :if={Downloads.deferred?(@download)}>
          <form id="start-at-form" class="download-start-form" phx-submit="reschedule">
            <input type="hidden" name="download_id" value={@download.id} />
            <.input
              name="start_at_local"
              id="start-at-local"
              type="datetime-local"
              value={Timezone.to_local(@download.start_at, @timezone)}
              aria-label={gettext("Start time")}
              required
            />
            <.button size="sm" type="submit">{gettext("Save")}</.button>
          </form>
        </dd>
        <dt :if={@download.started_at}>{gettext("Started")}</dt>
        <dd :if={@download.started_at}>
          <.local_time id="download-started-at" at={@download.started_at} />
        </dd>
        <dt :if={@download.finished_at}>{gettext("Finished")}</dt>
        <dd :if={@download.finished_at}>
          <.local_time id="download-finished-at" at={@download.finished_at} />
        </dd>
        <dt :if={@download.exit_status}>{gettext("Exit status")}</dt>
        <dd :if={@download.exit_status}>{@download.exit_status}</dd>
      </dl>

      <p :if={@download.error} class="download-error">{message_text(@download.error)}</p>

      <div :if={@download.status == :running}>
        <.progress id={"download-#{@download.id}"} download={@download} file_name />
      </div>

      <ul :if={@items != []} class="download-files" aria-label={gettext("Files")}>
        <li :for={item <- @items}>
          <a :if={item.url} href={item.url} rel="noreferrer" target="_blank">{item.url}</a>
          <span class="download-file-path">{item.path}</span>
        </li>
      </ul>

      <section
        :if={@download.log || @download.steps != []}
        class="download-steps"
        aria-label={gettext("Log")}
      >
        <.step
          id={"download-#{@download.id}-step-download"}
          name={@download.downloader_name}
          status={downloader_step_status(@download)}
          log={@download.log}
          open={@download.steps == [] or downloader_step_status(@download) in [:running, :failed]}
        />
        <.step
          :for={{step, index} <- Enum.with_index(@download.steps)}
          id={"download-#{@download.id}-step-#{index}"}
          name={step.name}
          status={shown_step_status(step, @download)}
          log={step.log}
          started_at={step.started_at}
          finished_at={step.finished_at}
          open={shown_step_status(step, @download) in [:running, :failed]}
        />
      </section>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FollowLog">
        // The log grows while a download runs: keep its newest line in view, unless the reader
        // scrolled up to read something.
        export default {
          mounted() {
            this.el.scrollTop = this.el.scrollHeight;
          },
          beforeUpdate() {
            const el = this.el;
            this.following = el.scrollHeight - el.scrollTop - el.clientHeight < 8;
          },
          updated() {
            if (this.following) this.el.scrollTop = this.el.scrollHeight;
          },
        };
      </script>
    </section>
    """
  end

  # The downloader's own run, as a step: done once the download got to post-processing.
  defp downloader_step_status(%Download{phase: :post_processing}), do: :succeeded
  defp downloader_step_status(%Download{status: :queued}), do: :pending
  defp downloader_step_status(%Download{status: :completed}), do: :succeeded
  # :running, :failed or :cancelled.
  defp downloader_step_status(%Download{status: status}), do: status

  # A cancel (or a crash) leaves the step it stopped at running and the rest pending; only the
  # runner writes steps.
  defp shown_step_status(%Step{status: :running}, %Download{status: status}) when status != :running, do: :cancelled
  defp shown_step_status(%Step{status: :pending}, %Download{status: status}) when status != :running, do: :skipped
  defp shown_step_status(%Step{status: status}, _download), do: status

  attr :id, :string,
    required: true,
    doc:
      "its prefix; the status is appended, so a change of status renders it anew, opened or closed as that status calls for. Until then `open` is the reader's: log updates don't patch it"

  attr :name, :string, required: true
  attr :status, :atom, required: true
  attr :log, :string, default: nil
  attr :started_at, DateTime, default: nil
  attr :finished_at, DateTime, default: nil
  attr :open, :boolean, default: false

  # One run in the download's log: the downloader's or a post-processor's.
  defp step(%{status: status} = assigns) when status in [:pending, :skipped] do
    ~H"""
    <div id={"#{@id}-#{@status}"} class="download-step">
      <div class="download-step-summary">
        <.step_heading
          id={@id}
          name={@name}
          status={@status}
          started_at={@started_at}
          finished_at={@finished_at}
        />
      </div>
    </div>
    """
  end

  defp step(assigns) do
    ~H"""
    <details
      id={"#{@id}-#{@status}"}
      class="download-step"
      open={@open}
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary class="download-step-summary">
        <.step_heading
          id={@id}
          name={@name}
          status={@status}
          started_at={@started_at}
          finished_at={@finished_at}
        />
      </summary>
      <pre :if={@log} id={"#{@id}-#{@status}-log"} class="download-log" phx-hook=".FollowLog">{@log}</pre>
      <p :if={!@log} class="download-muted download-step-empty">
        {if @status == :running, do: gettext("No output yet."), else: gettext("No output.")}
      </p>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :status, :atom, required: true
  attr :started_at, :any, required: true, doc: "a `DateTime`, or nil"
  attr :finished_at, :any, required: true, doc: "a `DateTime`, or nil"

  defp step_heading(assigns) do
    ~H"""
    <span class={["download-step-status", "download-step-status--#{@status}"]}>
      <.lucide :if={@status == :pending} name="circle-dashed" />
      <.lucide :if={@status == :running} name="loader" />
      <.lucide :if={@status == :succeeded} name="check" />
      <.lucide :if={@status == :failed} name="circle-x" />
      <.lucide :if={@status == :skipped} name="circle-slash" />
      <.lucide :if={@status == :cancelled} name="ban" />
      <span class="download-step-name">{@name}</span>
    </span>
    <span class="download-muted">{step_status(@status)}</span>
    <span class="download-step-time">
      <%= cond do %>
        <% @started_at && @finished_at -> %>
          {duration(DateTime.diff(@finished_at, @started_at))}
        <% @started_at && @status == :running -> %>
          {gettext("since")} <.local_time id={"#{@id}-#{@status}-started-at"} at={@started_at} />
        <% true -> %>
          {nil}
      <% end %>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :finished, :boolean, default: false, doc: "when it finished, instead of its progress"

  # The queue's and the finished downloads' table, a row each opening the download.
  defp download_table(assigns) do
    ~H"""
    <.table
      id={@id}
      rows={@rows}
      row_click={fn {_id, download} -> JS.patch(~p"/downloads/#{download}") end}
      sort_event={!@finished && "reorder_queue"}
      sort_id={fn {_id, d} -> if d.status == :queued and not Downloads.deferred?(d), do: d.id end}
    >
      <:col :let={{_id, download}} label={gettext("Status")}>
        <.status status={download.status} />
      </:col>
      <:col :let={{_id, download}} label={gettext("URL or arguments")}>
        <.target download={download} />
      </:col>
      <:col :let={{_id, download}} label={gettext("Downloader")}>{download.downloader_name}</:col>
      <:col :let={{id, download}} :if={!@finished} label={gettext("Progress")}>
        <.progress id={id} download={download} />
      </:col>
      <:col :let={{id, download}} :if={@finished} label={gettext("Finished")}>
        <span :if={download.finished_at} class="downloads-time">
          <.local_time id={"#{id}-finished-at"} at={download.finished_at} />
        </span>
      </:col>
      <:col :let={{_id, download}} label={gettext("Files")}>{number(length(download.files))}</:col>
      <:action :let={{_id, download}}>
        <.actions download={download} />
      </:action>
    </.table>
    """
  end

  attr :download, Download, required: true

  # What it was given: its URL, or an arguments download's arguments.
  defp target(assigns) do
    ~H"""
    <span :if={@download.url} class="download-url" title={@download.url}>{@download.url}</span>
    <code :if={!@download.url && @download.arguments} class="download-url" title={@download.arguments}>
      {@download.arguments}
    </code>
    <span :if={!@download.url && !@download.arguments} class="download-muted">{gettext("no arguments")}</span>
    """
  end

  attr :status, :atom, required: true

  defp status(assigns) do
    ~H"""
    <span class={["download-status", "download-status--#{@status}"]}>
      <.lucide :if={@status == :queued} name="clock" />
      <.lucide :if={@status == :running} name="loader" />
      <.lucide :if={@status == :completed} name="check" />
      <.lucide :if={@status == :failed} name="circle-x" />
      <.lucide :if={@status == :cancelled} name="ban" />
      {download_status(@status)}
    </span>
    """
  end

  attr :id, :string, required: true, doc: "its row's or detail's DOM id, prefixing its own"
  attr :download, Download, required: true
  attr :file_name, :boolean, default: false, doc: "show the current file's name (the open download)"

  # A running download gets a bar for its current file, indeterminate when the downloader reports no
  # fraction, and above it one for the whole download when the downloader can tell how far that is
  # (a `total` message). A deferred one says when it starts.
  defp progress(assigns) do
    assigns = assign(assigns, total?: assigns.download.total_progress != nil or assigns.download.total_text != nil)

    ~H"""
    <span :if={Downloads.deferred?(@download)} class="download-progress">
      <.lucide name="calendar-clock" /> {gettext("Starts")}
      <.local_time id={"#{@id}-start-at"} at={@download.start_at} />
    </span>
    <span :if={@download.status == :running} class="download-progress-rows">
      <span :if={@total?} class="download-progress download-progress--total">
        <span class="download-progress-label">{gettext("Total")}</span>
        <.progress_bar fraction={@download.total_progress} label={gettext("Total")} />
        <span :if={@download.total_progress}>{percent(@download.total_progress)}</span>
        <span :if={@download.total_text}>{@download.total_text}</span>
      </span>
      <span class="download-progress download-progress--file">
        <span :if={@total?} class="download-progress-label">{gettext("File")}</span>
        <.progress_bar fraction={@download.progress} label={gettext("Current file")} />
        <span :if={@download.progress}>{percent(@download.progress)}</span>
        <span :if={@download.progress_text}>{@download.progress_text}</span>
        <span
          :if={@file_name && @download.current_file}
          class="download-current-file"
          title={@download.current_file}
        >
          {Path.basename(@download.current_file)}
        </span>
      </span>
    </span>
    """
  end

  attr :fraction, :float, default: nil
  attr :label, :string, required: true

  defp progress_bar(assigns) do
    ~H"""
    <progress
      max="1"
      value={@fraction}
      aria-label={
        if @fraction,
          do: gettext("%{label}: %{percent}", label: @label, percent: percent(@fraction)),
          else: gettext("%{label}: in progress", label: @label)
      }
    />
    """
  end

  attr :download, Download, required: true
  attr :edit_start, :boolean, default: true, doc: "an Edit start button for a deferred download (not in its own panel)"

  defp actions(assigns) do
    ~H"""
    <.button
      :if={Downloads.deferred?(@download)}
      size="sm"
      phx-click="start_now"
      phx-value-id={@download.id}
    >
      {gettext("Start now")}
    </.button>
    <.button
      :if={@edit_start && Downloads.deferred?(@download)}
      size="sm"
      patch={~p"/downloads/#{@download}"}
    >
      {gettext("Edit start")}
    </.button>
    <.button
      :if={@download.status in [:queued, :running]}
      size="sm"
      danger
      phx-click="cancel"
      phx-value-id={@download.id}
    >
      {gettext("Cancel")}
    </.button>
    <.button
      :if={@download.status in [:failed, :cancelled]}
      size="sm"
      phx-click="retry"
      phx-value-id={@download.id}
    >
      {if(@download.phase == :post_processing,
        do: gettext("Retry post-processing"),
        else: gettext("Retry")
      )}
    </.button>
    <.button
      :if={@download.status in [:completed, :failed, :cancelled]}
      size="sm"
      danger
      phx-click="delete"
      phx-value-id={@download.id}
      data-confirm={
        gettext(
          "Delete this download, with its entries on the Downloaded page? Its files stay on disk."
        )
      }
    >
      {gettext("Delete")}
    </.button>
    """
  end
end

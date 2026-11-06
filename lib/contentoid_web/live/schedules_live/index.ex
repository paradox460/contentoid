defmodule ContentoidWeb.SchedulesLive.Index do
  @moduledoc """
  Schedules: every schedule with its URL or arguments, timing, next run and how its last run went.
  Each can be switched on or off, run now (URL and arguments schedules alike), edited or deleted
  from here. Times are in the viewer's time zone.
  """
  use ContentoidWeb, :live_view

  alias Contentoid.Downloads
  alias Contentoid.Schedules

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Schedules.subscribe()
      Downloads.subscribe()
    end

    {:ok, socket |> assign(page_title: gettext("Schedules")) |> load()}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    schedule = Schedules.get_schedule!(id)
    {:ok, _schedule} = Schedules.update_schedule(schedule, %{enabled: not schedule.enabled})
    {:noreply, socket}
  end

  def handle_event("run", %{"id" => id}, socket) do
    id
    |> Schedules.get_schedule!()
    |> Schedules.run_now()
    |> case do
      {:ok, _download} ->
        {:noreply, put_flash(socket, :info, gettext("Started a run."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, gettext("Didn't start: %{reason}.", reason: message_text(reason)))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, schedule} = id |> Schedules.get_schedule!() |> Schedules.delete_schedule()
    {:noreply, put_flash(socket, :info, gettext("Deleted %{name}.", name: schedule.name))}
  end

  @impl true
  def handle_info({:schedules, :changed}, socket), do: {:noreply, load(socket)}

  # A run's download changes the "last run" column when it's a new run or its status moves on, not
  # on every progress write. Deleting downloads changes it too.
  def handle_info({:download, %{schedule_id: schedule_id, id: id, status: status}}, socket)
      when is_binary(schedule_id) do
    case socket.assigns.latest[schedule_id] do
      %{id: ^id, status: ^status} -> {:noreply, socket}
      _new_or_changed -> {:noreply, load(socket)}
    end
  end

  def handle_info({:download, _download}, socket), do: {:noreply, socket}
  def handle_info({:downloads_deleted, _ids}, socket), do: {:noreply, load(socket)}
  def handle_info({:queue_paused, _paused}, socket), do: {:noreply, socket}
  def handle_info(:queue_reordered, socket), do: {:noreply, socket}

  defp load(socket) do
    schedules = Schedules.list_schedules()
    latest = Schedules.latest_downloads(Enum.map(schedules, & &1.id))
    socket |> assign(latest: latest) |> stream(:schedules, schedules, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the rules reach into `<.table>`, whose root carries `phx-r`. --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      .schedule-url {
        display: block;
        max-inline-size: 36ch;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .schedule-cron {
        white-space: nowrap;
      }

      .schedule-muted {
        color: var(--muted-foreground);
      }

      .schedule-error {
        display: block;
        max-inline-size: 32ch;
        font-size: var(--font-size-0);
        color: var(--destructive);
      }

      .schedule-name {
        color: inherit;
      }
    </style>
    <Layouts.app flash={@flash} active={:schedules}>
      <section id="schedules-page">
        <.header>
          {gettext("Schedules")}
          <:subtitle>
            {gettext(
              "URLs downloaded again on a schedule, to pick up what's new, and downloaders that find their own content, run with their arguments."
            )}
          </:subtitle>
          <:actions>
            <.button variant="primary" navigate={~p"/schedules/new"}>
              <.lucide name="plus" /> {gettext("New schedule")}
            </.button>
          </:actions>
        </.header>

        <.table id="schedules" rows={@streams.schedules}>
          <:col :let={{_id, schedule}} label={gettext("Enabled")}>
            <.button
              size="sm"
              aria-pressed={to_string(schedule.enabled)}
              aria-label={
                if schedule.enabled,
                  do: gettext("Disable %{name}", name: schedule.name),
                  else: gettext("Enable %{name}", name: schedule.name)
              }
              phx-click="toggle"
              phx-value-id={schedule.id}
            >
              {if schedule.enabled, do: gettext("On"), else: gettext("Off")}
            </.button>
          </:col>
          <:col :let={{_id, schedule}} label={gettext("Name")}>
            <.link navigate={~p"/schedules/#{schedule}/edit"} class="schedule-name">{schedule.name}</.link>
          </:col>
          <:col :let={{_id, schedule}} label={gettext("URL or arguments")}>
            <span :if={schedule.url} class="schedule-url" title={schedule.url}>{schedule.url}</span>
            <code
              :if={!schedule.url && schedule.arguments}
              class="schedule-url"
              title={schedule.arguments}
            >
              {schedule.arguments}
            </code>
            <span :if={!schedule.url && !schedule.arguments} class="schedule-muted">{gettext(
              "no arguments"
            )}</span>
          </:col>
          <:col :let={{_id, schedule}} label={gettext("Downloader")}>
            <span :if={schedule.downloader}>{schedule.downloader.name}</span>
            <span :if={!schedule.downloader} class="schedule-muted">
              {pgettext("a schedule's downloader, when none is picked", "matches URL")}
            </span>
          </:col>
          <:col :let={{_id, schedule}} label={gettext("When")}>
            <code class="schedule-cron" title={schedule.timezone}>{schedule.cron}</code>
          </:col>
          <:col :let={{_id, schedule}} label={gettext("Priority")}>{number(schedule.priority)}</:col>
          <:col :let={{id, schedule}} label={gettext("Next run")}>
            <span :if={schedule.next_run_at}><.local_time
              id={"#{id}-next-run"}
              at={schedule.next_run_at}
            /></span>
            <span :if={schedule.next_run_at && schedule.jitter_seconds > 0} class="schedule-muted">
              {gettext("+ up to %{duration}", duration: duration(schedule.jitter_seconds))}
            </span>
            <span :if={!schedule.next_run_at} class="schedule-muted">{pgettext(
              "next run of a disabled schedule",
              "off"
            )}</span>
          </:col>
          <:col :let={{_id, schedule}} label={gettext("Last run")}>
            <.link :if={@latest[schedule.id]} navigate={~p"/downloads/#{@latest[schedule.id]}"}>
              {download_status(@latest[schedule.id].status)}
            </.link>
            <span :if={!@latest[schedule.id] && !schedule.last_error} class="schedule-muted">
              {pgettext("a schedule's last run", "never")}
            </span>
            <span :if={schedule.last_error} class="schedule-error">{message_text(schedule.last_error)}</span>
          </:col>
          <:action :let={{_id, schedule}}>
            <.button size="sm" phx-click="run" phx-value-id={schedule.id}>{gettext("Run now")}</.button>
          </:action>
          <:action :let={{_id, schedule}}>
            <.button size="sm" navigate={~p"/schedules/#{schedule}/edit"}>{gettext("Edit")}</.button>
          </:action>
          <:action :let={{_id, schedule}}>
            <.button
              size="sm"
              danger
              phx-click="delete"
              phx-value-id={schedule.id}
              data-confirm={
                gettext("Delete %{name}? Its downloads stay listed.", name: schedule.name)
              }
            >
              {gettext("Delete")}
            </.button>
          </:action>
        </.table>
      </section>
    </Layouts.app>
    """
  end
end

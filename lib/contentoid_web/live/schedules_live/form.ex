defmodule ContentoidWeb.SchedulesLive.Form do
  @moduledoc """
  Creates or edits a schedule (`Contentoid.Schedules.Schedule`). The next few run times are shown
  as the cron expression and time zone are edited; a new schedule's zone defaults to the viewer's.
  Picking an arguments downloader swaps the URL field for an arguments one.
  """
  use ContentoidWeb, :live_view

  alias Contentoid.Downloaders
  alias Contentoid.PostProcessors
  alias Contentoid.Schedules
  alias Contentoid.Schedules.Schedule
  alias ContentoidWeb.PostProcessorAssignments

  @impl true
  def mount(params, _session, socket) do
    downloaders = Downloaders.list_downloaders()

    {:ok,
     socket
     |> assign(
       downloader_options: downloader_options(downloaders),
       post_processors: PostProcessors.list_post_processors(),
       arguments_downloaders: for(%{input: :arguments, id: id} <- downloaders, into: MapSet.new(), do: id)
     )
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    schedule = %Schedule{cron: "0 3 * * *", timezone: socket.assigns.timezone}

    socket
    |> assign(page_title: gettext("New schedule"), schedule: schedule)
    |> assign_form(Schedules.change_schedule(schedule))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    schedule = Schedules.get_schedule!(id)

    socket
    |> assign(page_title: gettext("Edit %{name}", name: schedule.name), schedule: schedule)
    |> assign_form(Schedules.change_schedule(schedule))
  end

  @impl true
  def handle_event("validate", %{"schedule" => params}, socket) do
    changeset = Schedules.change_schedule(socket.assigns.schedule, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"schedule" => params}, socket) do
    result =
      case socket.assigns.live_action do
        :new -> Schedules.create_schedule(params)
        :edit -> Schedules.update_schedule(socket.assigns.schedule, params)
      end

    case result do
      {:ok, schedule} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved %{name}.", name: schedule.name))
         |> push_navigate(to: ~p"/schedules")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    preview =
      Schedules.preview(Ecto.Changeset.get_field(changeset, :cron), Ecto.Changeset.get_field(changeset, :timezone))

    # The preview is in the schedule's own zone, not the viewer's.
    assign(socket,
      form: to_form(changeset),
      preview: preview,
      preview_timezone: Ecto.Changeset.get_field(changeset, :timezone)
    )
  end

  # A disabled downloader can still be pinned; its runs fail until it's enabled.
  defp downloader_options(downloaders) do
    for downloader <- downloaders do
      label =
        if downloader.input == :arguments,
          do: gettext("%{name} (arguments)", name: downloader.name),
          else: downloader.name

      {if(downloader.enabled, do: label, else: gettext("%{name} (disabled)", name: label)), downloader.id}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        arguments?: MapSet.member?(assigns.arguments_downloaders, to_string(assigns.form[:downloader_id].value))
      )

    ~H"""
    <%!-- `lower-bound="none"`: the rules reach into `<.input>`, whose roots carry `phx-r`. --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      section:scope {
        max-inline-size: 48rem;
      }

      .schedule-form {
        display: grid;
        gap: var(--size-4);
      }

      .schedule-form label {
        display: grid;
        gap: var(--size-1);
      }

      .schedule-form label > span {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .schedule-form .schedule-check label > span {
        display: flex;
        align-items: center;
        font-size: inherit;
        color: inherit;
      }

      .schedule-row {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: var(--size-3);
      }

      .schedule-preview {
        margin: 0;
        padding: var(--size-2) var(--size-3);
        list-style: none;
        border: 1px solid var(--border);
      }

      .schedule-preview li {
        max-inline-size: none;
        padding: 0;
      }

      .schedule-actions {
        display: flex;
        gap: var(--size-2);
      }

      @media (--phone) {
        .schedule-row {
          grid-template-columns: minmax(0, 1fr);
        }
      }
    </style>
    <Layouts.app flash={@flash} active={:schedules}>
      <section id="schedule-page">
        <.header>
          {@page_title}
          <:subtitle>
            {gettext(
              "Downloads a URL again on a schedule, or runs an arguments downloader with its arguments. Each run is an ordinary download."
            )}
          </:subtitle>
        </.header>

        <.form
          for={@form}
          id="schedule-form"
          class="schedule-form"
          phx-change="validate"
          phx-submit="save"
        >
          <.input field={@form[:name]} label={gettext("Name")} autocomplete="off" required />
          <.input
            field={@form[:downloader_id]}
            type="select"
            label={gettext("Downloader")}
            options={@downloader_options}
            prompt={gettext("Whichever matches the URL")}
          />
          <%= if @arguments? do %>
            <.input
              field={@form[:arguments]}
              label={gettext("Arguments (optional; quote words with spaces)")}
              autocomplete="off"
              spellcheck="false"
            />
          <% else %>
            <.input
              field={@form[:url]}
              type="url"
              label={gettext("URL (a channel, playlist, profile or gallery)")}
              autocomplete="off"
              required
            />
          <% end %>
          <div class="schedule-row">
            <.input
              field={@form[:cron]}
              label={gettext("When (cron)")}
              autocomplete="off"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:timezone]}
              label={gettext("Time zone")}
              autocomplete="off"
              spellcheck="false"
              required
            />
          </div>
          <.help>
            {gettext("Minute, hour, day of month, month, day of week:")} <code>0 3 * * *</code>
            {gettext("is 3:00 every day,")} <code>*/30 * * * *</code>
            {gettext("every half hour,")} <code>0 9 * * 1-5</code>
            {gettext("9:00 on weekdays. Or")} <code>@hourly</code>, <code>@daily</code>, <code>@weekly</code>, <code>@monthly</code>.
          </.help>
          <ul
            :if={@preview}
            id="schedule-preview"
            class="schedule-preview"
            aria-label={gettext("Next runs")}
          >
            <li :for={{at, i} <- Enum.with_index(@preview)}>
              <.local_time
                id={"schedule-preview-#{i}"}
                at={at}
                format={:weekday}
                time_zone={@preview_timezone}
              />
            </li>
          </ul>
          <div class="schedule-row">
            <.input
              field={@form[:jitter]}
              label={gettext("Random delay, up to (h:m:s)")}
              placeholder={gettext("none")}
              autocomplete="off"
              spellcheck="false"
            />
            <.input
              field={@form[:priority]}
              type="number"
              min="0"
              max="9"
              label={gettext("Priority (0-9, higher first)")}
            />
          </div>
          <.help>
            {gettext("Each run starts a random time up to the delay after its run time, e.g.")}
            <code>0:30:00</code>
            {gettext(
              "for anywhere in the next half hour, so schedules due together don't all start at once; Run now starts at once. Waiting downloads start highest priority first (downloads queued by hand are 0); one already running is never stopped for a higher one."
            )}
          </.help>
          <div class="schedule-check">
            <.input field={@form[:enabled]} type="checkbox" label={gettext("Enabled")} />
          </div>
          <.help>
            {gettext(
              "A run is skipped while the previous one is still queued (or waiting out its delay) or running. If Contentoid was down at a run time, it runs once when it's back."
            )}
          </.help>

          <PostProcessorAssignments.list form={@form} post_processors={@post_processors} />

          <div class="schedule-actions">
            <.button variant="primary" type="submit" phx-disable-with={gettext("Saving…")}>{gettext(
              "Save"
            )}</.button>
            <.button navigate={~p"/schedules"}>{gettext("Cancel")}</.button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end

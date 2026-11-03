defmodule ContentoidWeb.SettingsLive do
  @moduledoc """
  Edits how downloads run (`Contentoid.Settings`): the download directory, the Docker socket, the
  global download limit, the log lines kept per download and Docker timings. The directory and
  socket in use are shown under their fields, for the saved settings, with a warning when the
  directory can't work as a host path (`Contentoid.HostPaths`).
  """
  use ContentoidWeb, :live_view

  alias Contentoid.Downloads.Docker
  alias Contentoid.HostPaths
  alias Contentoid.Settings

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get_settings()

    {:ok,
     socket
     |> assign(page_title: gettext("Settings"), settings: settings, form: to_form(Settings.change_settings(settings)))
     |> assign_statuses()}
  end

  @impl true
  def handle_event("validate", %{"setting" => params}, socket) do
    form =
      socket.assigns.settings
      |> Settings.change_settings(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"setting" => params}, socket) do
    case Settings.update_settings(params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(settings: settings, form: to_form(Settings.change_settings(settings)))
         |> assign_statuses()
         |> put_flash(:info, gettext("Settings saved."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # For the saved settings, not unsaved edits.
  defp assign_statuses(socket) do
    download_dir_status = Settings.download_dir()

    warning =
      case download_dir_status do
        {:ok, dir} -> HostPaths.warning(dir)
        {:error, _message} -> nil
      end

    assign(socket,
      download_dir_status: download_dir_status,
      download_dir_warning: warning,
      docker_socket_status: Docker.socket()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the rules reach into `<.input>`, whose roots carry `phx-r`. --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      section:scope {
        max-inline-size: 48rem;
      }

      .settings-form {
        display: grid;
        gap: var(--size-4);
      }

      .settings-form label {
        display: grid;
        gap: var(--size-1);
      }

      .settings-form label > span {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .settings-row {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: var(--size-3);
      }

      /* Text stays foreground: --warning is for marks only (DESIGN.md). */
      .settings-warning {
        display: flex;
        gap: var(--size-2);
        margin: 0;
        max-inline-size: none;
        padding: var(--size-2) var(--size-3);
        border-inline-start: 2px solid var(--warning);
        font-size: var(--font-size-0);
      }

      .settings-warning .iconex {
        flex: none;
        margin-block-start: 0.2em;
        color: var(--warning);
      }

      .settings-actions {
        display: flex;
        gap: var(--size-2);
      }

      @media (--phone) {
        .settings-row {
          grid-template-columns: minmax(0, 1fr);
        }
      }
    </style>
    <Layouts.app flash={@flash} active={:settings}>
      <section id="settings-page">
        <.header>
          {gettext("Settings")}
          <:subtitle>
            {gettext(
              "How downloads run. Saved changes apply to downloads that start afterwards; the download limit applies at once."
            )}
          </:subtitle>
        </.header>

        <.form
          for={@form}
          id="settings-form"
          class="settings-form"
          phx-change="validate"
          phx-submit="save"
        >
          <.input
            field={@form[:download_dir]}
            label={gettext("Download directory")}
            autocomplete="off"
            spellcheck="false"
          />
          <.help id="download-dir-status">
            <%= case @download_dir_status do %>
              <% {:ok, dir} -> %>
                {gettext("In use:")} <code>{dir}</code>. {gettext(
                  "Relative mount sources, such as the default downloaders' output directories, resolve under it."
                )}
              <% {:error, message} -> %>
                {message_text(message)}
            <% end %>
          </.help>
          <p
            :if={@download_dir_warning}
            id="download-dir-warning"
            class="settings-warning"
            role="alert"
          >
            <.lucide name="triangle-alert" />
            <span>{message_text(@download_dir_warning)}</span>
          </p>

          <.input
            field={@form[:docker_socket]}
            label={gettext("Docker socket")}
            placeholder={gettext("Detected")}
            autocomplete="off"
            spellcheck="false"
          />
          <.help id="docker-socket-status">
            <%= case @docker_socket_status do %>
              <% {:ok, path} -> %>
                {gettext("In use:")} <code>{path}</code>.
              <% {:error, message} -> %>
                {message_text(message)}.
            <% end %>
            {gettext("Blank:")} <code>DOCKER_HOST</code>
            {gettext("when it's")} <code>unix://…</code>, {gettext(
              "else the first of these that exists:"
            )}
            <code>/var/run/docker.sock</code>, <code>~/.docker/run/docker.sock</code>, <code>~/.orbstack/run/docker.sock</code>.
          </.help>

          <div class="settings-row">
            <.input
              field={@form[:max_concurrent_downloads]}
              type="number"
              min="1"
              max="100"
              label={gettext("Downloads at once")}
            />
            <.input
              field={@form[:log_lines]}
              type="number"
              min="1"
              max="10000"
              label={gettext("Log lines kept per download")}
            />
          </div>
          <.help>
            {gettext(
              "Downloads at once counts all downloaders together; each downloader also has its own limit. Lowering it stops nothing that's running."
            )}
          </.help>

          <div class="settings-row">
            <.input
              field={@form[:stop_grace_seconds]}
              type="number"
              min="0"
              max="30"
              label={gettext("Stop grace (seconds)")}
            />
            <.input
              field={@form[:pull_timeout_minutes]}
              type="number"
              min="1"
              max="1440"
              label={gettext("Image pull timeout (minutes)")}
            />
          </div>
          <.help>
            {gettext(
              "Stop grace is how long a cancelled or interrupted script gets to save its resume state before it's killed."
            )}
          </.help>

          <div class="settings-actions">
            <.button variant="primary" type="submit" phx-disable-with={gettext("Saving…")}>
              {gettext("Save")}
            </.button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end

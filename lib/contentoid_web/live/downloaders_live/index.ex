defmodule ContentoidWeb.DownloadersLive.Index do
  @moduledoc """
  Downloaders: every downloader, highest priority first, with its pattern, limits and image, and whether
  that image is on the Docker daemon yet (it's pulled when a download first needs it). Each can be
  switched on or off, edited or deleted from here.
  """
  use ContentoidWeb, :live_view

  alias Contentoid.Downloaders
  alias Contentoid.Downloads.Docker
  alias ContentoidWeb.ContainerComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Downloaders.subscribe()
    {:ok, socket |> assign(page_title: gettext("Downloaders"), images: %{}) |> load(connected?(socket))}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    downloader = Downloaders.get_downloader!(id)
    {:ok, _downloader} = Downloaders.update_downloader(downloader, %{enabled: not downloader.enabled})
    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id
    |> Downloaders.get_downloader!()
    |> Downloaders.delete_downloader()
    |> case do
      {:ok, downloader} ->
        {:noreply, put_flash(socket, :info, gettext("Deleted %{name}.", name: downloader.name))}

      {:error, :in_use} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("It has downloads queued or running; cancel them or let them finish first.")
         )}
    end
  end

  @impl true
  def handle_info({:downloaders, :changed}, socket), do: {:noreply, load(socket, true)}

  # Image presence is asked of Docker only once connected, so the static render never waits on it.
  defp load(socket, connected?) do
    downloaders = Downloaders.list_downloaders()

    images = if connected?, do: Docker.images_present(Enum.map(downloaders, & &1.image)), else: %{}

    socket |> assign(images: images) |> stream(:downloaders, downloaders, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the rules reach into `<.table>`, whose root carries `phx-r`. --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      .downloader-pattern {
        display: block;
        max-inline-size: 36ch;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        font-size: var(--font-size-0);
      }

      .downloader-disabled,
      .downloader-muted {
        color: var(--muted-foreground);
      }

      .downloader-name {
        color: inherit;
      }
    </style>
    <Layouts.app flash={@flash} active={:downloaders}>
      <section id="downloaders-page">
        <.header>
          {gettext("Downloaders")}
          <:subtitle>
            {gettext(
              "A URL goes to the highest-priority enabled downloader whose pattern matches it. One that takes arguments is started only by a schedule."
            )}
          </:subtitle>
          <:actions>
            <.button variant="primary" navigate={~p"/downloaders/new"}>
              <.lucide name="plus" /> {gettext("New downloader")}
            </.button>
          </:actions>
        </.header>

        <.table id="downloaders" rows={@streams.downloaders}>
          <:col :let={{_id, downloader}} label={gettext("Enabled")}>
            <.button
              size="sm"
              aria-pressed={to_string(downloader.enabled)}
              aria-label={
                if downloader.enabled,
                  do: gettext("Disable %{name}", name: downloader.name),
                  else: gettext("Enable %{name}", name: downloader.name)
              }
              phx-click="toggle"
              phx-value-id={downloader.id}
            >
              {if downloader.enabled, do: gettext("On"), else: gettext("Off")}
            </.button>
          </:col>
          <:col :let={{_id, downloader}} label={gettext("Name")}>
            <.link
              navigate={~p"/downloaders/#{downloader}/edit"}
              class={["downloader-name", !downloader.enabled && "downloader-disabled"]}
            >
              {downloader.name}
            </.link>
          </:col>
          <:col :let={{_id, downloader}} label={gettext("Pattern")}>
            <code
              :if={downloader.url_pattern}
              class="downloader-pattern"
              title={downloader.url_pattern}
            >
              {downloader.url_pattern}
            </code>
            <span :if={downloader.input == :arguments} class="downloader-muted">
              {gettext("takes arguments")}
            </span>
          </:col>
          <:col :let={{_id, downloader}} label={gettext("Priority")}>
            {number(downloader.priority)}
          </:col>
          <:col :let={{_id, downloader}} label={gettext("At once")}>
            {number(downloader.concurrency)}
          </:col>
          <:col :let={{_id, downloader}} label={gettext("Image")}>
            <ContainerComponents.image_status
              image={downloader.image}
              present={@images[downloader.image]}
            />
          </:col>
          <:action :let={{_id, downloader}}>
            <.button size="sm" navigate={~p"/downloaders/#{downloader}/edit"}>{gettext("Edit")}</.button>
          </:action>
          <:action :let={{_id, downloader}}>
            <.button
              size="sm"
              danger
              phx-click="delete"
              phx-value-id={downloader.id}
              data-confirm={
                gettext("Delete %{name}? Its finished downloads stay listed.", name: downloader.name)
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

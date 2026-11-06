defmodule ContentoidWeb.PostProcessorsLive.Index do
  @moduledoc """
  Post-processors: every post-processor, highest priority first, with when it runs and its image, and
  whether that image is on the Docker daemon yet (it's pulled when a download first needs it). Each
  can be switched on or off, edited or deleted from here.
  """
  use ContentoidWeb, :live_view

  alias Contentoid.Downloads.Docker
  alias Contentoid.PostProcessors
  alias ContentoidWeb.ContainerComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PostProcessors.subscribe()

    {:ok,
     socket
     |> assign(page_title: gettext("Post-processors"), images: %{})
     |> stream_configure(:post_processors, dom_id: &"post-processors-#{&1.id}")
     |> load(connected?(socket))}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    post_processor = PostProcessors.get_post_processor!(id)

    {:ok, _post_processor} =
      PostProcessors.update_post_processor(post_processor, %{enabled: not post_processor.enabled})

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, post_processor} = id |> PostProcessors.get_post_processor!() |> PostProcessors.delete_post_processor()
    {:noreply, put_flash(socket, :info, gettext("Deleted %{name}.", name: post_processor.name))}
  end

  @impl true
  def handle_info({:post_processors, :changed}, socket), do: {:noreply, load(socket, true)}

  # Image presence is asked of Docker only once connected, so the static render never waits on it.
  defp load(socket, connected?) do
    post_processors = PostProcessors.list_post_processors()

    images = if connected?, do: Docker.images_present(Enum.map(post_processors, & &1.image)), else: %{}

    socket |> assign(images: images) |> stream(:post_processors, post_processors, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the rules reach into `<.table>`, whose root carries `phx-r`. --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      .post-processor-disabled {
        color: var(--muted-foreground);
      }

      .post-processor-name {
        color: inherit;
      }
    </style>
    <Layouts.app flash={@flash} active={:post_processors}>
      <section id="post-processors-page">
        <.header>
          {gettext("Post-processors")}
          <:subtitle>
            {gettext(
              "Scripts run after a download succeeds, highest priority first: the downloader's and the schedule's together."
            )}
          </:subtitle>
          <:actions>
            <.button variant="primary" navigate={~p"/post-processors/new"}>
              <.lucide name="plus" /> {gettext("New post-processor")}
            </.button>
          </:actions>
        </.header>

        <.table id="post-processors" rows={@streams.post_processors}>
          <:col :let={{_id, post_processor}} label={gettext("Enabled")}>
            <.button
              size="sm"
              aria-pressed={to_string(post_processor.enabled)}
              aria-label={
                if post_processor.enabled,
                  do: gettext("Disable %{name}", name: post_processor.name),
                  else: gettext("Enable %{name}", name: post_processor.name)
              }
              phx-click="toggle"
              phx-value-id={post_processor.id}
            >
              {if post_processor.enabled, do: gettext("On"), else: gettext("Off")}
            </.button>
          </:col>
          <:col :let={{_id, post_processor}} label={gettext("Name")}>
            <.link
              navigate={~p"/post-processors/#{post_processor}/edit"}
              class={["post-processor-name", !post_processor.enabled && "post-processor-disabled"]}
            >
              {post_processor.name}
            </.link>
          </:col>
          <:col :let={{_id, post_processor}} label={gettext("Priority")}>
            {number(post_processor.priority)}
          </:col>
          <:col :let={{_id, post_processor}} label={pgettext("when a post-processor runs", "Runs")}>
            {trigger_label(post_processor.trigger)}
          </:col>
          <:col :let={{_id, post_processor}} label={gettext("Image")}>
            <ContainerComponents.image_status
              image={post_processor.image}
              present={@images[post_processor.image]}
            />
          </:col>
          <:action :let={{_id, post_processor}}>
            <.button size="sm" navigate={~p"/post-processors/#{post_processor}/edit"}>{gettext("Edit")}</.button>
          </:action>
          <:action :let={{_id, post_processor}}>
            <.button
              size="sm"
              danger
              phx-click="delete"
              phx-value-id={post_processor.id}
              data-confirm={
                gettext("Delete %{name}? Downloaders and schedules stop running it.",
                  name: post_processor.name
                )
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

  defp trigger_label(:new_files), do: gettext("When there are files")
  defp trigger_label(:always), do: gettext("After every download")
end

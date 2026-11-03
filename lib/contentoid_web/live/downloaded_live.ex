defmodule ContentoidWeb.DownloadedLive do
  @moduledoc """
  Downloaded: every downloaded file, newest first, one row per finished file with the URL
  of what it is (`Contentoid.Downloads.Item`). Searchable by URL; new files appear as they finish, and
  a deleted download's files leave with it. Records can be removed one at a time, or every record the
  search shows cleared at once (all of them when it's empty); files stay on disk.
  """
  use ContentoidWeb, :live_view

  alias Contentoid.Downloads

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Downloads.subscribe_items()
    {:ok, socket |> assign(page_title: gettext("Downloaded"), search: "") |> load()}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(search: String.trim(search)) |> load()}
  end

  def handle_event("delete_item", %{"id" => id}, socket) do
    # The list reloads from this view's own `{:items_removed, _}` broadcast.
    case Downloads.delete_item(id) do
      :ok ->
        {:noreply, put_flash(socket, :info, gettext("Removed the record."))}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("That record was already removed."))}
    end
  end

  def handle_event("clear", _params, socket) do
    message =
      case length(Downloads.delete_items(socket.assigns.search)) do
        0 ->
          gettext("Nothing to clear.")

        count ->
          ngettext("Cleared %{number} record.", "Cleared %{number} records.", count, number: number(count))
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  @impl true
  def handle_info({:item, item}, socket) do
    if matches?(item.url, socket.assigns.search),
      do: {:noreply, socket |> assign(items?: true) |> stream_insert(:items, item, at: 0)},
      else: {:noreply, socket}
  end

  # Listed again rather than deleted row by row, so older records move into the listed window.
  def handle_info({:items_deleted, _download_ids}, socket), do: {:noreply, load(socket)}
  def handle_info({:items_removed, _item_ids}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    items = Downloads.list_items(socket.assigns.search)
    socket |> assign(items?: items != []) |> stream(:items, items, reset: true)
  end

  defp matches?(_url, ""), do: true
  defp matches?(nil, _search), do: false
  defp matches?(url, search), do: String.contains?(String.downcase(url), String.downcase(search))

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the rules reach into `<.table>` and `<.input>`, whose roots carry `phx-r`. --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      .downloaded-search {
        max-inline-size: 36rem;
        margin-block-end: var(--size-4);
      }

      .downloaded-url,
      .downloaded-path {
        display: block;
        max-inline-size: 48ch;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .downloaded-path {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .downloaded-when {
        white-space: nowrap;
      }
    </style>
    <Layouts.app flash={@flash} active={:downloaded}>
      <section id="downloaded-page">
        <.header>
          {gettext("Downloaded")}
          <:subtitle>
            {gettext("Every downloaded file, with the URL of what it is.")}
          </:subtitle>
          <:actions>
            <.button
              :if={@items?}
              id="clear-downloaded"
              size="sm"
              danger
              phx-click="clear"
              data-confirm={
                if(@search == "",
                  do:
                    gettext(
                      "Clear every Downloaded record? Files stay on disk; downloads stay listed."
                    ),
                  else:
                    gettext(
                      "Clear every Downloaded record whose URL contains \"%{search}\"? Files stay on disk.",
                      search: @search
                    )
                )
              }
            >
              {if(@search == "", do: gettext("Clear all"), else: gettext("Clear matching"))}
            </.button>
          </:actions>
        </.header>

        <form id="downloaded-search" class="downloaded-search" phx-change="search" phx-submit="search">
          <.input
            name="search"
            value={@search}
            type="search"
            label={gettext("URL contains")}
            autocomplete="off"
            phx-debounce="250"
          />
        </form>

        <.table id="items" rows={@streams.items}>
          <:col :let={{id, item}} label={gettext("When")}>
            <span class="downloaded-when"><.local_time id={"#{id}-when"} at={item.inserted_at} /></span>
          </:col>
          <:col :let={{_id, item}} label={gettext("URL")}>
            <a
              :if={item.url}
              class="downloaded-url"
              href={item.url}
              title={item.url}
              rel="noreferrer"
              target="_blank"
            >{item.url}</a>
            <span class="downloaded-path" title={item.path}>{item.path}</span>
          </:col>
          <:col :let={{_id, item}} label={gettext("Downloader")}>{item.downloader_name}</:col>
          <:action :let={{_id, item}}>
            <.button size="sm" navigate={~p"/downloads/#{item.download_id}"}>{gettext("Details")}</.button>
            <.button
              size="sm"
              danger
              phx-click="delete_item"
              phx-value-id={item.id}
              data-confirm={gettext("Remove this record? Its file stays on disk.")}
            >
              {gettext("Remove")}
            </.button>
          </:action>
        </.table>
      </section>
    </Layouts.app>
    """
  end
end

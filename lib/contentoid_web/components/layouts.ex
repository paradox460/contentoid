defmodule ContentoidWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ContentoidWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout: a navigation pane on the left holding all of the app's navigation, and
  the page in the pane on its right. There is no top bar. On phones the navigation pane becomes a
  drawer (Popover API) opened from a button at the top of the page pane.

  `active` names the navigation item the page belongs to, which is marked `aria-current="page"`.

  ## Examples

      <Layouts.app flash={@flash} active={:downloads}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, default: nil, doc: "the navigation item this page belongs to"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: the navigation items are `<.link>` roots, which carry `phx-r`; the
      default exclusive bound would cut them off. With no bound every element carrying this block's
      marker is a scope root, so the root rule is a tag-qualified `:scope` selector.
    --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      div:scope {
        flex: 1 1 auto;
        min-block-size: 0;
        display: grid;
        grid-template-columns: 15rem minmax(0, 1fr);
      }

      /* An in-flow column above the phone breakpoint. It carries `popover` for the phone drawer, so
         these undo the UA's popover styles (author styles outrank its `display: none`). */
      .app-nav {
        position: static;
        inset: auto;
        margin: 10px;
        inline-size: auto;
        block-size: auto;
        min-block-size: 0;
        display: flex;
        flex-direction: column;
        overflow: auto;
        padding: 0;
        color: inherit;
        background: var(--surface-2);
        border: 0;
        border: 1px solid var(--border);
      }

      .app-nav-brand {
        flex: 0 0 auto;
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-3);
        font-size: 1.15rem;
        font-weight: 700;
        color: inherit;
        text-decoration: none;
        border-block-end: 1px solid var(--border);
      }

      .app-nav-list {
        flex: 1 1 auto;
        display: flex;
        flex-direction: column;
        margin: 0;
        padding: var(--size-2) 0;
        list-style: none;
      }

      .app-nav-list li {
        max-inline-size: none;
        padding: 0;
      }

      .app-nav-item {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-1) var(--size-3);
        color: var(--muted-foreground);
        text-decoration: none;
        border-inline-start: 1px solid transparent;
      }

      .app-nav-item:hover {
        color: var(--foreground);
        background: var(--surface-3);
      }

      .app-nav-item[aria-current="page"] {
        color: var(--foreground);
        background: var(--surface-3);
      }

      .app-nav-footer {
        flex: 0 0 auto;
        margin: 0;
        max-inline-size: none;
        padding: var(--size-2) var(--size-3);
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
        border-block-start: 1px solid var(--border);
      }

      main.app-main {
        min-block-size: 0;
        overflow: auto;
        padding: var(--size-4) var(--size-5);
      }

      .app-nav-toggle {
        display: none;
      }

      @media (--phone) {
        div:scope {
          grid-template-columns: minmax(0, 1fr);
        }

        .app-nav {
          position: fixed;
          inset: 0 auto 0 0;
          inline-size: min(18rem, 85vw);
          border-inline-end: 1px solid var(--border-strong);
        }

        .app-nav:not(:popover-open) {
          display: none;
        }

        main.app-main {
          padding: var(--size-3);
        }

        .app-nav-toggle {
          display: inline-flex;
          margin-block-end: var(--size-3);
        }
      }
    </style>
    <div>
      <nav id="app-nav" class="app-nav" aria-label={gettext("Main")} popover phx-hook=".NavDrawer">
        <.link navigate={~p"/downloads"} class="app-nav-brand">
          <.lucide name="download" /> Contentoid
        </.link>
        <ul class="app-nav-list">
          <li>
            <.nav_item navigate={~p"/downloads"} active={@active == :downloads}>
              <.lucide name="arrow-down-to-line" /> {gettext("Downloads")}
            </.nav_item>
          </li>
          <li>
            <.nav_item navigate={~p"/downloaded"} active={@active == :downloaded}>
              <.lucide name="archive" /> {gettext("Downloaded")}
            </.nav_item>
          </li>
          <li>
            <.nav_item navigate={~p"/schedules"} active={@active == :schedules}>
              <.lucide name="calendar-clock" /> {gettext("Schedules")}
            </.nav_item>
          </li>
          <li>
            <.nav_item navigate={~p"/downloaders"} active={@active == :downloaders}>
              <.lucide name="container" /> {gettext("Downloaders")}
            </.nav_item>
          </li>
          <li>
            <.nav_item navigate={~p"/post-processors"} active={@active == :post_processors}>
              <.lucide name="workflow" /> {gettext("Post-processors")}
            </.nav_item>
          </li>
          <li>
            <.nav_item navigate={~p"/settings"} active={@active == :settings}>
              <.lucide name="settings" /> {gettext("Settings")}
            </.nav_item>
          </li>
        </ul>
        <p class="app-nav-footer">v{Application.spec(:contentoid, :vsn)}</p>
      </nav>
      <main class="app-main">
        <.button
          icon
          class="app-nav-toggle"
          popovertarget="app-nav"
          aria-label={gettext("Open navigation")}
        >
          <.lucide name="menu" />
        </.button>
        {render_slot(@inner_block)}
      </main>
    </div>
    <.flash_group flash={@flash} />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NavDrawer">
      // On phones the navigation pane is a popover drawer. Following a link inside it patches the
      // page without replacing the drawer, so close it here.
      export default {
        mounted() {
          this.el.addEventListener("click", (event) => {
            if (event.target.closest("a") && this.el.matches(":popover-open")) {
              this.el.hidePopover();
            }
          });
        },
      };
    </script>
    """
  end

  # The icon is part of the slot, as a literal `<.lucide name="…" />`, so the iconex compiler sees it.
  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_item(assigns) do
    ~H"""
    <.link navigate={@navigate} class="app-nav-item" aria-current={@active && "page"}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  The plain `:info` entry clears itself after five seconds; errors stay until closed.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      div:scope {
        position: fixed;
        bottom: calc(var(--panel-gap) * 2);
        translate: -50% 0;
        left: 50%;
        z-index: 100;
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        max-inline-size: min(28rem, calc(100vw - 2 * var(--panel-gap)));
        pointer-events: none;
      }
    </style>

    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} dismiss_after={5000} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={JS.remove_attribute("hidden", to: ".phx-client-error #client-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "#client-error")}
        hidden
      >
        {gettext("Attempting to reconnect")}
      </.flash>
      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={JS.remove_attribute("hidden", to: ".phx-server-error #server-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "#server-error")}
        hidden
      >
        {gettext("Attempting to reconnect")}
      </.flash>
    </div>
    """
  end
end

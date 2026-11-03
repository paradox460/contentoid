defmodule ContentoidWeb.CoreComponents do
  @moduledoc """
  The app's UI building blocks. Components style themselves with colocated CSS
  (`ContentoidWeb.ColocatedScopedCSS`, or `ContentoidWeb.ColocatedCSS` where scoping cannot reach),
  icons are Lucide via Iconex (`<.lucide name="x" />`), and there is no Tailwind.
  """
  use Phoenix.Component
  use Gettext, backend: ContentoidWeb.Gettext

  import Iconex, only: [lucide: 1]

  alias Phoenix.HTML.Form
  alias Phoenix.HTML.FormField
  alias Phoenix.LiveView.JS
  alias Phoenix.LiveView.LiveStream

  @doc """
  Renders flash notices.

  A flash value is a message string, or `%{message: text, action: label, path: path}` for a
  notice with a link (e.g. "Review"), so a prompt can sit in the flash instead of interrupting.

  `key` is the flash entry shown, `kind` by default. A prompt that must not be replaced by an
  unrelated notice of the same kind has a key of its own (`Layouts.flash_group/1` lists them).

  `dismiss_after` (milliseconds) clears the entry on its own once that long has passed with the
  pointer off it and focus outside it; a new message in the same entry starts the count again.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} key={:download} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling, and for lookup without a `key`"
  attr :key, :atom, default: nil, doc: "the flash entry to show, when not `kind`"
  attr :dismiss_after, :integer, default: nil, doc: "clears the entry after this many ms; nil keeps it"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign(assigns, :key, assigns.key || assigns.kind)
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.key}" end)

    ~H"""
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      :scope {
        pointer-events: auto;
        display: flex;
        align-items: flex-start;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        background: var(--surface-1);
        border: 1px solid var(--border-strong);
      }

      :scope[hidden] {
        display: none;
      }

      :scope[data-kind="error"] {
        border-inline-start-color: var(--destructive);
      }

      .flash-body {
        flex: 1 1 auto;
        min-width: 0;
      }

      .flash-title,
      .flash-message {
        margin: 0;
        max-inline-size: none;
      }

      .flash-title {
        font-weight: 700;
      }

      :scope[data-kind="error"] .flash-title {
        color: var(--destructive);
      }

      .flash-close {
        flex: 0 0 auto;
        padding: 0;
        border: 0;
        background: none;
        color: var(--muted-foreground);
        font: inherit;
        cursor: pointer;
      }

      .flash-action {
        display: inline-block;
        margin-top: var(--size-1);
        color: var(--primary);
        font-weight: 700;
      }
    </style>

    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @key)}
      id={@id}
      data-flash
      data-kind={@kind}
      data-flash-key={@key}
      data-dismiss-after={@dismiss_after}
      phx-hook=".AutoDismiss"
      role="alert"
      {@rest}
    >
      <div class="flash-body">
        <p :if={@title} class="flash-title">{@title}</p>

        <p class="flash-message">{flash_message(msg)}</p>
        <.link :if={flash_path(msg)} navigate={flash_path(msg)} class="flash-action">
          {flash_action(msg)}
        </.link>
      </div>

      <button
        type="button"
        class="flash-close"
        phx-click={JS.push("lv:clear-flash", value: %{key: @key})}
        aria-label={gettext("close")}
      >
        <.lucide name="x" />
      </button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoDismiss">
      // Clears the flash entry after `data-dismiss-after` ms (none: never), paused while the pointer
      // is over it or focus is inside it so it can be read and its link followed. Patches that leave
      // the text alone (any re-render of the page) keep the running count; a new message restarts it.
      export default {
        mounted() {
          if (!this.el.dataset.dismissAfter) return;
          this.text = this.el.textContent;
          this.hovered = false;
          this.focused = false;
          this.el.addEventListener("pointerenter", () =>
            this.hold({ hovered: true }),
          );
          this.el.addEventListener("pointerleave", () =>
            this.hold({ hovered: false }),
          );
          this.el.addEventListener("focusin", () => this.hold({ focused: true }));
          this.el.addEventListener("focusout", (e) => {
            if (!this.el.contains(e.relatedTarget)) this.hold({ focused: false });
          });
          this.restart();
        },
        updated() {
          if (!this.el.dataset.dismissAfter || this.el.textContent === this.text)
            return;
          this.text = this.el.textContent;
          this.restart();
        },
        destroyed() {
          clearTimeout(this.timer);
        },
        restart() {
          clearTimeout(this.timer);
          this.timer = null;
          this.remaining = Number(this.el.dataset.dismissAfter);
          this.schedule();
        },
        hold(state) {
          Object.assign(this, state);
          this.schedule();
        },
        schedule() {
          if (this.timer) {
            clearTimeout(this.timer);
            this.remaining -= performance.now() - this.startedAt;
            this.timer = null;
          }
          if (this.hovered || this.focused) return;
          this.startedAt = performance.now();
          this.timer = setTimeout(
            () => {
              this.timer = null;
              // Disconnected: the rejoin renders without the flash anyway.
              this.pushEvent("lv:clear-flash", {
                key: this.el.dataset.flashKey,
              }).catch(() => {});
            },
            Math.max(0, this.remaining),
          );
        },
      };
    </script>
    """
  end

  defp flash_message(%{message: message}), do: message
  defp flash_message(message), do: message

  defp flash_path(%{path: path}), do: path
  defp flash_path(_message), do: nil

  defp flash_action(%{action: action}), do: action
  defp flash_action(_message), do: nil

  @doc """
  The app's button: a rectangle with a label (or an icon on a backdrop). It is also the app's
  button-styled link: given `navigate`, `patch` or `href` it renders `<.link>` (an `<a>`), else a
  `<button>` (`type="button"` unless told otherwise). Cancel controls are secondary buttons, as links
  when they navigate away and as buttons when they fire an event.

    * `variant`: `"primary"` (filled; the screen's main action) or `"secondary"` (outlined; the
      default).
    * `danger`: destructive. Red text and a red fill on hover (primary: a red fill).
    * `icon`: icon-only, with square padding. Give it an `aria-label`.
    * `size="sm"`: the compact toolbar size.
    * `block`: full width, content centered.

  On a secondary button `aria-pressed="true"` marks a toggle on (accent outline), `"mixed"` partly on
  (dashed accent).

  Borderless controls (bare toolbar icons, close crosses) are not buttons in this sense and keep
  their own styling.

  Styles are global (`ContentoidWeb.ColocatedCSS`) because a `<.link>` root carries no scope
  marker. `class` is a caller hook for layout only (margins, flex); the element is this component's
  root, so the caller's rule must sit in a `lower-bound="none"` or `"inclusive"` block to reach it.
  """
  attr :variant, :string, default: "secondary", values: ~w(primary secondary)
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :icon, :boolean, default: false, doc: "icon-only; pair with an aria-label"
  attr :danger, :boolean, default: false
  attr :block, :boolean, default: false, doc: "full width, content centered"
  attr :type, :string, default: "button", doc: "ignored for links"
  attr :class, :any, default: nil, doc: "layout hook for the caller; see the moduledoc"

  attr :rest, :global,
    include:
      ~w(href navigate patch replace method csrf_token download form formmethod name value disabled popovertarget popovertargetaction commandfor command)

  slot :inner_block, required: true

  def button(assigns) do
    assigns =
      assign(assigns, :classes, [
        "button",
        "button--#{assigns.variant}",
        assigns.size == "sm" && "button--sm",
        assigns.icon && "button--icon",
        assigns.danger && "button--danger",
        assigns.block && "button--block",
        assigns.class
      ])

    if link?(assigns.rest) do
      ~H"""
      <.link class={@classes} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <style :type={ContentoidWeb.ColocatedCSS}>
        /* A 1px border on both variants (transparent on primary), so a primary and a secondary side
           by side are the same height. */
        .button {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          gap: var(--size-1);
          padding: var(--size-1) var(--size-2);
          border: 1px solid transparent;
          font: inherit;
          text-decoration: none;
          white-space: nowrap;
          cursor: pointer;
          transition:
            background-color 150ms ease,
            color 150ms ease,
            border-color 150ms ease;
        }

        /* `display: inline-flex` outranks the UA `[hidden] { display: none }`. */
        .button[hidden] {
          display: none;
        }

        .button:disabled,
        .button[aria-disabled="true"] {
          opacity: 0.4;
          cursor: default;
        }

        .button--sm {
          font-size: 0.85rem;
        }

        /* `line-height: 0` so the box hugs the 1em icon instead of a text line. */
        .button--icon {
          padding: var(--size-1);
          line-height: 0;
        }

        .button--block {
          display: flex;
          inline-size: 100%;
        }

        .button--primary {
          background: var(--primary);
          color: var(--primary-foreground);
        }

        .button--primary:hover:not(:disabled, [aria-disabled="true"]) {
          filter: brightness(1.5);
        }

        .button--secondary {
          border-color: var(--border-strong);
          background: none;
          color: var(--muted-foreground);
        }

        .button--secondary:hover:not(:disabled, [aria-disabled="true"]) {
          color: var(--foreground);
          background: var(--surface-2);
        }

        .button--secondary[aria-pressed="true"] {
          color: var(--primary);
          border-color: var(--primary);
        }

        .button--secondary[aria-pressed="mixed"] {
          color: var(--primary);
          border-color: var(--primary);
          border-style: dashed;
        }

        .button--danger {
          color: var(--destructive);
        }

        .button--danger:hover:not(:disabled, [aria-disabled="true"]),
        .button--primary.button--danger {
          color: var(--destructive-foreground);
          background: var(--destructive);
        }

        @media (--coarse) {
          .button {
            min-block-size: var(--touch-target);
          }

          .button--icon {
            min-inline-size: var(--touch-target);
          }
        }
      </style>
      <button type={@type} class={@classes} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  defp link?(rest), do: Enum.any?([:href, :navigate, :patch], &Map.has_key?(rest, &1))

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * `type="textarea"` renders a `<textarea>`

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, FormField, doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"

  attr :rest, :global, include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span>
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "input-check"}
            aria-invalid={@errors != [] && "true"}
            {@rest}
          />{@label}
        </span>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <label for={@id}>
        <span :if={@label}>{@label}</span>
        <select
          id={@id}
          name={@name}
          class={@class || "input"}
          multiple={@multiple}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Form.options_for_select(@options, @value)}
        </select>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="input-wrapper">
      <label for={@id}>
        <span :if={@label}>{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={@class || "input"}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        >{Form.normalize_value("textarea", @value)}</textarea>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <style :type={ContentoidWeb.ColocatedCSS}>
      .input {
        display: block;
        width: 100%;
        font: inherit;
        color: var(--foreground);
        background: var(--surface-1);
        border: 1px solid var(--border-strong);
        padding: var(--size-2);
      }

      input[type="checkbox"].input-check {
        display: inline-block;
        width: auto;
        margin-right: var(--size-1);
        accent-color: var(--primary);
      }
    </style>
    <div class="input-wrapper">
      <label for={@id}>
        <span :if={@label}>{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={@class || "input"}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        />
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  @doc false
  def error(assigns) do
    ~H"""
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      :scope {
        margin: var(--size-1) 0 0;
        max-inline-size: none;
        font-size: 0.8rem;
        color: var(--destructive);
      }
    </style>

    <p class="input-error">
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(ContentoidWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(ContentoidWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <style :type={ContentoidWeb.ColocatedScopedCSS}>
      :scope {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-4);
        padding-block-end: var(--size-4);
      }

      .header-title {
        margin: 0;
        max-inline-size: none;
        font-size: var(--font-size-4);
        font-weight: 700;
      }

      .header-subtitle {
        margin: var(--size-1) 0 0;
        max-inline-size: none;
        color: var(--muted-foreground);
      }

      .header-actions {
        flex: 0 0 auto;
        display: flex;
        gap: var(--size-2);
      }
    </style>
    <header>
      <div>
        <h1 class="header-title">{render_slot(@inner_block)}</h1>
        <p :if={@subtitle != []} class="header-subtitle">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="header-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc "A form's help text, small and muted, as wide as its container."
  attr :rest, :global
  slot :inner_block, required: true

  def help(assigns) do
    ~H"""
    <style :type={ContentoidWeb.ColocatedScopedCSS}>
      :scope {
        margin: 0;
        max-inline-size: none;
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }
    </style>
    <p {@rest}>{render_slot(@inner_block)}</p>
    """
  end

  @doc """
  The grip a sortable table row is dragged by (`SortableRows`, `assets/js/hooks/sortable_rows.ts`;
  `table/1`'s `sort_event`). Global CSS (`ContentoidWeb.ColocatedCSS`): the drag classes land on the
  caller's rows, and SortableJS's floating copy and the page's `grabbing` cursor sit outside any scope.
  """
  def drag_handle(assigns) do
    ~H"""
    <style :type={ContentoidWeb.ColocatedCSS}>
      .drag-handle {
        line-height: 0;
        color: var(--muted-foreground);
        cursor: grab;
        touch-action: none;
      }

      .drag-handle:hover {
        color: var(--foreground);
      }

      @media (--coarse) {
        .drag-handle {
          display: inline-block;
          padding: calc((var(--touch-target) - 1em) / 2);
          margin: calc((1em - var(--touch-target)) / 2);
        }
      }

      /* Where the dragged row will land. */
      .drag-ghost {
        outline: 1px dashed var(--primary);
        outline-offset: -1px;
      }

      .drag-ghost > * {
        opacity: 0.6;
      }

      /* SortableJS's floating copy of the row: the ghost in place shows where it goes instead. */
      .drag-fallback {
        visibility: hidden;
      }

      :root.drag-active,
      :root.drag-active * {
        cursor: grabbing !important;
      }
    </style>
    <span class="drag-handle" data-drag-handle aria-hidden="true" title={gettext("Drag to reorder")}>
      <.lucide name="grip-vertical" />
    </span>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :sort_event, :any,
    default: nil,
    doc: ~s|drag-to-reorder: the event a drop pushes, with %{"ids" => ids} in the new order; nil or false for none|

  attr :sort_id, :any,
    default: nil,
    doc: "with sort_event: a function giving a row's id to reorder by, or nil for a row that can't be dragged"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <style :type={ContentoidWeb.ColocatedScopedCSS}>
      :scope {
        inline-size: 100%;
        border-collapse: collapse;
      }

      th,
      td {
        padding: var(--size-2) var(--size-3);
        max-inline-size: none;
        text-align: start;
        border-block-end: 1px solid var(--border);
      }

      th {
        font-size: var(--font-size-0);
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: var(--font-letterspacing-2);
        color: var(--muted-foreground);
      }

      tbody tr:nth-child(even) {
        background: var(--surface-2);
      }

      .table-clickable {
        cursor: pointer;
      }

      .table-action-cell {
        inline-size: 0;
        white-space: nowrap;
      }

      .table-actions {
        display: flex;
        gap: var(--size-4);
      }

      .table-sr-only {
        position: absolute;
        inline-size: 1px;
        block-size: 1px;
        overflow: hidden;
        clip-path: inset(50%);
        white-space: nowrap;
      }

      .table-drag-cell {
        inline-size: 0;
        padding-inline-end: 0;
      }
    </style>
    <table>
      <thead>
        <tr>
          <th :if={@sort_event}><span class="table-sr-only">{gettext("Reorder")}</span></th>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="table-sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody
        id={@id}
        phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
        phx-hook={@sort_event && "SortableRows"}
        data-sort-event={@sort_event}
      >
        <tr
          :for={row <- @rows}
          id={@row_id && @row_id.(row)}
          data-sort-id={@sort_event && @sort_id.(row)}
        >
          <td :if={@sort_event} class="table-drag-cell"><.drag_handle :if={@sort_id.(row)} /></td>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "table-clickable"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="table-action-cell">
            <div class="table-actions">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end
end

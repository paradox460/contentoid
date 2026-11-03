defmodule ContentoidWeb.ContainerComponents do
  @moduledoc """
  What downloaders, post-processors and post-processor assignments share about a container: the
  row editors for mounts, named volumes and files, added and removed in place and sent with
  `_sort`/`_drop` params (`Phoenix.Component.inputs_for/1`) named after the field, and an image's
  name marked when it isn't on the Docker daemon yet.
  """
  use ContentoidWeb, :html

  alias Phoenix.HTML.FormField

  @doc "The mounts or named volumes of an owner, a row each: a host path or volume name, a container path, read-only."
  attr :field, FormField, required: true, doc: "the owner's `mounts` or `volumes`"
  attr :kind, :atom, values: [:mount, :volume], default: :mount

  def binds(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: the rows' rules reach into `<.input>` and `<.inputs_for>` content. Every
      element carrying this block's marker is a scope root, so the root rule is tag-qualified.
    --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      div:scope {
        display: grid;
        gap: var(--size-3);
      }

      /* A mount or volume: two paths, read-only, remove. */
      .container-bind {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) auto auto;
        align-items: end;
        gap: var(--size-3);
      }

      .container-check label > span {
        display: flex;
        align-items: center;
        font-size: inherit;
        color: inherit;
      }

      @media (--phone) {
        .container-bind {
          grid-template-columns: minmax(0, 1fr);
        }
      }
    </style>
    <div class="container-binds">
      <.error :for={message <- Enum.map(@field.errors, &translate_error/1)}>{message}</.error>
      <.inputs_for :let={bind} field={@field}>
        <div class="container-bind">
          <input
            type="hidden"
            name={"#{@field.form.name}[#{@field.field}_sort][]"}
            value={bind.index}
          />
          <.input
            :if={@kind == :mount}
            field={bind[:source]}
            label={gettext("Host path")}
            autocomplete="off"
          />
          <.input
            :if={@kind == :volume}
            field={bind[:name]}
            label={gettext("Volume name")}
            autocomplete="off"
          />
          <.input field={bind[:target]} label={gettext("Path in the container")} autocomplete="off" />
          <div class="container-check">
            <.input field={bind[:read_only]} type="checkbox" label={gettext("Read-only")} />
          </div>
          <.button
            icon
            type="button"
            name={"#{@field.form.name}[#{@field.field}_drop][]"}
            value={bind.index}
            phx-click={JS.dispatch("change")}
            aria-label={
              if @kind == :mount, do: gettext("Remove mount"), else: gettext("Remove volume")
            }
          >
            <.lucide name="x" />
          </.button>
        </div>
      </.inputs_for>
      <input type="hidden" name={"#{@field.form.name}[#{@field.field}_drop][]"} />
      <div>
        <.button
          size="sm"
          type="button"
          name={"#{@field.form.name}[#{@field.field}_sort][]"}
          value="new"
          phx-click={JS.dispatch("change")}
        >
          <.lucide name="plus" /> {if @kind == :mount,
            do: gettext("Add mount"),
            else: gettext("Add volume")}
        </.button>
      </div>
    </div>
    """
  end

  @doc "An owner's files, a row each: name, directory in the container, then the contents across the row."
  attr :field, FormField, required: true, doc: "the owner's `files`"
  attr :directory_placeholder, :string, required: true

  def files(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`, as in `binds/1`. --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      div:scope {
        display: grid;
        gap: var(--size-3);
      }

      /* A file: its name and directory, remove, then its contents across the row. */
      .container-file {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) auto;
        align-items: end;
        gap: var(--size-3);
        padding-block-end: var(--size-3);
        border-block-end: 1px solid var(--border);
      }

      .container-file-contents {
        grid-column: 1 / -1;
      }

      .container-file-contents textarea {
        min-block-size: 10rem;
        font-size: var(--font-size-0);
        white-space: pre;
        tab-size: 2;
      }

      @media (--phone) {
        .container-file {
          grid-template-columns: minmax(0, 1fr);
        }
      }
    </style>
    <div class="container-files">
      <.error :for={message <- Enum.map(@field.errors, &translate_error/1)}>{message}</.error>
      <.inputs_for :let={file} field={@field}>
        <div class="container-file">
          <input
            type="hidden"
            name={"#{@field.form.name}[#{@field.field}_sort][]"}
            value={file.index}
          />
          <.input
            field={file[:name]}
            label={gettext("File name")}
            autocomplete="off"
            placeholder="config"
          />
          <.input
            field={file[:directory]}
            label={gettext("Directory in the container")}
            autocomplete="off"
            placeholder={@directory_placeholder}
          />
          <.button
            icon
            type="button"
            name={"#{@field.form.name}[#{@field.field}_drop][]"}
            value={file.index}
            phx-click={JS.dispatch("change")}
            aria-label={gettext("Remove file")}
          >
            <.lucide name="x" />
          </.button>
          <div class="container-file-contents">
            <.input
              field={file[:contents]}
              type="textarea"
              label={gettext("Contents")}
              spellcheck="false"
            />
          </div>
        </div>
      </.inputs_for>
      <input type="hidden" name={"#{@field.form.name}[#{@field.field}_drop][]"} />
      <div>
        <.button
          size="sm"
          type="button"
          name={"#{@field.form.name}[#{@field.field}_sort][]"}
          value="new"
          phx-click={JS.dispatch("change")}
        >
          <.lucide name="file-plus" /> {gettext("Add file")}
        </.button>
      </div>
    </div>
    """
  end

  @doc "An image's name, marked when it isn't on the Docker daemon yet."
  attr :image, :string, required: true
  attr :present, :any, default: nil, doc: "true, false, an error, or nil before asking Docker; only false is marked"

  def image_status(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: both spans are scope roots, so the rules are tag-qualified. --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      span:scope {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        white-space: nowrap;
      }

      span.container-image--missing:scope {
        color: var(--muted-foreground);
      }

      span.container-image--missing:scope .iconex {
        color: var(--warning);
      }
    </style>
    <span
      :if={@present == false}
      class="container-image container-image--missing"
      title={gettext("Not on the Docker daemon yet; pulled when a download first needs it")}
    >
      <.lucide name="cloud-download" />{@image}
    </span>
    <span :if={@present != false} class="container-image">{@image}</span>
    """
  end
end

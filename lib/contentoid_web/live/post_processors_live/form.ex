defmodule ContentoidWeb.PostProcessorsLive.Form do
  @moduledoc """
  Creates or edits a post-processor (`Contentoid.PostProcessors.PostProcessor`): its name, priority,
  when it runs, the image and script, mounts, named volumes and files.
  """
  use ContentoidWeb, :live_view

  alias Contentoid.PostProcessors
  alias Contentoid.PostProcessors.PostProcessor
  alias ContentoidWeb.ContainerComponents

  @starter_script ~S"""
  # "$@" are the arguments it's assigned with (on a downloader's or schedule's form). The download's
  # files (paths in this container) are one per line in $CONTENTOID_FILES; $CONTENTOID_OUTPUT is its
  # output directory.
  # Report changes with one JSON object per line (anything else goes to the log), and exit 0 on
  # success. json quotes a value for them:
  json() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')"; }
  #   printf '{"contentoid": "moved", "from": %s, "to": %s}\n' "$(json "$old")" "$(json "$new")"
  #   printf '{"contentoid": "removed", "path": %s}\n' "$(json "$deleted")"
  #   printf '{"contentoid": "file", "path": %s}\n' "$(json "$created")"
  #   printf '{"contentoid": "error", "message": %s}\n' "$(json "what went wrong")"
  printf '%s\n' "$CONTENTOID_FILES" | while IFS= read -r file; do
    [ -n "$file" ] || continue
    :
  done
  """

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    post_processor = %PostProcessor{script: @starter_script}

    socket
    |> assign(page_title: gettext("New post-processor"), post_processor: post_processor)
    |> assign_form(PostProcessors.change_post_processor(post_processor))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    post_processor = PostProcessors.get_post_processor!(id)

    socket
    |> assign(page_title: gettext("Edit %{name}", name: post_processor.name), post_processor: post_processor)
    |> assign_form(PostProcessors.change_post_processor(post_processor))
  end

  @impl true
  def handle_event("validate", %{"post_processor" => params}, socket) do
    changeset = PostProcessors.change_post_processor(socket.assigns.post_processor, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"post_processor" => params}, socket) do
    result =
      case socket.assigns.live_action do
        :new -> PostProcessors.create_post_processor(params)
        :edit -> PostProcessors.update_post_processor(socket.assigns.post_processor, params)
      end

    case result do
      {:ok, post_processor} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved %{name}.", name: post_processor.name))
         |> push_navigate(to: ~p"/post-processors")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset))

  @impl true
  def render(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: the rules reach into `<.input>` and `<.inputs_for>` content, whose roots
      carry `phx-r`. Everything sits inside `#post-processor-page`, a scope root.
    --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      section:scope {
        max-inline-size: 64rem;
      }

      .post-processor-form {
        display: grid;
        gap: var(--size-5);
      }

      .post-processor-form fieldset {
        display: grid;
        gap: var(--size-3);
        margin: 0;
        padding: var(--size-3);
        border: 1px solid var(--border);
      }

      .post-processor-form legend {
        padding: 0 var(--size-1);
        font-weight: 700;
      }

      .post-processor-form label {
        display: grid;
        gap: var(--size-1);
      }

      .post-processor-form label > span {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .post-processor-form .post-processor-check label > span {
        display: flex;
        align-items: center;
        font-size: inherit;
        color: inherit;
      }

      .post-processor-row {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        align-items: end;
        gap: var(--size-3);
      }

      .post-processor-script textarea {
        min-block-size: 22rem;
        font-size: var(--font-size-0);
        white-space: pre;
        tab-size: 2;
      }

      .post-processor-actions {
        display: flex;
        gap: var(--size-2);
      }

      @media (--phone) {
        .post-processor-row {
          grid-template-columns: minmax(0, 1fr);
        }
      }
    </style>
    <Layouts.app flash={@flash} active={:post_processors}>
      <section id="post-processor-page">
        <.header>
          {@page_title}
          <:subtitle>
            {gettext("Runs a shell script in a Docker image on a download's files once it succeeds.")}
          </:subtitle>
        </.header>

        <.form
          for={@form}
          id="post-processor-form"
          class="post-processor-form"
          phx-change="validate"
          phx-submit="save"
        >
          <fieldset>
            <legend>{gettext("Post-processor")}</legend>
            <.input field={@form[:name]} label={gettext("Name")} autocomplete="off" required />
            <div class="post-processor-row">
              <.input
                field={@form[:priority]}
                type="number"
                label={gettext("Priority (higher runs first)")}
              />
              <.input
                field={@form[:trigger]}
                type="select"
                label={gettext("Runs")}
                options={[
                  {gettext("When the download has files"), :new_files},
                  {gettext("After every successful download"), :always}
                ]}
              />
              <div class="post-processor-check">
                <.input field={@form[:enabled]} type="checkbox" label={gettext("Enabled")} />
              </div>
            </div>
          </fieldset>

          <fieldset>
            <legend>{gettext("Container")}</legend>
            <.input
              field={@form[:image]}
              label={gettext("Docker image")}
              autocomplete="off"
              placeholder="ghcr.io/owner/image:tag"
              required
            />
            <div class="post-processor-script">
              <.input
                field={@form[:script]}
                type="textarea"
                label={gettext("Script (/bin/sh -c)")}
                spellcheck="false"
                required
              />
            </div>
            <.help>
              {gettext(
                "It's given arguments where it's assigned, on a downloader's or schedule's form: they're"
              )}
              <code>"$@"</code>
              ({gettext("and")} <code>$CONTENTOID_ARGUMENTS</code>
              {gettext("as written).")} {gettext(
                "The download's files (paths in this container) are one per line in"
              )} <code>$CONTENTOID_FILES</code>. {gettext("Its output directory is")}
              <code>$CONTENTOID_OUTPUT</code>
              (<code>/contentoid/output</code>); {gettext(
                "add a mount to move files elsewhere on the host."
              )}
              <code>$CONTENTOID_MOUNTS</code>
              {gettext(
                "maps host paths to this container's, a line each (host, tab, container path), for arguments given as host paths."
              )}
              {gettext("Report with one JSON object per line, named by its")}
              <code>"contentoid"</code>
              {gettext("key:")} <code>moved</code>
              (<code>from</code>, <code>to</code>), <code>removed</code>
              {gettext("and")} <code>file</code>
              (<code>path</code>, {gettext("a new file")}), <code>progress</code>
              {gettext("and")} <code>error</code>
              (<code>message</code>).
            </.help>
          </fieldset>

          <fieldset id="post-processor-mounts">
            <legend>{gettext("Mounts")}</legend>
            <.help>
              {gettext(
                "Host paths bound into the container, such as a library to move files into. They must exist."
              )}
              {gettext("Not under")} <code>/contentoid</code>.
            </.help>
            <ContainerComponents.binds field={@form[:mounts]} />
          </fieldset>

          <fieldset id="post-processor-volumes">
            <legend>{gettext("Named volumes")}</legend>
            <.help>
              {gettext("Docker volumes kept between runs, such as caches. Created on first use.")}
              {gettext("Not under")} <code>/contentoid</code>.
            </.help>
            <ContainerComponents.binds field={@form[:volumes]} kind={:volume} />
          </fieldset>

          <fieldset id="post-processor-files">
            <legend>{gettext("Files")}</legend>
            <.help>
              {gettext(
                "Kept in Contentoid and put into the container before the script starts, read-only: a tool's config. Missing directories are created. Not inside a mount, and not under"
              )} <code>/contentoid</code>.
            </.help>
            <ContainerComponents.files field={@form[:files]} directory_placeholder="/config" />
          </fieldset>

          <div class="post-processor-actions">
            <.button variant="primary" type="submit" phx-disable-with={gettext("Saving…")}>
              {gettext("Save")}
            </.button>
            <.button navigate={~p"/post-processors"}>{gettext("Cancel")}</.button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end

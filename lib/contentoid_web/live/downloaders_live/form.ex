defmodule ContentoidWeb.DownloadersLive.Form do
  @moduledoc """
  Creates or edits a downloader (`Contentoid.Downloaders.Downloader`): what it takes (a URL or a
  schedule's arguments), its pattern, priority and limit, the image and script, the output mount,
  extra mounts and named volumes, files, and the post-processors its downloads run.

  On a new downloader the slug follows the name until the user types their own. A URL typed into
  "Try a URL" is checked against the pattern as it's edited. An arguments downloader has no pattern.
  """
  use ContentoidWeb, :live_view

  alias Contentoid.Downloaders
  alias Contentoid.Downloaders.Downloader
  alias Contentoid.Downloaders.Downloader.Output
  alias Contentoid.PostProcessors
  alias ContentoidWeb.ContainerComponents
  alias ContentoidWeb.PostProcessorAssignments
  alias Phoenix.HTML.Form

  @starter_script ~S"""
  # $CONTENTOID_URL (and $1) is the URL, or "$@" a schedule's arguments; write files under $CONTENTOID_OUTPUT.
  # Report with one JSON object per line (anything else goes to the log), and exit 0 on success:
  #   {"contentoid": "progress", "percent": 42, "text": "1.2MiB/s ETA 0:31"}
  #   {"contentoid": "file", "path": "/out/name.ext", "url": "https://site/item-url"}   (url optional)
  #   {"contentoid": "error", "message": "what went wrong"}
  # Tools' templates can usually JSON-encode a field (yt-dlp %(field)j, gallery-dl {field!j}); from
  # the shell, quote values with json:
  json() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')"; }
  #   printf '{"contentoid": "file", "path": %s}\n' "$(json "$CONTENTOID_OUTPUT/name.ext")"
  """

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(try_url: "", post_processors: PostProcessors.list_post_processors())
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    downloader = %Downloader{output: %Output{}, script: @starter_script}

    socket
    |> assign(page_title: gettext("New downloader"), downloader: downloader, slug_edited?: false)
    |> assign_form(Downloaders.change_downloader(downloader))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    downloader = Downloaders.get_downloader!(id)

    # An existing slug stays put when the name changes.
    socket
    |> assign(page_title: gettext("Edit %{name}", name: downloader.name), downloader: downloader, slug_edited?: true)
    |> assign_form(Downloaders.change_downloader(downloader))
  end

  @impl true
  def handle_event("validate", %{"downloader" => params} = event, socket) do
    slug_edited? = socket.assigns.slug_edited? or event["_target"] == ["downloader", "slug"]
    params = if slug_edited?, do: params, else: Map.put(params, "slug", Downloader.slugify(params["name"] || ""))

    changeset = Downloaders.change_downloader(socket.assigns.downloader, params)

    {:noreply,
     socket
     |> assign(slug_edited?: slug_edited?, try_url: event["try_url"] || socket.assigns.try_url)
     |> assign_form(Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"downloader" => params}, socket) do
    result =
      case socket.assigns.live_action do
        :new -> Downloaders.create_downloader(params)
        :edit -> Downloaders.update_downloader(socket.assigns.downloader, params)
      end

    case result do
      {:ok, downloader} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved %{name}.", name: downloader.name))
         |> push_navigate(to: ~p"/downloaders")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset))

  # Whether the pattern being edited matches the URL under "Try a URL".
  defp try_result(_form, ""), do: nil

  defp try_result(form, url) do
    case Regex.compile(Form.input_value(form, :url_pattern) || "") do
      {:ok, regex} -> if Regex.match?(regex, url), do: :match, else: :no_match
      {:error, _reason} -> :invalid
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, try_result: try_result(assigns.form, assigns.try_url))

    ~H"""
    <%!--
      `lower-bound="none"`: the rules reach into `<.input>` and `<.inputs_for>` content, whose roots
      carry `phx-r`. Everything sits inside `#downloader-page`, a scope root.
    --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      section:scope {
        max-inline-size: 64rem;
      }

      .downloader-form {
        display: grid;
        gap: var(--size-5);
      }

      .downloader-form fieldset {
        display: grid;
        gap: var(--size-3);
        margin: 0;
        padding: var(--size-3);
        border: 1px solid var(--border);
      }

      .downloader-form legend {
        padding: 0 var(--size-1);
        font-weight: 700;
      }

      .downloader-form label {
        display: grid;
        gap: var(--size-1);
      }

      .downloader-form label > span {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .downloader-form .downloader-check label > span {
        display: flex;
        align-items: center;
        font-size: inherit;
        color: inherit;
      }

      .downloader-row {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: var(--size-3);
      }

      .downloader-row--numbers {
        grid-template-columns: repeat(3, minmax(0, 1fr));
        align-items: end;
      }

      .downloader-script textarea {
        min-block-size: 22rem;
        font-size: var(--font-size-0);
        white-space: pre;
        tab-size: 2;
      }

      .downloader-try {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        align-items: end;
        gap: var(--size-3);
      }

      .downloader-try-result {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        padding-block-end: var(--size-2);
        white-space: nowrap;
      }

      .downloader-try-result--match .iconex {
        color: var(--success);
      }

      .downloader-try-result--no_match .iconex,
      .downloader-try-result--invalid .iconex {
        color: var(--destructive);
      }

      .downloader-actions {
        display: flex;
        gap: var(--size-2);
      }

      @media (--phone) {
        .downloader-row,
        .downloader-row--numbers {
          grid-template-columns: minmax(0, 1fr);
        }
      }
    </style>
    <Layouts.app flash={@flash} active={:downloaders}>
      <section id="downloader-page">
        <.header>
          {@page_title}
          <:subtitle>
            {gettext(
              "Runs a shell script in a Docker image for every URL its pattern matches, or for a schedule's arguments."
            )}
          </:subtitle>
        </.header>

        <.form
          for={@form}
          id="downloader-form"
          class="downloader-form"
          phx-change="validate"
          phx-submit="save"
        >
          <fieldset>
            <legend>{gettext("Downloader")}</legend>
            <div class="downloader-row">
              <.input field={@form[:name]} label={gettext("Name")} autocomplete="off" required />
              <.input field={@form[:slug]} label={gettext("Slug")} autocomplete="off" />
            </div>
            <div class="downloader-row--numbers downloader-row">
              <.input
                field={@form[:priority]}
                type="number"
                label={gettext("Priority (higher wins)")}
              />
              <.input
                field={@form[:concurrency]}
                type="number"
                label={gettext("Downloads at once")}
                min="1"
                max="32"
              />
              <div class="downloader-check">
                <.input field={@form[:enabled]} type="checkbox" label={gettext("Enabled")} />
              </div>
            </div>
          </fieldset>

          <fieldset>
            <legend>{gettext("Input")}</legend>
            <.input
              field={@form[:input]}
              type="select"
              label={gettext("Takes")}
              options={[
                {gettext("A URL its pattern matches"), :url},
                {gettext("Arguments, from a schedule"), :arguments}
              ]}
            />
            <%= if to_string(@form[:input].value) == "arguments" do %>
              <.help id="arguments-help">
                {gettext(
                  "It finds its content itself. Only a schedule starts it, with the schedule's arguments (if any), never the download form."
                )}
              </.help>
            <% else %>
              <.input
                field={@form[:url_pattern]}
                label={gettext("URL pattern (regex; (?i) for any case)")}
                autocomplete="off"
                required
              />
              <div class="downloader-try">
                <.input
                  name="try_url"
                  value={@try_url}
                  label={gettext("Try a URL")}
                  type="url"
                  autocomplete="off"
                  phx-debounce="200"
                />
                <span
                  :if={@try_result}
                  id="try-result"
                  class={["downloader-try-result", "downloader-try-result--#{@try_result}"]}
                >
                  <.lucide :if={@try_result == :match} name="check" />
                  <.lucide :if={@try_result != :match} name="x" />
                  {try_label(@try_result)}
                </span>
              </div>
            <% end %>
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
            <div class="downloader-script">
              <.input
                field={@form[:script]}
                type="textarea"
                label={gettext("Script (/bin/sh -c)")}
                spellcheck="false"
                required
              />
            </div>
            <.help>
              {gettext("The URL is")} <code>$CONTENTOID_URL</code>
              ({gettext("and")} <code>$1</code>); {gettext("a schedule's arguments are")}
              <code>"$@"</code>, {gettext("split as a shell would")} ({gettext("and")}
              <code>$CONTENTOID_ARGUMENTS</code>
              {gettext("as written).")} {gettext("The output mount's path is")}
              <code>$CONTENTOID_OUTPUT</code>. {gettext(
                "Report with one JSON object per line, named by its"
              )} <code>"contentoid"</code>
              {gettext("key:")} <code>progress</code>
              (<code>percent</code>, <code>text</code>), <code>total</code>
              (<code>done</code>, <code>of</code>), <code>start</code>
              {gettext("and")} <code>file</code>
              (<code>path</code>, {gettext("optional")} <code>url</code>), <code>error</code>
              (<code>message</code>).
            </.help>
          </fieldset>

          <fieldset>
            <legend>{gettext("Output")}</legend>
            <.inputs_for :let={output} field={@form[:output]}>
              <div class="downloader-row">
                <.input
                  field={output[:source]}
                  label={
                    gettext("Host directory (relative to the download directory, ~ or absolute)")
                  }
                  autocomplete="off"
                  required
                />
                <.input
                  field={output[:target]}
                  label={gettext("Path in the container")}
                  autocomplete="off"
                  required
                />
              </div>
            </.inputs_for>
          </fieldset>

          <fieldset id="downloader-mounts">
            <legend>{gettext("Mounts")}</legend>
            <.help>
              {gettext(
                "Host paths bound into the container, such as a tool's config directory. They must exist."
              )}
            </.help>
            <ContainerComponents.binds field={@form[:mounts]} />
          </fieldset>

          <fieldset id="downloader-volumes">
            <legend>{gettext("Named volumes")}</legend>
            <.help>
              {gettext("Docker volumes kept between downloads, such as caches. Created on first use.")}
            </.help>
            <ContainerComponents.binds field={@form[:volumes]} kind={:volume} />
          </fieldset>

          <fieldset id="downloader-files">
            <legend>{gettext("Files")}</legend>
            <.help>
              {gettext(
                "Kept in Contentoid and put into the container before the script starts, read-only: a tool's config, a cookies file. Missing directories are created. Not inside a mount."
              )}
            </.help>
            <ContainerComponents.files field={@form[:files]} directory_placeholder="/config/yt-dlp" />
          </fieldset>

          <PostProcessorAssignments.list form={@form} post_processors={@post_processors} />

          <div class="downloader-actions">
            <.button variant="primary" type="submit" phx-disable-with={gettext("Saving…")}>
              {gettext("Save")}
            </.button>
            <.button navigate={~p"/downloaders"}>{gettext("Cancel")}</.button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  defp try_label(:match), do: gettext("Matches")
  defp try_label(:no_match), do: gettext("Doesn't match")
  defp try_label(:invalid), do: gettext("Pattern doesn't compile")
end

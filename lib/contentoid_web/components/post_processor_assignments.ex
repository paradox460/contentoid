defmodule ContentoidWeb.PostProcessorAssignments do
  @moduledoc """
  The "Post-processing" fieldset of the downloader and schedule forms: the owner's post-processor
  assignments (`Contentoid.PostProcessors.Assignment`), a row each of a post-processor and the
  arguments its script gets, added and removed in place. Sent as `FORM[post_processor_assignments]`
  with `_sort`/`_drop` (`Phoenix.Component.inputs_for/1`), cast by the owner's changeset. A
  post-processor can be listed more than once, with different arguments.
  """
  use ContentoidWeb, :html

  alias ContentoidWeb.ContainerComponents
  alias Phoenix.HTML.Form

  attr :form, Form, required: true, doc: "the owner's form, its data with post_processor_assignments preloaded"
  attr :post_processors, :list, required: true

  def list(assigns) do
    assigns = assign(assigns, options: Enum.map(assigns.post_processors, &option/1))

    ~H"""
    <%!-- `lower-bound="none"`: the rows' rules reach into `<.input>` and `<.inputs_for>`. --%>
    <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
      fieldset:scope {
        display: grid;
        gap: var(--size-3);
        margin: 0;
        padding: var(--size-3);
        border: 1px solid var(--border);
      }

      legend {
        padding: 0 var(--size-1);
        font-weight: 700;
      }

      /* One assignment: its post-processor row, then its own mounts. */
      .pp-assignment {
        display: grid;
        gap: var(--size-2);
        padding-block-end: var(--size-3);
        border-block-end: 1px solid var(--border);
      }

      /* A post-processor, its arguments, its priority, remove. */
      .pp-assignment-row {
        display: grid;
        grid-template-columns: minmax(0, 18rem) minmax(0, 1fr) 9rem auto;
        align-items: end;
        gap: var(--size-3);
      }

      /* Its own mounts, indented under its post-processor. */
      .pp-mounts {
        margin-inline-start: var(--size-5);
      }

      @media (--phone) {
        .pp-assignment-row {
          grid-template-columns: minmax(0, 1fr);
        }

        .pp-mounts {
          margin-inline-start: 0;
        }
      }
    </style>
    <fieldset id={"#{@form.name}-post-processors"}>
      <legend>{gettext("Post-processing")}</legend>
      <.help>
        {gettext(
          "Run after each successful download, highest priority first, together with those of the schedule or downloader it came from. A priority here replaces the post-processor's own for these runs; blank keeps it."
        )}
        {rich(
          gettext("A post-processor's script gets its arguments as %{args}, split as a shell would.",
            args: code(~s("$@"))
          )
        )}
        {rich(
          gettext(
            "Mounts added here are bound for these runs on top of the post-processor's own (host paths that exist, not under %{reserved}).",
            reserved: code("/contentoid")
          )
        )}
        {gettext("List one more than once to run it with different arguments or mounts.")}
      </.help>
      <.inputs_for :let={assignment} field={@form[:post_processor_assignments]}>
        <div class="pp-assignment">
          <div class="pp-assignment-row">
            <input
              type="hidden"
              name={"#{@form.name}[post_processor_assignments_sort][]"}
              value={assignment.index}
            />
            <.input
              field={assignment[:post_processor_id]}
              type="select"
              label={gettext("Post-processor")}
              options={@options}
              prompt={gettext("Pick one")}
            />
            <.input
              field={assignment[:arguments]}
              label={gettext("Arguments")}
              placeholder={pgettext("arguments", "none")}
              autocomplete="off"
              spellcheck="false"
            />
            <.input
              field={assignment[:priority]}
              type="number"
              label={gettext("Priority")}
              placeholder={pgettext("priority, when blank: the post-processor's", "its own")}
            />
            <.button
              icon
              type="button"
              name={"#{@form.name}[post_processor_assignments_drop][]"}
              value={assignment.index}
              phx-click={JS.dispatch("change")}
              aria-label={gettext("Remove post-processor")}
            >
              <.lucide name="x" />
            </.button>
          </div>
          <div class="pp-mounts">
            <ContainerComponents.binds field={assignment[:mounts]} />
          </div>
        </div>
      </.inputs_for>
      <input type="hidden" name={"#{@form.name}[post_processor_assignments_drop][]"} />
      <.help :if={@post_processors == []}>
        {gettext("No post-processors yet.")}
        <.link navigate={~p"/post-processors/new"}>{gettext("Add one")}</.link>.
      </.help>
      <div :if={@post_processors != []}>
        <.button
          size="sm"
          type="button"
          name={"#{@form.name}[post_processor_assignments_sort][]"}
          value="new"
          phx-click={JS.dispatch("change")}
        >
          <.lucide name="plus" /> {gettext("Add post-processor")}
        </.button>
      </div>
    </fieldset>
    """
  end

  defp option(post_processor) do
    label =
      if post_processor.enabled,
        do:
          gettext("%{name} (priority %{priority})",
            name: post_processor.name,
            priority: number(post_processor.priority)
          ),
        else:
          gettext("%{name} (priority %{priority}, disabled)",
            name: post_processor.name,
            priority: number(post_processor.priority)
          )

    {label, post_processor.id}
  end
end

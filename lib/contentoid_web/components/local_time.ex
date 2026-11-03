defmodule ContentoidWeb.LocalTime do
  @moduledoc """
  A timestamp in the reader's own time zone and locale: `local_time/1` renders a `<time>` carrying
  the UTC ISO-8601 value, and the `.LocalTime` hook rewrites its text with `Intl.DateTimeFormat` on
  mount and on every patch, in the page's locale (`<html lang>`, `ContentoidWeb.Locale`) so dates
  match the server-formatted numbers. The full date, time and zone name go in the `title` tooltip.

  The server text is a fallback in `time_zone` (UTC when nil), formatted by Localize. It is what
  LiveViewTest sees, and it stays hidden (its width kept, so nothing shifts) until the hook has
  run. The hook reads the `datetime` attribute, never the text.
  """
  use Phoenix.Component

  attr :id, :string, required: true, doc: "unique per element; `phx-hook` requires it"
  attr :at, DateTime, required: true

  attr :format, :atom,
    values: [:datetime, :weekday],
    default: :datetime,
    doc: "`:datetime` date, time and zone; `:weekday` adds the day of the week"

  attr :time_zone, :string,
    default: nil,
    doc: "an IANA zone to show the time in instead of the browser's"

  attr :rest, :global

  def local_time(assigns) do
    ~H"""
    <style :type={ContentoidWeb.ColocatedScopedCSS}>
      time:scope:not([data-localized]) {
        visibility: hidden;
      }
    </style>

    <time
      id={@id}
      phx-hook=".LocalTime"
      datetime={DateTime.to_iso8601(@at)}
      data-format={@format}
      data-time-zone={@time_zone}
      {@rest}
    >
      {fallback(@at, @format, @time_zone)}
    </time>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      const DATETIME = {
        year: "numeric",
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
        timeZoneName: "short",
      };

      const OPTIONS = {
        datetime: DATETIME,
        weekday: { ...DATETIME, weekday: "short" },
      };

      export default {
        mounted() {
          this.updated();
        },
        // A patch resets the text to the server fallback and drops `data-localized`; this runs
        // before paint and restores both.
        updated() {
          const at = new Date(this.el.dateTime);
          // Leave the server fallback visible rather than an "Invalid Date".
          if (Number.isNaN(at.getTime())) {
            this.el.dataset.localized = "";
            return;
          }
          const locale = document.documentElement.lang || undefined;
          const zone = this.el.dataset.timeZone
            ? { timeZone: this.el.dataset.timeZone }
            : {};
          const options = OPTIONS[this.el.dataset.format] ?? OPTIONS.datetime;
          this.el.textContent = new Intl.DateTimeFormat(locale, {
            ...options,
            ...zone,
          }).format(at);
          this.el.title = new Intl.DateTimeFormat(locale, {
            dateStyle: "full",
            timeStyle: "long",
            ...zone,
          }).format(at);
          this.el.dataset.localized = "";
        },
      };
    </script>
    """
  end

  defp fallback(at, format, time_zone) do
    at
    |> DateTime.shift_zone!(time_zone || "Etc/UTC")
    |> Localize.DateTime.to_string!(format: skeleton(format), locale: Localize.get_locale())
  end

  defp skeleton(:datetime), do: :yMMMdjmz
  defp skeleton(:weekday), do: :yMMMEdjmz
end

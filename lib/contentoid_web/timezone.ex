defmodule ContentoidWeb.Timezone do
  @moduledoc """
  The viewer's time zone, for `datetime-local` inputs (`to_local/2`, `parse_local/2`) and a new
  schedule's default zone. Timestamps shown on the page are localized in the browser instead
  (`ContentoidWeb.LocalTime`).

  Every LiveView gets `@timezone` (`on_mount/4`, attached in `ContentoidWeb.live_view/0`): the
  browser's IANA zone, sent as the `timezone` connect param (`assets/js/app.ts`), or `Etc/UTC`
  before the socket connects or when the browser sends nothing usable.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Contentoid.Schedules.Cron

  @fallback "Etc/UTC"

  def on_mount(:default, _params, _session, socket) do
    timezone =
      with true <- Phoenix.LiveView.connected?(socket),
           %{"timezone" => timezone} when is_binary(timezone) <- Phoenix.LiveView.get_connect_params(socket),
           true <- Cron.valid_timezone?(timezone) do
        timezone
      else
        _unknown -> @fallback
      end

    {:cont, assign(socket, :timezone, timezone)}
  end

  @doc "`at` as a `datetime-local` value in `timezone`: `2026-11-05T03:00`."
  @spec to_local(DateTime.t(), String.t()) :: String.t()
  def to_local(%DateTime{} = at, timezone),
    do: at |> DateTime.shift_zone!(timezone) |> Calendar.strftime("%Y-%m-%dT%H:%M")

  @doc """
  The instant a `datetime-local` value (`2026-11-05T03:00`) means in `timezone`. A wall-clock time
  skipped by daylight saving means the end of the gap; one that happens twice, its first pass.
  """
  @spec parse_local(String.t(), String.t()) :: {:ok, DateTime.t()} | :error
  def parse_local(value, timezone) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(pad_seconds(value)),
         at when not is_atom(at) <- from_naive(naive, timezone) do
      {:ok, at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)}
    else
      _invalid -> :error
    end
  end

  # `datetime-local` inputs leave out the seconds.
  defp pad_seconds(value), do: if(String.length(value) == 16, do: value <> ":00", else: value)

  defp from_naive(naive, timezone) do
    case DateTime.from_naive(naive, timezone) do
      {:ok, at} -> at
      {:gap, _before, just_after} -> just_after
      {:ambiguous, first, _second} -> first
      {:error, _reason} -> :error
    end
  end
end

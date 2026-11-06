defmodule ContentoidWeb.Format do
  @moduledoc """
  Numbers, durations and status words as the viewer reads them: CLDR formats in the current
  Localize locale (`ContentoidWeb.Locale`), status names through Gettext. Every call passes the
  locale explicitly; some Localize formatters default to `:en` rather than the process locale.
  """
  use Gettext, backend: ContentoidWeb.Gettext

  @doc "`1234` → `\"1,234\"` in en."
  @spec number(number()) :: String.t()
  def number(n), do: Localize.Number.to_string!(n, locale: Localize.get_locale())

  @doc "A fraction as a percentage: `0.42` → `\"42%\"` in en."
  @spec percent(number()) :: String.t()
  def percent(fraction), do: Localize.Number.to_string!(fraction, format: :percent, locale: Localize.get_locale())

  @doc "`1800` → `\"30 minutes\"` in en."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(seconds),
    do: seconds |> Localize.Duration.new_from_seconds() |> Localize.Duration.to_string!(locale: Localize.get_locale())

  # Statuses carry a context: a language may inflect a download's and a run's differently.
  @doc "A `Contentoid.Downloads.Download` status, for display."
  @spec download_status(atom()) :: String.t()
  def download_status(:queued), do: pgettext("download status", "Queued")
  def download_status(:running), do: pgettext("download status", "Running")
  def download_status(:completed), do: pgettext("download status", "Completed")
  def download_status(:failed), do: pgettext("download status", "Failed")
  def download_status(:cancelled), do: pgettext("download status", "Cancelled")

  @doc "A `Contentoid.Downloads.Download.Step` status, for display."
  @spec step_status(atom()) :: String.t()
  def step_status(:pending), do: pgettext("post-processor run status", "Waiting")
  def step_status(:running), do: pgettext("post-processor run status", "Running")
  def step_status(:succeeded), do: pgettext("post-processor run status", "Succeeded")
  def step_status(:failed), do: pgettext("post-processor run status", "Failed")
  def step_status(:skipped), do: pgettext("post-processor run status", "Skipped")
  def step_status(:cancelled), do: pgettext("post-processor run status", "Cancelled")
end

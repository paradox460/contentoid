defmodule ContentoidWeb.Locale do
  @moduledoc """
  The viewer's locale: the best match for the browser's `Accept-Language` among Localize's supported
  (CLDR "modern") locales, else `Localize.default_locale/0` (`DEFAULT_LOCALE`, `config/runtime.exs`).

  `Localize.Plug.PutLocale` in the router's `:browser` pipeline picks it for every request and
  `Localize.Plug.PutSession` saves it, so `on_mount/4` (attached in `ContentoidWeb.live_view/0`) can
  set it in the LiveView process. Numbers and dates follow it in any CLDR locale; Gettext gets the
  closest locale it has translations for, English until others ship.
  """

  def on_mount(:default, _params, session, socket) do
    _ = Localize.Plug.put_locale_from_session(session, gettext: ContentoidWeb.Gettext)
    {:cont, socket}
  end

  @doc "The current locale as a BCP 47 tag, for `<html lang>`: `en-US`, `de-DE`."
  @spec html_lang() :: String.t()
  def html_lang, do: Localize.LanguageTag.to_string(Localize.get_locale())
end

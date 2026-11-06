defmodule ContentoidWeb.RichText do
  @moduledoc """
  Code inside a translated sentence, so a sentence stays one msgid however much code it quotes. The
  code goes in as a binding wrapped by `code/1`; `rich/1` escapes the translation and renders each
  wrapped binding as a `<code>` element:

      {rich(gettext("The URL is %{url}.", url: code("$CONTENTOID_URL")))}

  Translators see `The URL is %{url}.` and put `%{url}` wherever their grammar needs it.
  """

  # Supplementary private-use characters: never in a translation, a path or an icon font.
  @open "\u{F0000}"
  @close "\u{F0001}"

  @doc "`text` marked to render as code inside a `rich/1` sentence; pass it as a binding."
  @spec code(String.Chars.t()) :: String.t()
  def code(text), do: @open <> to_string(text) <> @close

  @doc "A translated sentence, escaped, with its `code/1` bindings as `<code>` elements."
  @spec rich(String.t()) :: Phoenix.HTML.safe()
  def rich(text) do
    parts =
      ~r/\x{F0000}[^\x{F0001}]*\x{F0001}/u
      |> Regex.split(text, include_captures: true, trim: true)
      |> Enum.map(fn
        @open <> marked -> ["<code>", escape(String.trim_trailing(marked, @close)), "</code>"]
        plain -> escape(plain)
      end)

    {:safe, parts}
  end

  defp escape(text) do
    {:safe, iodata} = Phoenix.HTML.html_escape(text)
    iodata
  end
end

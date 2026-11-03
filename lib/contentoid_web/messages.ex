defmodule ContentoidWeb.Messages do
  @moduledoc """
  Renders a stored `Contentoid.Message` in the current Gettext locale, the way
  `ContentoidWeb.CoreComponents.translate_error/1` renders changeset errors: a `count` binding
  picks the plural form. A binding that is itself a message is rendered first.
  """
  alias Contentoid.Message

  @spec message_text(Message.t() | nil) :: String.t() | nil
  def message_text(nil), do: nil
  def message_text(%Message{text: text}) when is_binary(text), do: text

  def message_text(%Message{domain: domain, msgid: msgid, bindings: bindings}) do
    bindings = Map.new(bindings, fn {key, value} -> {String.to_existing_atom(key), render_binding(value)} end)

    if count = bindings[:count] do
      Gettext.dngettext(ContentoidWeb.Gettext, domain, msgid, msgid, count, bindings)
    else
      Gettext.dgettext(ContentoidWeb.Gettext, domain, msgid, bindings)
    end
  end

  defp render_binding(%{} = value) when is_map_key(value, "msgid") or is_map_key(value, "text"),
    do: Message |> Ecto.embedded_load(value, :json) |> message_text()

  defp render_binding(value), do: value
end

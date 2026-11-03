defmodule Contentoid.Message do
  @moduledoc """
  A message Contentoid stores to show later (`downloads.error`, `schedules.last_error`), translated
  when shown, in the viewer's locale (`ContentoidWeb.Messages.message_text/1`), not when written.

  Either a Gettext `msgid` in `domain` with its `bindings`, or `text`: verbatim text from outside
  Contentoid (a tool, Docker, the OS) that has no msgid. Exactly one of the two is set. Mark msgids
  with `gettext_noop/1` (or `dgettext_noop/2`) so `mix gettext.extract` finds them:

      Message.new(gettext_noop("exited with status %{status}"), status: 3)

  Bindings are kept as a string-keyed map of strings, numbers and nested messages, the shape they
  load back from JSON in, so a message equals itself after a database round trip.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{
          domain: String.t(),
          msgid: String.t() | nil,
          bindings: %{optional(String.t()) => String.t() | number() | map()},
          text: String.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :domain, :string, default: "default"
    field :msgid, :string
    field :bindings, :map, default: %{}
    field :text, :string
  end

  @doc "A message in the default Gettext domain."
  @spec new(String.t(), keyword() | map()) :: t()
  def new(msgid, bindings \\ []), do: %__MODULE__{msgid: msgid, bindings: normalize(bindings)}

  @doc "A message in the `errors` domain, where changeset messages live."
  @spec error(String.t(), keyword() | map()) :: t()
  def error(msgid, bindings \\ []), do: %__MODULE__{domain: "errors", msgid: msgid, bindings: normalize(bindings)}

  @doc "Verbatim text that isn't Contentoid's own and isn't translated."
  @spec text(String.t()) :: t()
  def text(string) when is_binary(string), do: %__MODULE__{text: string}

  defp normalize(bindings) do
    for {key, value} <- bindings, value = normalize_value(value), value != :drop, into: %{} do
      {to_string(key), value}
    end
  end

  defp normalize_value(%__MODULE__{} = message),
    do: %{"domain" => message.domain, "msgid" => message.msgid, "bindings" => message.bindings, "text" => message.text}

  defp normalize_value(value) when is_binary(value) or is_number(value), do: value
  defp normalize_value(value) when is_boolean(value) or is_nil(value), do: :drop
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(_other), do: :drop
end

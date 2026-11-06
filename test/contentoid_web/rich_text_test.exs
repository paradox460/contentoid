defmodule ContentoidWeb.RichTextTest do
  use ExUnit.Case, async: true

  import ContentoidWeb.RichText

  defp html(text), do: text |> rich() |> Phoenix.HTML.safe_to_string()

  test "renders marked bindings as code wherever the sentence puts them, the rest as text" do
    assert html("La URL es #{code("$URL")} (y #{code("$1")}).") ==
             "La URL es <code>$URL</code> (y <code>$1</code>)."

    assert html("#{code("$MOUNTS")} maps host paths") == "<code>$MOUNTS</code> maps host paths"
    assert html("no code here") == "no code here"
  end

  test "escapes the sentence and the code" do
    assert html(~s(a <b> & #{code(~s("<path> & 'x'"))})) ==
             "a &lt;b&gt; &amp; <code>&quot;&lt;path&gt; &amp; &#39;x&#39;&quot;</code>"
  end
end

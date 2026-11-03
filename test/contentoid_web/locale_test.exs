defmodule ContentoidWeb.LocaleTest do
  use ContentoidWeb.ConnCase, async: true

  defp html_lang(conn) do
    conn |> html_response(200) |> LazyHTML.from_document() |> LazyHTML.query("html") |> LazyHTML.attribute("lang")
  end

  test "the page is in the browser's language", %{conn: conn} do
    conn = conn |> put_req_header("accept-language", "de-DE,de;q=0.9") |> get(~p"/downloads")
    assert ["de" <> _region] = html_lang(conn)
  end

  test "without Accept-Language the page is in the default locale", %{conn: conn} do
    assert ["en" <> _region] = conn |> get(~p"/downloads") |> html_lang()
  end
end

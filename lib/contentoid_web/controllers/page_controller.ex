defmodule ContentoidWeb.PageController do
  use ContentoidWeb, :controller

  @doc "The app opens on the downloads page."
  def home(conn, _params), do: redirect(conn, to: ~p"/downloads")
end

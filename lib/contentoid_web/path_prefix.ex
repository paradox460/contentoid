defmodule ContentoidWeb.PathPrefix do
  @moduledoc """
  Serves Contentoid below the endpoint's URL path (`PHX_PATH`, `config/runtime.exs`), behind a
  reverse proxy that either strips that prefix (Caddy's `handle_path`) or passes it on (Caddy's
  `reverse_proxy /contentoid/*`).

  `Phoenix.Endpoint` sets `conn.script_name` from the URL path, so generated URLs (`~p`, static
  paths) carry the prefix. `normalize/1` makes the request agree: `path_info`, which the socket
  dispatch, `Plug.Static` and the router match, holds the path below the prefix, and
  `request_path` the whole path the browser asked for, so redirects (`Plug.SSL`) keep it.

  It runs from `ContentoidWeb.Endpoint.call/2`, ahead of the endpoint's socket dispatch, which
  precedes every plug.
  """

  @doc "Strips the script name from `path_info` when the proxy kept it, and adds it to `request_path` when the proxy stripped it."
  def normalize(%Plug.Conn{script_name: []} = conn), do: conn

  def normalize(%Plug.Conn{script_name: prefix, path_info: path_info} = conn) do
    if :lists.prefix(prefix, path_info) do
      %{conn | path_info: Enum.drop(path_info, length(prefix))}
    else
      %{conn | request_path: "/" <> Enum.join(prefix, "/") <> conn.request_path}
    end
  end
end

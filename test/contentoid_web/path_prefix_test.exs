defmodule ContentoidWeb.PathPrefixTest do
  use ExUnit.Case, async: true

  alias ContentoidWeb.PathPrefix

  defp conn(path, script_name), do: %{Plug.Test.conn(:get, path) | script_name: script_name}

  test "a proxy that keeps the prefix: routes see the path below it" do
    conn = PathPrefix.normalize(conn("/contentoid/downloads/1", ["contentoid"]))

    assert conn.path_info == ["downloads", "1"]
    assert conn.request_path == "/contentoid/downloads/1"
  end

  test "a proxy that strips the prefix: the request path gets it back" do
    conn = PathPrefix.normalize(conn("/downloads/1", ["contentoid"]))

    assert conn.path_info == ["downloads", "1"]
    assert conn.request_path == "/contentoid/downloads/1"
  end

  test "the prefix itself is the root" do
    assert %{path_info: [], request_path: "/contentoid"} = PathPrefix.normalize(conn("/contentoid", ["contentoid"]))
    assert %{path_info: [], request_path: "/contentoid/"} = PathPrefix.normalize(conn("/", ["contentoid"]))
  end

  test "only whole segments match the prefix" do
    conn = PathPrefix.normalize(conn("/contentoid-old/downloads", ["contentoid"]))

    assert conn.path_info == ["contentoid-old", "downloads"]
    assert conn.request_path == "/contentoid/contentoid-old/downloads"
  end

  test "with no prefix nothing changes" do
    conn = conn("/downloads", [])
    assert PathPrefix.normalize(conn) == conn
  end
end

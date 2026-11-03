defmodule Contentoid.Paths do
  @moduledoc "Path containment, for host and container paths alike."

  @doc ~s{Whether `path` is `dir` or inside it: `under?("/a/b", "/a")` holds, `under?("/ab", "/a")` doesn't, and every absolute path is under "/".}
  @spec under?(String.t(), String.t()) :: boolean()
  def under?(path, dir), do: path == dir or String.starts_with?(path, String.trim_trailing(dir, "/") <> "/")
end

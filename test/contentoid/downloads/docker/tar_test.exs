defmodule Contentoid.Downloads.Docker.TarTest do
  use ExUnit.Case, async: true

  alias Contentoid.Downloads.Docker.Tar

  # Read back with erl_tar, an independent reader.
  defp read(archive) do
    {:ok, table} = :erl_tar.table({:binary, archive}, [:verbose])
    {:ok, contents} = :erl_tar.extract({:binary, archive}, [:memory])
    contents = Map.new(contents)

    for {name, type, _size, mtime, mode, uid, gid} <- table,
        do: {to_string(name), type, contents[name], mode, uid, gid, mtime}
  end

  test "regular files, root-owned, with their mode and time, and no directory entries" do
    archive = Tar.build([{"/config/yt-dlp/config", "--no-mtime\n", 0o444}, {"/a b/c.json", "{}", 0o400}], 1_700_000_000)

    assert read(archive) == [
             {"config/yt-dlp/config", :regular, "--no-mtime\n", 0o444, 0, 0, 1_700_000_000},
             {"a b/c.json", :regular, "{}", 0o400, 0, 0, 1_700_000_000}
           ]
  end

  test "contents of any size, across blocks" do
    for size <- [0, 511, 512, 513, 2000] do
      contents = :binary.copy("x", size)
      assert [{_name, :regular, ^contents, _mode, _uid, _gid, _mtime}] = read(Tar.build([{"/f", contents, 0o444}]))
    end
  end

  # ustar holds up to 255 bytes as a prefix and a name split at a slash.
  test "paths longer than 100 bytes" do
    path = "/" <> Enum.join(List.duplicate("a-directory-name-thirty-bytes", 6), "/") <> "/file.conf"
    assert [{name, :regular, "x", _mode, _uid, _gid, _mtime}] = read(Tar.build([{path, "x", 0o444}]))
    assert "/" <> name == path
  end
end

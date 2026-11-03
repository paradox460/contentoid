defmodule Contentoid.Downloads.Docker.Tar do
  @moduledoc """
  Builds the uncompressed ustar archive the Engine API extracts into a container
  (`PUT /containers/{id}/archive`). Only regular files: Docker creates missing parent directories
  (root, 0755) itself, and leaving them out keeps existing directories' modes as they are.
  """

  import Bitwise

  @block 512

  @typedoc "A file: its absolute path in the container, contents and mode (e.g. `0o444`)."
  @type entry :: {Path.t(), binary(), non_neg_integer()}

  @doc "The archive of `entries`, owned by root, with the given modification time (Unix seconds)."
  @spec build([entry()], non_neg_integer()) :: binary()
  def build(entries, mtime \\ System.os_time(:second)) do
    IO.iodata_to_binary([Enum.map(entries, &entry(&1, mtime)), :binary.copy(<<0>>, 2 * @block)])
  end

  defp entry({path, contents, mode}, mtime) do
    {prefix, name} = split(String.trim_leading(path, "/"))
    [header(prefix, name, byte_size(contents), mode, mtime), contents, padding(byte_size(contents))]
  end

  defp header(prefix, name, size, mode, mtime) do
    fields = fn checksum ->
      [
        field(name, 100),
        octal(mode, 8),
        octal(0, 8),
        octal(0, 8),
        octal(size, 12),
        octal(mtime, 12),
        checksum,
        "0",
        field("", 100),
        "ustar\0",
        "00",
        field("root", 32),
        field("root", 32),
        octal(0, 8),
        octal(0, 8),
        field(prefix, 155),
        field("", 12)
      ]
    end

    # The checksum is the sum of the header's bytes with its own field read as eight spaces.
    sum = fields.("        ") |> IO.iodata_to_binary() |> :binary.bin_to_list() |> Enum.sum()
    fields.(String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> "\0 ")
  end

  # ustar keeps names over 100 bytes as a prefix (up to 155) and a name, split at a slash.
  defp split(path) when byte_size(path) <= 100, do: {"", path}

  defp split(path) do
    parts = String.split(path, "/")

    Enum.find_value(1..(length(parts) - 1)//1, fn at ->
      {prefix, name} = Enum.split(parts, at)
      {prefix, name} = {Enum.join(prefix, "/"), Enum.join(name, "/")}
      if byte_size(prefix) <= 155 and byte_size(name) <= 100, do: {prefix, name}
    end) || raise ArgumentError, "path too long for a tar header: #{path}"
  end

  defp field(value, size), do: value <> :binary.copy(<<0>>, size - byte_size(value))

  # `size - 1` octal digits, then a NUL.
  defp octal(value, size) when value < 1 <<< (3 * (size - 1)),
    do: String.pad_leading(Integer.to_string(value, 8), size - 1, "0") <> "\0"

  defp padding(size) do
    case rem(size, @block) do
      0 -> ""
      used -> :binary.copy(<<0>>, @block - used)
    end
  end
end

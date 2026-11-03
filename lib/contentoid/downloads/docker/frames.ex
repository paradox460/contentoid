defmodule Contentoid.Downloads.Docker.Frames do
  @moduledoc """
  Splits the Engine API's multiplexed stream (container logs without a TTY) into its payloads.

  Each frame is an 8-byte header, `<<stream, 0, 0, 0, size::32-big>>`, then `size` bytes of output;
  `stream` is 1 for stdout and 2 for stderr. Both are kept, in order, like `2>&1`. A frame can be cut
  anywhere across chunks, so the unconsumed tail is handed back for the next one.
  """

  @doc "Returns the complete payloads in `buffer` and the bytes left over."
  @spec split(binary()) :: {[binary()], binary()}
  def split(buffer), do: split(buffer, [])

  defp split(<<_stream, 0, 0, 0, size::32-big, payload::binary-size(size), rest::binary>>, payloads) do
    split(rest, [payload | payloads])
  end

  defp split(rest, payloads), do: {Enum.reverse(payloads), rest}
end

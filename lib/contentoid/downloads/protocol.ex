defmodule Contentoid.Downloads.Protocol do
  @moduledoc """
  The line protocol a downloader's or post-processor's script reports with: one JSON object per
  line, on stdout or stderr, whose `"contentoid"` key names the message. Every other line, including
  JSON without that key, goes to the download's log.

      {"contentoid": "progress", "percent": 42.3, "text": "1.2 MiB/s ETA 0:31"}
      {"contentoid": "total", "done": 3, "of": 12, "text": "in this post"}
      {"contentoid": "start", "path": "/out/post/03.jpg"}
      {"contentoid": "file", "path": "/out/Video.webm", "url": "https://site/watch?v=1"}
      {"contentoid": "moved", "from": "/out/a.mkv", "to": "/library/a.mkv"}
      {"contentoid": "removed", "path": "/out/a.part"}
      {"contentoid": "error", "message": "Resource not found"}

  * `progress` - the current file. `percent` is a number, or a string such as `"42.3%"` (what tools'
    templates print); `done` and `of` instead give it as a count. Unknown when neither is given.
  * `total` - the whole download, the same way: `done` of `of` (shown as "3 of 12", then `text`), or a
    `percent`. A total says no more than a file's own progress when there's only one, so `of` below 2,
    or a `done` or `of` that isn't a number (a tool printing what it doesn't know, as `null`), is
    ignored.
  * `start` - a file starting.
  * `file` - a finished file, with the URL of what it is (a video's own page, an image's file URL)
    when the tool knows it, else recorded under the download's own URL (none for arguments). Report
    each file once.
  * `moved`, `removed` - a file moved or renamed, or deleted (post-processors).
  * `error` - what went wrong; the last one explains a failed run. When a failed run reported no
    error, its last log line explains it instead.

  Paths are in the container. `text` is optional anywhere; extra keys are ignored, so a message can
  grow fields without breaking older readers. A message Contentoid doesn't know, or one missing what
  it needs, goes to the log rather than being dropped.
  """

  @typedoc """
  What one line means: `{:progress, fraction, text}` (fraction 0.0-1.0 or nil when unknown, text
  nil when there's none), `{:total, fraction, text}` the same for the whole download,
  `{:start, path}`, `{:file, path, url}` (url nil when not given), `{:moved, from, to}`,
  `{:removed, path}`, `{:error, message}`, `:log`, or `:ignore` for a blank line or an empty total.
  """
  @type event ::
          {:progress, float() | nil, String.t() | nil}
          | {:total, float() | nil, String.t() | nil}
          | {:start, String.t()}
          | {:file, String.t(), String.t() | nil}
          | {:moved, String.t(), String.t()}
          | {:removed, String.t()}
          | {:error, String.t()}
          | :log
          | :ignore

  @spec parse_line(String.t()) :: event()
  def parse_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> :ignore
      String.starts_with?(trimmed, "{") -> message(trimmed)
      true -> :log
    end
  end

  defp message(json) do
    case JSON.decode(json) do
      {:ok, %{"contentoid" => name} = fields} when is_binary(name) -> event(name, fields)
      _not_a_message -> :log
    end
  end

  defp event("progress", fields), do: {:progress, fraction(fields), text(fields)}
  defp event("total", %{"of" => _of} = fields), do: count(fields)
  defp event("total", fields), do: {:total, fraction(fields), text(fields)}
  defp event("start", %{"path" => path}) when is_binary(path) and path != "", do: {:start, path}

  defp event("file", %{"path" => path} = fields) when is_binary(path) and path != "",
    do: {:file, path, string(fields["url"])}

  defp event("moved", %{"from" => from, "to" => to}) when is_binary(from) and is_binary(to) and from != "" and to != "",
    do: {:moved, from, to}

  defp event("removed", %{"path" => path}) when is_binary(path) and path != "", do: {:removed, path}

  defp event("error", %{"message" => message}) when is_binary(message) do
    case String.trim(message) do
      "" -> :log
      message -> {:error, message}
    end
  end

  defp event(_unknown_or_incomplete, _fields), do: :log

  # "3 of 12", then the text; nothing when there's only one, or the tool didn't know.
  defp count(%{"done" => done, "of" => of} = fields) when is_number(done) and done >= 0 and is_integer(of) and of > 1 do
    {:total, min(done / of, 1.0), Enum.join(Enum.reject(["#{done} of #{of}", text(fields)], &is_nil/1), " ")}
  end

  defp count(_unknown_or_single), do: :ignore

  defp fraction(%{"percent" => percent}) when percent != nil, do: percent |> number() |> then(&(&1 && clamp(&1 / 100)))
  defp fraction(%{"done" => done, "of" => of}) when is_number(done) and is_number(of) and of > 0, do: clamp(done / of)
  defp fraction(_unknown), do: nil

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing("%")
    |> Float.parse()
    |> case do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp number(_other), do: nil

  defp clamp(fraction), do: fraction |> max(0.0) |> min(1.0)

  # Whitespace squeezed, as templates pad their fields; none when empty.
  defp text(fields) do
    case string(fields["text"]) do
      nil -> nil
      text -> text |> String.split() |> Enum.join(" ") |> string()
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_none), do: nil
end

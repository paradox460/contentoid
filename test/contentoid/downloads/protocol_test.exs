defmodule Contentoid.Downloads.ProtocolTest do
  use ExUnit.Case, async: true

  alias Contentoid.Downloads.Protocol

  describe "progress" do
    test "reads a percentage, a number or a template's padded string, and squeezes the text" do
      # yt-dlp's `%(progress._percent_str)j`, as the default downloader prints it.
      assert {:progress, fraction, "1.47MiB/s ETA 00:00"} =
               Protocol.parse_line(~s|{"contentoid": "progress", "percent": "  1.4%", "text": " 1.47MiB/s ETA 00:00"}|)

      assert_in_delta fraction, 0.014, 1.0e-9
      assert {:progress, 0.5, nil} = Protocol.parse_line(~s|{"contentoid": "progress", "percent": 50}|)
      assert {:progress, 1.0, nil} = Protocol.parse_line(~s|{"contentoid": "progress", "percent": 140}|)
    end

    test "or a count" do
      assert {:progress, 0.25, nil} = Protocol.parse_line(~s|{"contentoid": "progress", "done": 1024, "of": 4096}|)
    end

    test "leaves the fraction unknown when it isn't given, or isn't a number" do
      # aria2c without a length, and yt-dlp's placeholder.
      assert {:progress, nil, nil} = Protocol.parse_line(~s|{"contentoid":"progress","percent":null,"text":""}|)

      assert {:progress, nil, "76KiB/s"} =
               Protocol.parse_line(~s|{"contentoid": "progress", "percent": "Unknown %", "text": "76KiB/s"}|)

      assert {:progress, nil, nil} = Protocol.parse_line(~s|{"contentoid": "progress"}|)
    end
  end

  describe "total" do
    test "a count is the fraction done, said as N of M, then the text" do
      assert Protocol.parse_line(~s|{"contentoid": "total", "done": 3, "of": 12, "text": "in this post"}|) ==
               {:total, 0.25, "3 of 12 in this post"}

      assert Protocol.parse_line(~s|{"contentoid": "total", "done": 14, "of": 12}|) == {:total, 1.0, "14 of 12"}
    end

    test "or a percentage, like progress" do
      assert Protocol.parse_line(~s|{"contentoid": "total", "percent": 40, "text": "2 of 5 videos"}|) ==
               {:total, 0.4, "2 of 5 videos"}

      assert Protocol.parse_line(~s|{"contentoid": "total", "text": "7 files so far"}|) ==
               {:total, nil, "7 files so far"}
    end

    # Nothing a file's own bar doesn't say, or what a tool prints when it doesn't know (gallery-dl
    # with `keywords-default=null`).
    test "a total of one, or one that isn't a number, says nothing" do
      for line <- [
            ~s|{"contentoid": "total", "done": 1, "of": 1, "text": "in this post"}|,
            ~s|{"contentoid": "total", "done": null, "of": null, "text": "in this post"}|,
            ~s|{"contentoid": "total", "done": 2, "of": "x"}|
          ] do
        assert Protocol.parse_line(line) == :ignore, line
      end
    end
  end

  test "files keep their path exactly, with the URL of what they are when given" do
    path = ~s|/downloads/Me at the zoo [jNQXAC9IVRw] "1".webm|

    assert Protocol.parse_line(JSON.encode!(%{contentoid: "file", path: path, url: "https://youtu.be/jNQXAC9IVRw"})) ==
             {:file, path, "https://youtu.be/jNQXAC9IVRw"}

    assert Protocol.parse_line(~s|{"contentoid":"file","path":"/out/dummy.pdf"}|) == {:file, "/out/dummy.pdf", nil}
  end

  test "starts, moves, removals and errors" do
    assert Protocol.parse_line(~s|{"contentoid": "start", "path": "/out/post/0 1.jpg"}|) ==
             {:start, "/out/post/0 1.jpg"}

    assert Protocol.parse_line(~s|{"contentoid": "moved", "from": "/a b.mp4", "to": "/c d.mp4"}|) ==
             {:moved, "/a b.mp4", "/c d.mp4"}

    assert Protocol.parse_line(~s|{"contentoid": "removed", "path": "/x.mp4"}|) == {:removed, "/x.mp4"}

    assert Protocol.parse_line(~s|{"contentoid":"error","message":"Resource not found (aria2 error 3)"}|) ==
             {:error, "Resource not found (aria2 error 3)"}
  end

  test "extra fields are ignored, so messages can grow" do
    assert {:start, "/out/a.jpg"} = Protocol.parse_line(~s|{"contentoid": "start", "path": "/out/a.jpg", "size": 1234}|)
  end

  # Nothing a script reports is dropped silently: what Contentoid can't use stays readable.
  test "anything else is a log line: plain text, other JSON, unknown or incomplete messages" do
    for line <- [
          "[youtube] jNQXAC9IVRw: Downloading webpage",
          ~s|{"level": "info", "msg": "a tool's own JSON log"}|,
          ~s|{"contentoid": "files", "path": "/x"}|,
          ~s|{"contentoid": "file"}|,
          ~s|{"contentoid": "moved", "from": "/a"}|,
          ~s|{"contentoid": "error", "message": " "}|,
          # Unfinished JSON.
          ~s|{"contentoid": "file", "path": "/x"|,
          "[contentoid:file] /downloads/old-style.webm"
        ] do
      assert Protocol.parse_line(line) == :log, line
    end

    assert :ignore = Protocol.parse_line("   ")
  end
end

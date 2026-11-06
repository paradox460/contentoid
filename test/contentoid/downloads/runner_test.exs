defmodule Contentoid.Downloads.RunnerTest do
  # Runs the real worker and runner against `Contentoid.FakeDocker`, shared with the processes the
  # runner starts (its watchdog), hence not async.
  use Contentoid.DataCase, async: false
  use Oban.Testing, repo: Contentoid.Repo

  import Contentoid.DownloadsFixtures
  import ContentoidWeb.Messages

  alias Contentoid.Downloaders
  alias Contentoid.Downloads
  alias Contentoid.Downloads.Docker
  alias Contentoid.Downloads.Download
  alias Contentoid.Downloads.Download.Step
  alias Contentoid.Downloads.Runner
  alias Contentoid.Downloads.Worker
  alias Contentoid.FakeDocker
  alias Contentoid.Message
  alias Contentoid.Schedules
  alias Contentoid.Settings

  setup do
    Req.Test.set_req_test_to_shared()
    FakeDocker.start()
    %{root: reset_download_dir()}
  end

  test "a successful run completes with its files, mapped from the output mount to the host", %{root: root} do
    downloader = downloader_fixture(%{output: %{source: "videos", target: "/out"}})
    download = download_fixture(%{downloader_id: downloader.id})

    assert :ok = perform_job(Worker, %{download_id: download.id})

    file = Path.join([root, "videos", "video.mp4"])

    assert %Download{status: :completed, files: [^file], progress: 1.0, progress_text: nil, exit_status: 0} =
             Downloads.get_download!(download.id)

    assert File.exists?(file)
  end

  test "the container runs the downloader's script in its image, with the URL, mounts and volumes", %{root: root} do
    config = Path.join(root, "config")
    File.mkdir_p!(config)

    downloader =
      downloader_fixture(%{
        image: "example/tool:2",
        script: "do-the-thing",
        output: %{source: Path.join(root, "absolute-out"), target: "/out"},
        mounts: [%{source: config, target: "/config", read_only: true}],
        volumes: [%{name: "tool-cache", target: "/cache"}]
      })

    download = download_fixture(%{downloader_id: downloader.id, url: "https://example.com/v"})
    name = Docker.container_name(download)

    assert :ok = perform_job(Worker, %{download_id: download.id})

    assert_received {:docker, :created, body}

    assert %{
             "Image" => "example/tool:2",
             "Entrypoint" => ["/bin/sh", "-c"],
             "Cmd" => ["do-the-thing", "contentoid", "https://example.com/v"],
             "HostConfig" => %{"Init" => true, "Binds" => [output, bind, "tool-cache:/cache"]}
           } = body

    assert output == "#{Path.join(root, "absolute-out")}:/out"

    assert bind == "#{config}:/config:ro"
    assert "CONTENTOID_URL=https://example.com/v" in body["Env"]
    assert "CONTENTOID_OUTPUT=/out" in body["Env"]
    assert "CONTENTOID_DOWNLOAD_ID=#{download.id}" in body["Env"]
    assert_received {:docker, :removed, ^name}
  end

  test "an arguments download passes its arguments as words, and its files have no URL" do
    downloader = downloader_fixture(%{input: :arguments, script: "do-the-thing"})
    arguments = ~S(--since "last week" a\ b)
    {:ok, download} = Downloads.create_download(%{downloader_id: downloader.id, arguments: arguments})

    assert :ok = perform_job(Worker, %{download_id: download.id})

    assert_received {:docker, :created,
                     %{"Cmd" => ["do-the-thing", "contentoid", "--since", "last week", "a b"]} = body}

    assert "CONTENTOID_ARGUMENTS=#{arguments}" in body["Env"]
    refute Enum.any?(body["Env"], &String.starts_with?(&1, "CONTENTOID_URL="))
    assert [%{url: nil}] = Downloads.list_download_items(download)
  end

  # So a post-processor can use the download's arguments (a directory, say) without splitting them.
  test "a post-processor of an arguments download gets its arguments as written and as words" do
    post_processor = post_processor_fixture()

    downloader =
      downloader_fixture(%{input: :arguments, post_processor_assignments: assignments([post_processor])})

    arguments = ~S("/mnt/a b/c" --x)
    {:ok, download} = Downloads.create_download(%{downloader_id: downloader.id, arguments: arguments})

    assert :ok = perform_job(Worker, %{download_id: download.id})

    assert [_downloaded, %{"Env" => env}] = created_bodies()
    assert "CONTENTOID_DOWNLOAD_ARGUMENTS=#{arguments}" in env
    assert "CONTENTOID_DOWNLOAD_ARGV=/mnt/a b/c\n--x" in env
    refute Enum.any?(env, &String.starts_with?(&1, "CONTENTOID_URL="))
  end

  describe "files" do
    test "are put into the container, root-owned and read-only, before it starts" do
      downloader =
        downloader_fixture(%{
          files: [
            %{name: "config", directory: "/config/yt-dlp", contents: "--no-mtime\r\n--embed-metadata\n"},
            %{name: "cookies.txt", directory: "/secrets", contents: ""}
          ]
        })

      download = download_fixture(%{downloader_id: downloader.id})
      name = Docker.container_name(download)

      assert :ok = perform_job(Worker, %{download_id: download.id})

      # In the order they reached the daemon: the script must find its files from its first line.
      {:messages, messages} = Process.info(self(), :messages)

      assert [{:archive, files}, :started] =
               for(message <- messages, do: container_event(message, name)) |> Enum.reject(&is_nil/1)

      assert files == [
               {"/config/yt-dlp/config", "--no-mtime\n--embed-metadata\n", 0o444, 0},
               {"/secrets/cookies.txt", "", 0o444, 0}
             ]
    end

    test "none to put, no archive" do
      download = download_fixture()

      assert :ok = perform_job(Worker, %{download_id: download.id})
      refute_received {:docker, :archive, _id, _files}
    end

    test "a refused archive fails the download before it starts" do
      FakeDocker.start(archive_error: "no space left on device")
      downloader = downloader_fixture(%{files: [%{name: "config", directory: "/config", contents: "x"}]})
      download = download_fixture(%{downloader_id: downloader.id})

      assert {:error, message} = perform_job(Worker, %{download_id: download.id})
      assert message_text(message) == "can't put its files in place: no space left on device"

      refute_received {:docker, :started, _id}
    end
  end

  defp container_event({:docker, :archive, name, files}, name), do: {:archive, files}
  defp container_event({:docker, :started, name}, name), do: :started
  defp container_event(_message, _name), do: nil

  describe "what's recorded as downloaded" do
    test "each item the script reports, with its own URL and host path", %{root: root} do
      downloader = downloader_fixture(%{output: %{source: "videos", target: "/out"}})
      download = download_fixture(%{downloader_id: downloader.id, url: "https://videos.test/playlist?list=x"})

      assert :ok = perform_job(Worker, %{download_id: download.id})

      assert [first, second] = Downloads.list_download_items(download)

      assert {first.url, first.path} ==
               {"https://videos.test/watch?v=1", Path.join([root, "videos", "One video [1].mp4"])}

      assert {second.url, second.downloader_name} == {"https://videos.test/watch?v=2", downloader.name}
    end

    test "a file reported without a URL is recorded under the download's URL" do
      download = download_fixture(%{url: "https://example.com/video"})

      assert :ok = perform_job(Worker, %{download_id: download.id})
      assert [%{url: "https://example.com/video"}] = Downloads.list_download_items(download)
    end

    test "a file finished before the run failed still counts" do
      download = download_fixture(%{url: "https://example.com/half-fail"})

      assert {:error, %Message{text: "connection lost"}} = perform_job(Worker, %{download_id: download.id})
      assert [%{path: path}] = Downloads.list_download_items(download)
      assert String.ends_with?(path, "/first.mp4")
    end

    test "a run that finished nothing records nothing" do
      download = download_fixture(%{url: "https://example.com/fail"})

      perform_job(Worker, %{download_id: download.id})
      assert Downloads.list_download_items(download) == []
    end
  end

  test "a failed run keeps the script's error and log" do
    download = download_fixture(%{url: "https://example.com/fail"})

    assert {:error, %Message{text: "This video is unavailable"}} = perform_job(Worker, %{download_id: download.id})

    assert %Download{status: :failed, exit_status: 1, error: %Message{text: "This video is unavailable"}, log: log} =
             Downloads.get_download!(download.id)

    assert log =~ "[site] abc: Downloading webpage"
  end

  test "keeps as many log lines as Settings says" do
    {:ok, _settings} = Settings.update_settings(%{log_lines: 1})
    download = download_fixture(%{url: "https://example.com/fail"})

    perform_job(Worker, %{download_id: download.id})

    # One line, the last: the error.
    assert %Download{log: log} = Downloads.get_download!(download.id)
    assert %{"contentoid" => "error", "message" => "This video is unavailable"} = JSON.decode!(log)
  end

  test "a failed run that reported no error is explained by its last log line" do
    download = download_fixture(%{url: "https://example.com/quiet-fail"})

    assert {:error, %Message{text: "ERROR: gone"}} = perform_job(Worker, %{download_id: download.id})
    assert %Download{status: :failed, exit_status: 2} = Downloads.get_download!(download.id)
  end

  test "a missing image is pulled, then run" do
    FakeDocker.start(image?: false)
    downloader = downloader_fixture(%{image: "ghcr.io/example/tool"})
    download = download_fixture(%{downloader_id: downloader.id})

    assert :ok = perform_job(Worker, %{download_id: download.id})
    assert_received {:docker, :pulled, "ghcr.io/example/tool:latest"}
  end

  test "a failed pull fails the download with the registry's reason" do
    FakeDocker.start(image?: false, pull_error: "pull access denied for fake/downloader")
    download = download_fixture()

    assert {:error, message} = perform_job(Worker, %{download_id: download.id})
    assert message_text(message) == "can't pull fake/downloader:1: pull access denied for fake/downloader"
  end

  test "a mount whose source is missing fails the download before any container starts" do
    downloader = downloader_fixture(%{mounts: [%{source: "/nonexistent/config", target: "/config"}]})
    download = download_fixture(%{downloader_id: downloader.id})

    assert {:error,
            %Message{msgid: "the mount source %{path} doesn't exist", bindings: %{"path" => "/nonexistent/config"}}} =
             perform_job(Worker, %{download_id: download.id})

    refute_received {:docker, :created, _body}
  end

  test "a download whose downloader was deleted fails" do
    downloader = downloader_fixture()
    {:ok, running} = Downloads.mark_running(download_fixture(%{downloader_id: downloader.id}))
    Repo.delete!(downloader)

    assert {:error, %Message{msgid: "its downloader was deleted"}} = Runner.run(Downloads.get_download!(running.id))
  end

  test "a download fails with the reason when Docker isn't answering" do
    FakeDocker.start(down?: true)
    download = download_fixture()

    assert {:error, message} = perform_job(Worker, %{download_id: download.id})
    assert message_text(message) =~ "Docker isn't answering: "
    assert %Download{status: :failed, error: ^message} = Downloads.get_download!(download.id)
  end

  test "a download cancelled while queued doesn't run" do
    download = download_fixture()
    {:ok, _cancelled} = Downloads.cancel_download(download)

    assert {:cancel, _reason} = perform_job(Worker, %{download_id: download.id})
    refute_received {:docker, :created, _body}
    assert %Download{status: :cancelled} = Downloads.get_download!(download.id)
  end

  # Cancelling relies on this: Oban kills a cancelled job's process, and its container doesn't care.
  # It is stopped first (SIGTERM, so the script can save its resume state), then removed.
  test "the container is stopped and removed when the process running it dies" do
    {:ok, running} = Downloads.mark_running(download_fixture(%{url: "https://example.com/hang"}))
    name = Docker.container_name(running)
    runner = spawn(fn -> Runner.run(running) end)
    assert_receive {:docker, :created, _body}, 1_000

    Process.exit(runner, :kill)

    assert_receive {:docker, :stopped, ^name}, 1_000
    assert_receive {:docker, :removed, ^name}, 1_000
  end

  test "remove_all/0 removes every download container" do
    {:ok, running} = Downloads.mark_running(download_fixture(%{url: "https://example.com/hang"}))
    name = Docker.container_name(running)
    run = Task.async(fn -> Runner.run(running) end)
    assert_receive {:docker, :created, _body}, 1_000

    assert {:ok, 1} = Docker.remove_all()
    assert_receive {:docker, :removed, ^name}, 1_000

    # Its container gone, the run ends as a kill (137) and the download as failed.
    assert {:error, _message} = Task.await(run)
    assert %Download{status: :failed, exit_status: 137} = Downloads.get_download!(running.id)
  end

  test "output is split into lines across chunks and on bare carriage returns, paths mapped to the host" do
    {:ok, running} = Downloads.mark_running(download_fixture())
    {:ok, writer} = Runner.Writer.start_link(running)
    output = %Runner.Output{download: running, binds: [{"/host/videos", "/out"}], log_lines: 200, writer: writer}

    # A bare \r ends the progress line, before the rest of its chunk.
    output = Runner.consume(output, ~s({"contentoid":"progress","percent":25,"text":"1MiB/s"}\r{"contentoid":"fi))
    assert {output.progress, output.progress_text} == {0.25, "1MiB/s"}

    output =
      [~s(le","path":"/out/a.mp4"}\n{"contentoid":"file","path":"/outside/b), ~s(.mp4"})]
      |> Enum.reduce(output, &Runner.consume(&2, &1))
      |> Runner.flush()

    :ok = Runner.Writer.stop(writer)

    assert output.files == ["/outside/b.mp4", "/host/videos/a.mp4"]
    assert %Download{files: ["/host/videos/a.mp4", "/outside/b.mp4"]} = Downloads.get_download!(running.id)
  end

  test "a file's start, progress and finish, and the whole download's total, as gallery-dl reports them" do
    {:ok, running} = Downloads.mark_running(download_fixture())
    {:ok, writer} = Runner.Writer.start_link(running)
    output = %Runner.Output{download: running, binds: [{"/host/pics", "/out"}], log_lines: 200, writer: writer}

    output =
      Runner.consume(output, """
      {"contentoid": "total", "done": 3, "of": 12, "text": "in this post"}
      {"contentoid": "start", "path": "/out/post/03.jpg"}
      {"contentoid": "progress", "percent": 40, "text": "1.6MB of 4.0MB, 2.1MB/s"}
      """)

    assert {output.total_progress, output.total_text} == {0.25, "3 of 12 in this post"}
    assert {output.current_file, output.progress} == {"/host/pics/post/03.jpg", 0.4}

    # Finished, the file's bar waits for the next; the total stays until the next report.
    output =
      Runner.consume(
        output,
        ~s({"contentoid": "file", "url": "https://pics.test/03.jpg", "path": "/out/post/03.jpg"}\n)
      )

    assert {output.current_file, output.progress, output.progress_text} == {nil, nil, nil}
    assert output.total_progress == 0.25

    :ok = Runner.Writer.stop(writer)

    assert %Download{total_text: "3 of 12 in this post", current_file: nil} = Downloads.get_download!(running.id)
    # A finished download has neither.
    assert %Download{total_progress: nil, total_text: nil} = Downloads.finish(running, status: :completed)
  end

  # The runner is blocked reading the container's output, so the writer saves what came last even
  # when nothing follows it.
  test "a running download's log is saved as it arrives, the last line too when output goes quiet" do
    {:ok, running} = Downloads.mark_running(download_fixture())
    {:ok, writer} = Runner.Writer.start_link(running)
    output = %Runner.Output{download: running, binds: [{"/host/videos", "/out"}], log_lines: 200, writer: writer}
    Downloads.subscribe()

    output = Runner.consume(output, "first\n")
    assert_receive {:download, %Download{log: "first", status: :running}}, 1_000

    # Too soon after the first write: held back, then written once the interval is up.
    _output = Runner.consume(output, "second\n")
    assert_receive {:download, %Download{log: "first\nsecond", status: :running}}, 1_000

    :ok = Runner.Writer.stop(writer)
  end

  test "disabling a downloader keeps its queued downloads; they wait" do
    downloader = downloader_fixture()
    download = download_fixture(%{downloader_id: downloader.id})

    {:ok, _disabled} = Downloaders.update_downloader(downloader, %{enabled: false})

    assert %Download{status: :queued} = Downloads.get_download!(download.id)
    assert_enqueued(worker: Worker, args: %{download_id: download.id})
  end

  # Its job was already handed out (waiting for a slot) when the downloader was disabled.
  test "a job whose downloader was disabled snoozes instead of running" do
    downloader = downloader_fixture()
    download = download_fixture(%{downloader_id: downloader.id})
    {:ok, _disabled} = Downloaders.update_downloader(downloader, %{enabled: false})

    assert {:snooze, _seconds} = perform_job(Worker, %{download_id: download.id})
    refute_received {:docker, :created, _body}
    assert %Download{status: :queued} = Downloads.get_download!(download.id)
  end

  describe "post-processing" do
    test "runs after the download, highest priority first, with its arguments, following moves and new files",
         %{root: root} do
      library = Path.join(root, "library")
      File.mkdir_p!(library)

      move =
        post_processor_fixture(%{
          image: "fake/post:move",
          priority: 10,
          mounts: [%{source: library, target: "/library", read_only: false}]
        })

      transcode = post_processor_fixture(%{image: "fake/post:transcode", priority: 5})

      downloader =
        downloader_fixture(%{
          output: %{source: "videos", target: "/out"},
          post_processor_assignments: assignments([transcode, {move, "/library"}])
        })

      download = download_fixture(%{downloader_id: downloader.id})

      assert :ok = perform_job(Worker, %{download_id: download.id})

      assert [downloaded, moved, transcoded] = created_bodies()

      assert {downloaded["Image"], moved["Image"], transcoded["Image"]} ==
               {downloader.image, move.image, transcode.image}

      # Its arguments are "$@"; the files are one per line in CONTENTOID_FILES.
      assert moved["Cmd"] == ["true", "contentoid", "/library"]
      assert "CONTENTOID_ARGUMENTS=/library" in moved["Env"]
      assert "CONTENTOID_FILES=/contentoid/output/video.mp4" in moved["Env"]
      assert "CONTENTOID_URL=#{download.url}" in moved["Env"]
      assert transcoded["Cmd"] == ["true", "contentoid"]
      assert "#{root}/videos:/contentoid/output" in moved["HostConfig"]["Binds"]
      # Host to container, for scripts taking host paths: the output first, then the mounts.
      assert "CONTENTOID_MOUNTS=#{root}/videos\t/contentoid/output\n#{library}\t/library" in moved["Env"]

      moved_path = Path.join(library, "video.mp4")
      new_path = Path.join([root, "videos", "video.mkv"])

      move_name = "#{move.name} /library"
      transcode_name = transcode.name

      assert %Download{
               status: :completed,
               phase: :post_processing,
               files: [^moved_path, ^new_path],
               steps: [
                 %Step{
                   name: ^move_name,
                   status: :succeeded,
                   exit_status: 0,
                   started_at: %DateTime{},
                   finished_at: %DateTime{}
                 },
                 %Step{name: ^transcode_name, status: :succeeded}
               ]
             } = Downloads.get_download!(download.id)

      assert [%{path: ^moved_path} | _new] = Downloads.list_download_items(download)
    end

    test "a download runs its downloader's and its schedule's assignments together, each set of arguments once" do
      first = post_processor_fixture(%{priority: 1})
      second = post_processor_fixture(%{priority: 2})
      downloader = downloader_fixture(%{post_processor_assignments: assignments([first, {second, "a"}])})

      {:ok, schedule} =
        Schedules.create_schedule(%{
          name: "Schedule #{System.unique_integer([:positive])}",
          url: "https://example.com/channel",
          downloader_id: downloader.id,
          cron: "0 3 * * *",
          timezone: "Etc/UTC",
          post_processor_assignments: assignments([first, {second, "a"}, {second, ~s("b c")}])
        })

      {:ok, download} = Schedules.run_now(schedule)
      assert :ok = perform_job(Worker, %{download_id: download.id})

      assert [_downloaded | post] = created_bodies()

      assert Enum.map(post, &{&1["Image"], Enum.drop(&1["Cmd"], 2)}) == [
               {second.image, ["a"]},
               {second.image, ["b c"]},
               {first.image, []}
             ]
    end

    test "an assignment's own mounts are bound on top of the post-processor's, and tell runs apart", %{root: root} do
      films = Path.join(root, "films")
      shows = Path.join(root, "shows")
      for dir <- [films, shows], do: File.mkdir_p!(dir)
      move = post_processor_fixture(%{image: "fake/post:move"})

      downloader =
        downloader_fixture(%{
          output: %{source: "videos", target: "/out"},
          post_processor_assignments:
            assignments([
              {move, "/dest", [%{source: films, target: "/dest", read_only: false}]},
              {move, "/dest", [%{source: shows, target: "/dest", read_only: false}]}
            ])
        })

      download = download_fixture(%{downloader_id: downloader.id})
      assert :ok = perform_job(Worker, %{download_id: download.id})

      # Same post-processor and arguments, different mounts: both run.
      assert [_downloaded, into_films, into_shows] = created_bodies()
      assert "#{films}:/dest" in into_films["HostConfig"]["Binds"]
      assert "#{shows}:/dest" in into_shows["HostConfig"]["Binds"]

      # The first move lands in films through its mount; the second no longer sees the file (it's
      # outside every mount it has) and moves nothing.
      moved = Path.join(films, "video.mp4")

      assert %Download{
               status: :completed,
               files: [^moved],
               steps: [%Step{status: :succeeded}, %Step{name: second_name, log: second_log}]
             } = Downloads.get_download!(download.id)

      assert second_name == "#{move.name} /dest (#{shows} at /dest)"
      assert second_log =~ "not passed to #{move.name} /dest (#{shows} at /dest), outside every mount: #{moved}"
    end

    test "one that runs only on files is skipped when there are none; a disabled one never runs" do
      on_files = post_processor_fixture(%{image: "fake/post:on-files", trigger: :new_files})
      always = post_processor_fixture(%{image: "fake/post:always", trigger: :always})
      disabled = post_processor_fixture(%{image: "fake/post:disabled", trigger: :always, enabled: false})
      downloader = downloader_fixture(%{post_processor_assignments: assignments([on_files, always, disabled])})
      download = download_fixture(%{downloader_id: downloader.id, url: "https://example.com/nothing"})

      assert :ok = perform_job(Worker, %{download_id: download.id})

      assert [_downloaded, %{"Image" => "fake/post:always"}] = created_bodies()
      # The disabled one is never listed.
      assert %Download{status: :completed, steps: [%Step{status: :skipped}, %Step{status: :succeeded}]} =
               Downloads.get_download!(download.id)
    end

    test "a failure fails the download and skips the rest; a retry runs only post-processing", %{root: root} do
      failing = post_processor_fixture(%{image: "fake/post:fail", priority: 10})
      ok = post_processor_fixture(%{image: "fake/post:ok", priority: 1})

      downloader =
        downloader_fixture(%{
          output: %{source: "videos", target: "/out"},
          post_processor_assignments: assignments([failing, ok])
        })

      download = download_fixture(%{downloader_id: downloader.id})
      file = Path.join([root, "videos", "video.mp4"])
      assert {:error, message} = perform_job(Worker, %{download_id: download.id})
      assert message_text(message) == "#{failing.name}: ffmpeg failed"
      assert [_downloaded, %{"Image" => "fake/post:fail"}] = created_bodies()

      assert %Download{
               status: :failed,
               phase: :post_processing,
               files: [^file],
               error: ^message,
               steps: [%Step{status: :failed, exit_status: 1, log: log}, %Step{status: :skipped}]
             } = failed = Downloads.get_download!(download.id)

      assert log =~ "ffmpeg failed"

      {:ok, _queued} = Downloads.retry_download(failed)
      assert Downloads.get_download!(download.id).steps == []
      assert {:error, ^message} = perform_job(Worker, %{download_id: download.id})
      assert [%{"Image" => "fake/post:fail"}] = created_bodies()

      # Replaced, not appended.
      assert %Download{files: [^file], steps: [%Step{status: :failed}, %Step{status: :skipped}]} =
               Downloads.get_download!(download.id)
    end

    test "a post-processor that prints nothing shows as running, and its failure is its own" do
      hang = post_processor_fixture(%{image: "fake/post:hang", priority: 10})
      ok = post_processor_fixture(%{image: "fake/post:ok", priority: 1})
      downloader = downloader_fixture(%{post_processor_assignments: assignments([hang, ok])})
      {:ok, running} = Downloads.mark_running(download_fixture(%{downloader_id: downloader.id}))
      run = Task.async(fn -> Runner.run(running) end)

      # Saved before its container started, though it never prints a line.
      assert_receive {:docker, :created, %{"Image" => "fake/post:hang"}}, 1_000

      assert %Download{
               status: :running,
               steps: [%Step{status: :running, started_at: %DateTime{}, log: nil}, %Step{status: :pending}]
             } = Downloads.get_download!(running.id)

      assert {:ok, 1} = Docker.remove_all()
      assert {:error, message} = Task.await(run)
      assert message_text(message) == "#{hang.name}: exited with status 137"

      assert %Download{
               status: :failed,
               steps: [%Step{status: :failed, exit_status: 137}, %Step{status: :skipped}],
               log: downloader_log
             } = Downloads.get_download!(running.id)

      refute downloader_log =~ "=="
    end

    test "removed files leave the download's files" do
      remove = post_processor_fixture(%{image: "fake/post:remove"})
      downloader = downloader_fixture(%{post_processor_assignments: assignments([remove])})
      download = download_fixture(%{downloader_id: downloader.id})

      assert :ok = perform_job(Worker, %{download_id: download.id})
      assert %Download{status: :completed, files: []} = Downloads.get_download!(download.id)
    end

    # Its label, shown as the progress text while it runs, is the post-processor's name and all its
    # arguments: an rsync pair list runs to thousands of characters.
    test "a run with a long list of arguments runs" do
      ok = post_processor_fixture(%{image: "fake/post:ok"})
      pairs = Enum.map_join(1..40, " ", &~s(user#{&1} "/mnt/private/synced/user #{&1}/ofscraper"))
      downloader = downloader_fixture(%{post_processor_assignments: assignments([{ok, pairs}])})
      download = download_fixture(%{downloader_id: downloader.id})

      assert :ok = perform_job(Worker, %{download_id: download.id})
      assert %Download{status: :completed, steps: [%Step{status: :succeeded}]} = Downloads.get_download!(download.id)
    end
  end

  # Every container created so far, in order.
  defp created_bodies do
    receive do
      {:docker, :created, body} -> [body | created_bodies()]
    after
      0 -> []
    end
  end
end

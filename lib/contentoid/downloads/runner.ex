defmodule Contentoid.Downloads.Runner do
  @moduledoc """
  Runs one download: its downloader's script in a container from the downloader's image
  (`Contentoid.Downloads.Docker`), the output read line by line through
  `Contentoid.Downloads.Protocol`.

  The script runs as `/bin/sh -c SCRIPT contentoid URL` with `CONTENTOID_URL` set, or for an
  arguments download `/bin/sh -c SCRIPT contentoid ARG…` (`Download.argv/1`) with
  `CONTENTOID_ARGUMENTS` set; and with `CONTENTOID_OUTPUT` (the output mount's container path),
  `CONTENTOID_DOWNLOAD_ID` and the downloader's mounts and volumes in place
  (`Contentoid.Downloaders.Downloader`). Files it reports are mapped from the container's output
  mount back to the host. Progress, files and the log are saved to the download as the run goes,
  at most twice a second, by a `Runner.Writer` per container, so the download's page follows it live.

  When the script exits 0 and post-processors apply (`Contentoid.PostProcessors.for_download/1`),
  the download moves to phase `post_processing` and each runs in turn in its own container, in the
  same job (`Contentoid.PostProcessors.PostProcessor` has the script contract). They see the
  download's current files, and report moves, removals and new files back. The first to fail fails
  the download and skips the rest; a retry then starts again at post-processing, with the files.

  A container outlives whoever started it, so each run has a watchdog that removes the container if
  the runner dies before the run ends (Oban kills a cancelled job's process); removing the container
  stops the script and everything it started. At shutdown `Contentoid.Downloads.Janitor` removes
  what's left, and the next boot requeues downloads still `running`.
  """

  use Gettext, backend: ContentoidWeb.Gettext

  alias Contentoid.Downloaders
  alias Contentoid.Downloaders.Downloader
  alias Contentoid.Downloaders.Downloader.ConfigFile
  alias Contentoid.Downloads
  alias Contentoid.Downloads.Docker
  alias Contentoid.Downloads.Download
  alias Contentoid.Downloads.Protocol
  alias Contentoid.Downloads.Runner.Output
  alias Contentoid.Downloads.Runner.Writer
  alias Contentoid.Downloads.TaskSupervisor
  alias Contentoid.Message
  alias Contentoid.Paths
  alias Contentoid.PostProcessors
  alias Contentoid.PostProcessors.Assignment
  alias Contentoid.PostProcessors.PostProcessor
  alias Contentoid.Settings
  alias ContentoidWeb.Messages

  require Logger

  @doc """
  Runs `download`, which must already be `running`, to the end and records the outcome: its
  downloader's script, then its post-processors; or only the post-processors when it already got
  that far. Returns `:ok` when every script succeeded, `{:error, message}` otherwise.
  """
  @spec run(Download.t()) :: :ok | {:error, Message.t()}
  def run(%Download{status: :running, phase: :post_processing} = download) do
    post_process(download, PostProcessors.for_download(download))
  end

  def run(%Download{status: :running} = download) do
    with {:ok, downloader} <- fetch_downloader(download),
         {:ok, output_dir} <- prepare_output(downloader),
         output_bind = {output_dir, downloader.output.target},
         {:ok, binds, _path_map} <- binds(output_bind, downloader.mounts, downloader.volumes) do
      run_in(download, downloader, output_bind, binds)
    else
      {:error, message} -> fail(download, message)
    end
  end

  defp fetch_downloader(%Download{downloader_id: nil}), do: {:error, downloader_deleted()}

  defp fetch_downloader(%Download{downloader_id: id}) do
    case Downloaders.get_downloader(id) do
      nil -> {:error, downloader_deleted()}
      downloader -> {:ok, downloader}
    end
  end

  defp downloader_deleted, do: Message.new(gettext_noop("its downloader was deleted"))

  defp prepare_output(%Downloader{output: output}) do
    with {:ok, dir} <- Downloaders.host_path(output.source) do
      case File.mkdir_p(dir) do
        :ok ->
          {:ok, dir}

        {:error, reason} ->
          {:error,
           Message.new(gettext_noop("can't create the output directory %{dir}: %{reason}"),
             dir: dir,
             reason: List.to_string(:file.format_error(reason))
           )}
      end
    end
  end

  # Docker would create a missing bind source as an empty root-owned directory; refuse instead.
  # Returns the bind strings and the `{host, target}` directories files can be mapped through: the
  # output and the mounts (a volume has no host path).
  defp binds({output_dir, output_target} = output_bind, mounts, volumes) do
    with {:ok, mounts} <- resolve_mounts(mounts) do
      case Enum.find(mounts, fn {source, _target, _read_only} -> not File.exists?(source) end) do
        {missing, _target, _read_only} ->
          {:error, Message.new(gettext_noop("the mount source %{path} doesn't exist"), path: missing)}

        nil ->
          volumes = for volume <- volumes, do: {volume.name, volume.target, volume.read_only}
          strings = Enum.map([{output_dir, output_target, false} | mounts ++ volumes], &bind/1)
          {:ok, strings, [output_bind | for({host, target, _read_only} <- mounts, do: {host, target})]}
      end
    end
  end

  defp resolve_mounts(mounts) do
    mounts
    |> Enum.reduce_while({:ok, []}, fn mount, {:ok, resolved} ->
      case Downloaders.host_path(mount.source) do
        {:ok, host} -> {:cont, {:ok, [{host, mount.target, mount.read_only} | resolved]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp bind({source, target, true}), do: "#{source}:#{target}:ro"
  defp bind({source, target, false}), do: "#{source}:#{target}"

  defp run_in(download, downloader, output_bind, binds) do
    output = %Output{download: download, binds: [output_bind], log_lines: Settings.get_settings().log_lines}

    env = [
      input_env(download),
      "CONTENTOID_OUTPUT=#{downloader.output.target}",
      "CONTENTOID_DOWNLOAD_ID=#{download.id}"
    ]

    container = container(downloader.image, downloader.script, args(download), env, binds)

    case run_container(download, container, output, downloader.files) do
      {:error, message} -> fail(download, message)
      {output, exit_status} -> finish(download, output, exit_status)
    end
  end

  # Runs `container` to its end under a watchdog, its log fed into `output`, with a writer saving
  # its progress and log as it goes (stopped, after a last write, before the runner moves on).
  defp run_container(download, container, output, config_files) do
    on_pull = fn image -> Downloads.record_progress(download, progress: nil, progress_text: "Pulling #{image}") end
    files = for file <- config_files, do: {ConfigFile.path(file), file.contents}
    {:ok, writer} = Writer.start_link(download)

    watchdog = watch(Docker.container_name(download))

    result =
      Docker.run(Docker.container_name(download), container, %{output | writer: writer}, on_pull: on_pull, files: files)

    send(watchdog, {:done, self()})
    :ok = Writer.stop(writer)
    result
  end

  # A script's container: `/bin/sh -c script`, with `$0` "contentoid" and `argv` as "$@".
  defp container(image, script, argv, env, binds) do
    %{
      "Image" => image,
      "Entrypoint" => ["/bin/sh", "-c"],
      "Cmd" => [script, "contentoid" | argv],
      "Env" => env,
      "HostConfig" => %{"Binds" => binds}
    }
  end

  defp args(%Download{url: nil} = download), do: Download.argv(download)
  defp args(%Download{url: url}), do: [url]

  defp input_env(%Download{url: nil, arguments: arguments}), do: "CONTENTOID_ARGUMENTS=#{arguments}"
  defp input_env(%Download{url: url}), do: "CONTENTOID_URL=#{url}"

  # A post-processor's own arguments are CONTENTOID_ARGUMENTS; the download's are named apart, as
  # written and as words (one per line), so a script needn't split them itself.
  defp download_input_env(%Download{url: nil, arguments: arguments} = download) do
    [
      "CONTENTOID_DOWNLOAD_ARGUMENTS=#{arguments}",
      "CONTENTOID_DOWNLOAD_ARGV=#{Enum.join(Download.argv(download), "\n")}"
    ]
  end

  defp download_input_env(%Download{url: url}), do: ["CONTENTOID_URL=#{url}"]

  defp fail(download, message) do
    Downloads.finish(download, status: :failed, error: message)
    {:error, message}
  end

  # Removes the container `name` unless the calling process reports the run done first.
  defp watch(name) do
    runner = self()

    {:ok, watchdog} =
      Task.Supervisor.start_child(TaskSupervisor, fn ->
        ref = Process.monitor(runner)

        receive do
          {:done, ^runner} ->
            :ok

          {:DOWN, ^ref, :process, ^runner, _reason} ->
            case Docker.remove(name) do
              :ok ->
                :ok

              {:error, message} ->
                Logger.warning("Couldn't remove container #{name}: #{Messages.message_text(message)}")
            end
        end
      end)

    watchdog
  end

  # A finished download has no speed or ETA left to show.
  defp finish(download, output, 0) do
    case PostProcessors.for_download(download) do
      [] ->
        changes = Keyword.merge(results(output), status: :completed, exit_status: 0, progress: 1.0, progress_text: nil)
        Downloads.finish(download, changes)
        :ok

      assignments ->
        [{output_dir, _target} | _mounts] = output.binds
        results = results(output)

        download
        |> Downloads.record_progress(
          phase: :post_processing,
          output_dir: output_dir,
          files: results[:files],
          log: results[:log],
          progress: nil,
          progress_text: nil,
          total_progress: nil,
          total_text: nil,
          current_file: nil
        )
        |> case do
          nil -> {:error, no_longer_running()}
          updated -> post_process(updated, assignments)
        end
    end
  end

  defp finish(download, output, exit_status) do
    message = failure_message(output, exit_status)
    Downloads.finish(download, [status: :failed, error: message, exit_status: exit_status] ++ results(output))
    {:error, message}
  end

  defp results(output) do
    [progress_text: output.progress_text, files: Enum.reverse(output.files), log: log_text(output)]
  end

  @doc false
  # What `Runner.Writer` saves while the container runs.
  def live_changes(%Output{} = output) do
    [
      progress: output.progress,
      progress_text: output.progress_text,
      total_progress: output.total_progress,
      total_text: output.total_text,
      current_file: output.current_file,
      files: Enum.reverse(output.files),
      log: log_text(output)
    ]
  end

  # The download's whole log: what came before this container, then its last `log_lines` lines.
  defp log_text(output) do
    lines = output.log |> Enum.take(output.log_lines) |> Enum.reverse() |> Enum.join("\n")
    Enum.join(Enum.reject([output.log_prefix, lines], &(&1 in [nil, ""])), "\n")
  end

  defp last_log_line(%{log: [line | _]}), do: line
  defp last_log_line(_output), do: nil

  # The script's own explanation (an `error` message, else its last log line) is the tool's text.
  defp failure_message(output, exit_status) do
    case output.error || last_log_line(output) do
      nil -> Message.new(gettext_noop("exited with status %{status}"), status: exit_status)
      text -> Message.text(text)
    end
  end

  defp no_longer_running, do: Message.new(gettext_noop("download is no longer running"))

  defp named(name, reason), do: Message.new(gettext_noop("%{name}: %{reason}"), name: name, reason: reason)

  # Each assigned post-processor in turn on the download's current files, until one fails.
  defp post_process(download, assignments) do
    assignments
    |> Enum.reduce_while({:ok, download}, fn %Assignment{post_processor: post_processor} = assignment,
                                             {:ok, download} ->
      if post_processor.trigger == :new_files and download.files == [] do
        {:cont, {:ok, download}}
      else
        case run_post_processor(download, assignment) do
          {:ok, download} -> {:cont, {:ok, download}}
          {:error, _message} = error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, download} ->
        Downloads.finish(download, status: :completed, exit_status: 0, progress: 1.0, progress_text: nil)
        :ok

      error ->
        error
    end
  end

  # The script gets the assignment's arguments as "$@" and the files in CONTENTOID_FILES, one per
  # line; the assignment's mounts are bound after the post-processor's own.
  defp run_post_processor(download, %Assignment{post_processor: %PostProcessor{} = post_processor} = assignment) do
    name = label(assignment)
    mounts = post_processor.mounts ++ assignment.mounts

    with {:ok, output_dir} <- existing_output_dir(download),
         {:ok, binds, path_map} <- binds({output_dir, PostProcessor.output_target()}, mounts, post_processor.volumes) do
      mapped = Enum.map(download.files, &{&1, map_path(&1, path_map)})
      container_files = for {_host, container} <- mapped, container, do: container

      # The label stays until the script reports progress of its own.
      output =
        for {host, nil} <- mapped,
            reduce: %Output{
              download: download,
              binds: path_map,
              log_lines: Settings.get_settings().log_lines,
              log_prefix: Enum.join(Enum.reject([download.log, "== #{name} =="], &(&1 in [nil, ""])), "\n"),
              progress_text: "Post-processing: #{name}",
              files: Enum.reverse(download.files)
            } do
          output -> log(output, "not passed to #{name}, outside every mount: #{host}")
        end

      Downloads.record_progress(download, progress: nil, progress_text: "Post-processing: #{name}")

      env =
        [
          "CONTENTOID_ARGUMENTS=#{assignment.arguments}",
          "CONTENTOID_OUTPUT=#{PostProcessor.output_target()}",
          "CONTENTOID_DOWNLOAD_ID=#{download.id}",
          "CONTENTOID_DOWNLOADER=#{download.downloader_name}",
          "CONTENTOID_FILES=#{Enum.join(container_files, "\n")}",
          # Host path, tab, container path, a line per bind (the output first), so a script can take
          # host paths as arguments.
          "CONTENTOID_MOUNTS=#{Enum.map_join(path_map, "\n", fn {host, target} -> "#{host}\t#{target}" end)}"
        ] ++ download_input_env(download)

      container = container(post_processor.image, post_processor.script, Assignment.argv(assignment), env, binds)

      case run_container(download, container, output, post_processor.files) do
        {:error, message} -> fail(download, named(name, message))
        {output, exit_status} -> post_processed(download, name, output, exit_status)
      end
    else
      {:error, message} -> fail(download, named(name, message))
    end
  end

  # How a run is named in the log, its progress and errors: the post-processor, then its arguments
  # and its own mounts, which tell apart assignments of one post-processor.
  defp label(%Assignment{post_processor: post_processor, arguments: arguments, mounts: mounts}) do
    mounted = if mounts != [], do: "(#{Enum.map_join(mounts, ", ", &"#{&1.source} at #{&1.target}")})"
    [post_processor.name, arguments, mounted] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp existing_output_dir(%Download{output_dir: nil}),
    do: {:error, Message.new(gettext_noop("its output directory is unknown"))}

  defp existing_output_dir(%Download{output_dir: dir}) do
    if File.dir?(dir),
      do: {:ok, dir},
      else: {:error, Message.new(gettext_noop("the output directory %{dir} doesn't exist"), dir: dir)}
  end

  # The post-processor's log follows the download's, under a heading of its own (`log_prefix`).
  defp post_processed(download, name, output, exit_status) do
    log = log_text(output)
    files = Enum.reverse(output.files)

    if exit_status == 0 do
      case Downloads.record_progress(download, files: files, log: log) do
        nil -> {:error, no_longer_running()}
        updated -> {:ok, updated}
      end
    else
      message = named(name, failure_message(output, exit_status))
      Downloads.finish(download, status: :failed, error: message, exit_status: exit_status, files: files, log: log)
      {:error, message}
    end
  end

  @doc false
  # Splits `chunk` into lines (on `\n`, `\r\n` or a bare `\r`, which progress readouts redraw with),
  # holding back a trailing partial line until the next chunk.
  def consume(%Output{} = output, chunk) do
    lines = String.split(output.buffer <> chunk, ~r/\r\n|\r|\n/)
    {complete, [partial]} = Enum.split(lines, -1)
    complete |> Enum.reduce(output, &handle_line/2) |> Map.put(:buffer, partial)
  end

  @doc false
  def flush(%Output{} = output) do
    if output.buffer == "", do: output, else: handle_line(output.buffer, %{output | buffer: ""})
  end

  defp handle_line("", output), do: output

  defp handle_line(line, output) do
    case Protocol.parse_line(line) do
      {:progress, fraction, text} ->
        changed(%{output | progress: fraction, progress_text: text})

      {:total, fraction, text} ->
        changed(%{output | total_progress: fraction, total_text: text})

      {:start, path} ->
        changed(%{log(output, line) | current_file: to_host(path, output), progress: nil, progress_text: nil})

      {:file, path, url} ->
        finished(output, line, url || output.download.url, to_host(path, output))

      {:moved, from, to} ->
        moved(output, line, to_host(from, output), to_host(to, output))

      {:removed, path} ->
        host_path = to_host(path, output)
        changed(%{log(output, line) | files: List.delete(output.files, host_path)})

      {:error, message} ->
        changed(%{log(output, line) | error: message})

      :log ->
        changed(log(output, line))

      :ignore ->
        output
    end
  end

  # A finished file is recorded at once, so it counts even if the run later fails or is cancelled.
  # Its own progress is over: the bar waits for the next file's.
  defp finished(output, line, url, path) do
    Downloads.record_item(output.download, url, path)

    changed(%{
      log(output, line)
      | files: [path | output.files],
        current_file: nil,
        progress: nil,
        progress_text: nil
    })
  end

  # The item keeps its record under the new path.
  defp moved(output, line, from, to) do
    Downloads.move_items(output.download, from, to)
    files = Enum.map(output.files, &if(&1 == from, do: to, else: &1))
    changed(%{log(output, line) | files: files})
  end

  # A container path maps to the host through the bind with the longest matching target; other
  # paths are kept as reported.
  defp to_host(path, %Output{binds: binds}) do
    map_path(path, Enum.map(binds, fn {host, target} -> {target, host} end)) || path
  end

  # `path` mapped through the `{from, to}` directory pair with the longest `from` it's in; nil when
  # it's in none.
  defp map_path(path, pairs) do
    pairs
    |> Enum.filter(fn {from, _to} -> Paths.under?(path, from) end)
    |> Enum.max_by(fn {from, _to} -> String.length(from) end, fn -> nil end)
    |> case do
      nil -> nil
      {from, to} when path == from -> to
      {from, to} -> Path.join(to, Path.relative_to(path, from))
    end
  end

  # Newest first; trimmed back to `log_lines` once it holds twice that.
  defp log(output, line) do
    if output.log_count >= 2 * output.log_lines do
      %{output | log: [line | Enum.take(output.log, output.log_lines - 1)], log_count: output.log_lines}
    else
      %{output | log: [line | output.log], log_count: output.log_count + 1}
    end
  end

  # Hands the latest state to the writer, which saves it within the interval.
  defp changed(%Output{writer: writer} = output) do
    Writer.update(writer, output)
    output
  end
end

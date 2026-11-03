defmodule Contentoid.Downloads.Runner.Output do
  @moduledoc false
  # The `Collectable` a container's log stream is fed into (`Contentoid.Downloads.Docker.run/4`). It
  # lives in the runner's process; every change goes to the run's `Runner.Writer`, which writes it to
  # the download.

  alias Contentoid.Downloads.Runner

  @enforce_keys [:download, :binds, :log_lines]
  defstruct [
    :download,
    # `{host_dir, container_target}` directories bound into the container, for mapping reported
    # paths back: the output mount first.
    :binds,
    # Lines of output kept as the download's log (Settings).
    :log_lines,
    :progress,
    :progress_text,
    # The whole download's, when the tool reports it (a `total` message).
    :total_progress,
    :total_text,
    # The file being downloaded now, as a host path (a `start` message).
    :current_file,
    :error,
    # The `Runner.Writer` saving this run's progress and log; set while the container runs.
    :writer,
    # What the download's log already says before this container's lines (a post-processor's run
    # follows the earlier output under its own heading); nil for the downloader.
    log_prefix: nil,
    buffer: "",
    files: [],
    log: [],
    log_count: 0
  ]

  defimpl Collectable do
    def into(output) do
      collector = fn
        output, {:cont, chunk} -> Runner.consume(output, chunk)
        output, :done -> Runner.flush(output)
        _output, :halt -> :ok
      end

      {output, collector}
    end
  end
end

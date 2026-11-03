defmodule Contentoid.DownloadsFixtures do
  @moduledoc """
  Test helpers for downloads, downloaders and schedules: an empty download directory, downloaders,
  downloads in a given state, and schedules. Docker itself is `Contentoid.FakeDocker`.

  The test database also holds the three default downloaders (inserted by their migration).
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Contentoid.Downloaders
  alias Contentoid.Downloads
  alias Contentoid.PostProcessors
  alias Contentoid.Schedules
  alias Contentoid.Settings

  @doc """
  Empties the download directory (`Contentoid.Settings.download_dir/0`) now and after the test, and
  returns it. The directory is shared: only for `async: false` tests.
  """
  def reset_download_dir do
    {:ok, dir} = Settings.download_dir()
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc "Valid attributes for a downloader; `overrides` win."
  def downloader_attrs(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Enum.into(overrides, %{
      name: "Fixture #{n}",
      url_pattern: "^https://example\\.com/",
      priority: 100 + n,
      image: "fake/downloader:1",
      script: "exec fake-tool \"$CONTENTOID_URL\"",
      output: %{source: "fixture-#{n}", target: "/out"}
    })
  end

  @doc "A downloader; see `downloader_attrs/1`."
  def downloader_fixture(overrides \\ %{}) do
    {:ok, downloader} = overrides |> downloader_attrs() |> Downloaders.create_downloader()
    downloader
  end

  @doc "A post-processor running `fake/post:ok` (`Contentoid.FakeDocker`); `overrides` win."
  def post_processor_fixture(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, post_processor} =
      overrides
      |> Enum.into(%{name: "Post #{n}", image: "fake/post:ok", script: "true"})
      |> PostProcessors.create_post_processor()

    post_processor
  end

  @doc """
  `post_processor_assignments` attrs for a downloader or schedule: each a post-processor, a
  `{post_processor, arguments}` pair or a `{post_processor, arguments, mounts}` triple.
  """
  def assignments(post_processors) do
    for entry <- post_processors do
      case entry do
        {post_processor, arguments, mounts} ->
          %{post_processor_id: post_processor.id, arguments: arguments, mounts: mounts}

        {post_processor, arguments} ->
          %{post_processor_id: post_processor.id, arguments: arguments}

        post_processor ->
          %{post_processor_id: post_processor.id}
      end
    end
  end

  @doc """
  A queued download, of `https://example.com/video` by a new fixture downloader unless `attrs` say
  otherwise.
  """
  def download_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    downloader_id = Map.get_lazy(attrs, :downloader_id, fn -> downloader_fixture().id end)

    {:ok, download} =
      attrs
      |> Map.put(:downloader_id, downloader_id)
      |> Map.put_new(:url, "https://example.com/video")
      |> Downloads.create_download()

    download
  end

  @doc "A download that ran and failed with `error`, the tool's text."
  def failed_download_fixture(attrs \\ %{}, error \\ "something broke") do
    {:ok, running} = attrs |> download_fixture() |> Downloads.mark_running()

    Downloads.finish(running,
      status: :failed,
      error: Contentoid.Message.text(error),
      exit_status: 1,
      log: "first line\n#{error}"
    )
  end

  @doc "A URL schedule running daily at 03:00 UTC; `attrs` win."
  def schedule_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, schedule} =
      attrs
      |> Enum.into(%{
        name: "Schedule #{n}",
        url: "https://example.com/channel/#{n}",
        cron: "0 3 * * *",
        timezone: "Etc/UTC"
      })
      |> Schedules.create_schedule()

    schedule
  end
end

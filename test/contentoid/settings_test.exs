defmodule Contentoid.SettingsTest do
  # Changes the global download limit and the app's config, hence not async.
  use Contentoid.DataCase, async: false

  alias Contentoid.Downloaders
  alias Contentoid.Downloads.Slots
  alias Contentoid.Message
  alias Contentoid.Settings

  test "relative sources resolve under the configured default, the saved directory, or fail without either" do
    default = Application.get_env(:contentoid, Settings)
    on_exit(fn -> Application.put_env(:contentoid, Settings, default) end)

    assert Settings.download_dir() == {:ok, Path.expand(default[:default_download_dir])}

    Application.put_env(:contentoid, Settings, [])
    assert Downloaders.host_path("yt-dlp") == {:error, Message.new("no download directory set: set it in Settings")}
    assert Downloaders.host_path("/srv/media") == {:ok, "/srv/media"}

    {:ok, _settings} = Settings.update_settings(%{download_dir: "~/media"})
    assert Downloaders.host_path("yt-dlp") == {:ok, Path.join(Path.expand("~/media"), "yt-dlp")}
  end

  test "paths must be absolute or start with ~, and the stop grace is capped" do
    assert {:error, changeset} = Settings.update_settings(%{download_dir: "media"})
    assert errors_on(changeset).download_dir == ["must be an absolute path or start with ~"]

    assert {:error, changeset} = Settings.update_settings(%{stop_grace_seconds: 31})
    assert %{stop_grace_seconds: [_message]} = errors_on(changeset)
  end

  test "a changed download limit applies at once" do
    on_exit(fn -> Slots.set_limit(4) end)

    {:ok, _settings} = Settings.update_settings(%{max_concurrent_downloads: 7})
    assert Slots.info().limit == 7
  end
end

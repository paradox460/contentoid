defmodule Contentoid.DownloadersTest do
  use Contentoid.DataCase, async: true

  import Contentoid.DownloadsFixtures

  alias Contentoid.Downloaders
  alias Contentoid.Downloaders.Downloader
  alias Contentoid.Settings

  describe "changeset/2" do
    test "makes the slug from the name unless one is given" do
      changeset = Downloader.changeset(%Downloader{}, downloader_attrs(%{name: "  Bandcamp Albums! "}))
      assert Ecto.Changeset.get_field(changeset, :slug) == "bandcamp-albums"

      changeset = Downloader.changeset(%Downloader{}, downloader_attrs(%{name: "Bandcamp", slug: "bc"}))
      assert Ecto.Changeset.get_field(changeset, :slug) == "bc"
    end

    test "rejects a slug that isn't lowercase words joined by single dashes" do
      for slug <- ["Has Caps", "two--dashes", "-leading", "under_score"] do
        changeset = Downloader.changeset(%Downloader{}, downloader_attrs(%{slug: slug}))
        assert %{slug: [_message]} = errors_on(changeset), "accepted #{inspect(slug)}"
      end
    end

    test "rejects a pattern that doesn't compile, saying where" do
      changeset = Downloader.changeset(%Downloader{}, downloader_attrs(%{url_pattern: "^https://(unclosed"}))
      assert %{url_pattern: ["isn't a valid regex: " <> _reason]} = errors_on(changeset)
    end

    test "a URL downloader needs a pattern; an arguments downloader has none" do
      changeset = Downloader.changeset(%Downloader{}, Map.delete(downloader_attrs(), :url_pattern))
      assert %{url_pattern: ["can't be blank"]} = errors_on(changeset)

      changeset = Downloader.changeset(%Downloader{}, downloader_attrs(%{input: :arguments, url_pattern: "(unclosed"}))
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :url_pattern) == nil
    end

    test "requires an output mount" do
      changeset = Downloader.changeset(%Downloader{}, Map.delete(downloader_attrs(), :output))
      assert %{output: ["can't be blank"]} = errors_on(changeset)
    end

    test "mount sources may be absolute, ~ or relative, but can't leave the download directory" do
      for source <- ["/srv/media", "~/media", "media/videos"] do
        changeset = Downloader.changeset(%Downloader{}, downloader_attrs(%{mounts: [%{source: source, target: "/m"}]}))
        assert changeset.valid?, "rejected #{inspect(source)}"
      end

      changeset =
        Downloader.changeset(%Downloader{}, downloader_attrs(%{output: %{source: "../elsewhere", target: "/out"}}))

      assert %{output: %{source: ["can't leave the download directory (no ..)"]}} = errors_on(changeset)
    end

    test "container paths must be absolute and not the root" do
      changeset =
        Downloader.changeset(
          %Downloader{},
          downloader_attrs(%{mounts: [%{source: "a", target: "relative"}, %{source: "b", target: "/"}]})
        )

      assert %{
               mounts: [
                 %{target: ["must be an absolute path in the container"]},
                 %{target: ["can't be the container's root"]}
               ]
             } =
               errors_on(changeset)
    end

    test "no two mounts or volumes may share a container path" do
      changeset =
        Downloader.changeset(
          %Downloader{},
          downloader_attrs(%{output: %{source: "o", target: "/data"}, volumes: [%{name: "cache", target: "/data"}]})
        )

      assert %{mounts: ["/data is mounted more than once"]} = errors_on(changeset)
    end

    test "volume names follow Docker's rule" do
      changeset =
        Downloader.changeset(%Downloader{}, downloader_attrs(%{volumes: [%{name: "has space", target: "/v"}]}))

      assert %{volumes: [%{name: [_message]}]} = errors_on(changeset)
    end

    test "a file's name is a single name in an absolute directory" do
      for {file, field} <- [
            {%{name: "a/b", directory: "/etc"}, :name},
            {%{name: "..", directory: "/etc"}, :name},
            {%{name: "config", directory: "etc"}, :directory}
          ] do
        changeset = Downloader.changeset(%Downloader{}, downloader_attrs(%{files: [file]}))
        assert %{files: [errors]} = errors_on(changeset)
        assert Map.has_key?(errors, field), "accepted #{inspect(file)}"
      end
    end

    test "a file can't go inside a mount or volume, where it would land outside the container" do
      changeset =
        Downloader.changeset(
          %Downloader{},
          downloader_attrs(%{output: %{source: "o", target: "/out"}, files: [%{name: "x", directory: "/out/sub"}]})
        )

      assert %{files: ["/out/sub/x is inside the mount at /out; files go in the container itself"]} =
               errors_on(changeset)
    end

    test "blank mount and volume rows don't clash with each other or with files" do
      attrs =
        downloader_attrs(%{
          mounts: [%{source: "", target: ""}, %{source: "", target: ""}],
          volumes: [%{name: "", target: ""}],
          files: [%{name: "x", directory: "/etc"}]
        })

      errors = errors_on(Downloader.changeset(%Downloader{}, attrs))
      refute Enum.any?(Map.get(errors, :mounts, []), &is_binary/1)
      refute Map.has_key?(errors, :files)
    end

    test "two files can't share a path" do
      files = [%{name: "config", directory: "/config/"}, %{name: "config", directory: "/config"}]
      changeset = Downloader.changeset(%Downloader{}, downloader_attrs(%{files: files}))

      assert %{files: ["/config/config is used by more than one file"]} = errors_on(changeset)
    end

    test "edits mounts by sort and drop params, as the form sends them" do
      downloader = downloader_fixture(%{mounts: [%{source: "a", target: "/a"}, %{source: "b", target: "/b"}]})

      changeset =
        Downloader.changeset(downloader, %{
          "mounts" => %{"0" => %{"source" => "a", "target" => "/a"}, "1" => %{"source" => "b", "target" => "/b"}},
          "mounts_sort" => ["1", "0", "new"],
          "mounts_drop" => ["0"]
        })

      assert [%{source: "b"}, %{source: nil}] = Ecto.Changeset.get_field(changeset, :mounts)
    end
  end

  describe "match/1" do
    test "picks the highest-priority enabled downloader whose pattern matches" do
      low = downloader_fixture(%{url_pattern: "^https://match\\.test/", priority: 1_000_001})
      high = downloader_fixture(%{url_pattern: "^https://match\\.test/videos/", priority: 1_000_002})
      _disabled = downloader_fixture(%{url_pattern: "^https://match\\.test/", priority: 1_000_003, enabled: false})

      assert Downloaders.match("https://match.test/videos/1").id == high.id
      assert Downloaders.match("https://match.test/other").id == low.id
    end

    test "never picks an arguments downloader, even one that had a pattern" do
      %{id: id} = downloader = downloader_fixture(%{url_pattern: "^https://args\\.test/", priority: 1_000_004})
      {:ok, _arguments} = Downloaders.update_downloader(downloader, %{input: :arguments})

      refute match?(%{id: ^id}, Downloaders.match("https://args.test/x"))
    end

    # The defaults come from their migration; these are the routes they're meant to take.
    test "the default downloaders send direct files to aria2c, gallery sites to gallery-dl, the rest to yt-dlp" do
      for {url, slug} <- [
            {"https://example.org/files/Thing.ZIP", "aria2c"},
            {"ftp://mirror.example/distro.iso?x=1", "aria2c"},
            {"https://imgur.com/gallery/abc", "gallery-dl"},
            {"https://commons.wikimedia.org/wiki/File:Example.jpg", "gallery-dl"},
            {"https://www.deviantart.com/someone", "gallery-dl"},
            {"https://www.youtube.com/watch?v=jNQXAC9IVRw", "yt-dlp"},
            {"https://notimgur.com/x", "yt-dlp"}
          ] do
        assert Downloaders.match(url).slug == slug, "#{url} didn't go to #{slug}"
      end
    end
  end

  describe "delete_downloader/1" do
    test "refuses while the downloader has downloads queued or running" do
      downloader = downloader_fixture()
      _queued = download_fixture(%{downloader_id: downloader.id})

      assert {:error, :in_use} = Downloaders.delete_downloader(downloader)
      assert Downloaders.get_downloader(downloader.id)
    end
  end

  test "host_path/1 resolves relative sources under the download directory" do
    {:ok, root} = Settings.download_dir()

    assert Downloaders.host_path("yt-dlp") == {:ok, Path.join(root, "yt-dlp")}
    assert Downloaders.host_path("/srv/media") == {:ok, "/srv/media"}
    assert Downloaders.host_path("~/media") == {:ok, Path.expand("~/media")}
  end

  test "every change is broadcast" do
    Downloaders.subscribe()
    downloader_fixture()
    assert_receive {:downloaders, :changed}
  end
end

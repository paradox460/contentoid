defmodule Contentoid.PostProcessorsTest do
  use Contentoid.DataCase, async: true

  import Contentoid.DownloadsFixtures

  alias Contentoid.Downloaders
  alias Contentoid.PostProcessors
  alias Contentoid.PostProcessors.PostProcessor

  test "a mount can't go under /contentoid, which Contentoid uses" do
    changeset =
      PostProcessor.changeset(%PostProcessor{}, %{
        name: "Move",
        image: "alpine",
        script: "true",
        mounts: [%{source: "/tmp", target: "/contentoid/x"}]
      })

    assert "/contentoid/x is inside /contentoid, which Contentoid uses" in errors_on(changeset).mounts
  end

  # What the form sends when its last row is removed: only the drop marker.
  test "a downloader's assignments are replaced by the form's, an empty list clearing them" do
    post_processor = post_processor_fixture()
    downloader = downloader_fixture(%{post_processor_assignments: assignments([{post_processor, "--into /a"}])})

    assert [%{post_processor_id: id, arguments: "--into /a"}] =
             Downloaders.get_downloader!(downloader.id).post_processor_assignments

    assert id == post_processor.id

    {:ok, _downloader} = Downloaders.update_downloader(downloader, %{"post_processor_assignments_drop" => [""]})
    assert Downloaders.get_downloader!(downloader.id).post_processor_assignments == []
  end

  test "without assignments in the attrs a downloader keeps its own" do
    post_processor = post_processor_fixture()
    downloader = downloader_fixture(%{post_processor_assignments: assignments([post_processor])})

    {:ok, _downloader} = Downloaders.update_downloader(downloader, %{"priority" => "3"})
    assert [_kept] = Downloaders.get_downloader!(downloader.id).post_processor_assignments
  end

  test "an assignment's arguments must split; blank ones are none" do
    post_processor = post_processor_fixture()

    assert {:error, changeset} =
             Downloaders.create_downloader(
               downloader_attrs(%{post_processor_assignments: assignments([{post_processor, ~s(--into "/a)}])})
             )

    assert %{post_processor_assignments: [%{arguments: ["have a quote that's never closed"]}]} = errors_on(changeset)

    downloader = downloader_fixture(%{post_processor_assignments: assignments([{post_processor, "   "}])})
    assert [%{arguments: nil}] = Downloaders.get_downloader!(downloader.id).post_processor_assignments
  end

  describe "an assignment's mounts" do
    setup do
      %{post_processor: post_processor_fixture(%{mounts: [%{source: "/srv/library", target: "/library"}]})}
    end

    test "are kept with it", %{post_processor: post_processor} do
      mount = %{source: "/srv/films", target: "/dest", read_only: false}
      downloader = downloader_fixture(%{post_processor_assignments: assignments([{post_processor, nil, [mount]}])})

      assert [%{mounts: [%{source: "/srv/films", target: "/dest", read_only: false}]}] =
               Downloaders.get_downloader!(downloader.id).post_processor_assignments
    end

    test "can't clash with Contentoid's or the post-processor's, or cover its files", %{post_processor: post_processor} do
      {:ok, with_file} =
        PostProcessors.update_post_processor(post_processor, %{
          files: [%{name: "config", directory: "/etc/tool", contents: "x"}]
        })

      for {target, message} <- [
            {"/contentoid/output", "/contentoid/output is inside /contentoid, which Contentoid uses"},
            {"/library", "/library is mounted by the post-processor already"},
            {"/etc", "would cover the post-processor's file /etc/tool/config"}
          ] do
        attrs =
          downloader_attrs(%{
            post_processor_assignments: assignments([{with_file, nil, [%{source: "/srv/x", target: target}]}])
          })

        assert {:error, changeset} = Downloaders.create_downloader(attrs)
        assert %{post_processor_assignments: [%{mounts: [^message]}]} = errors_on(changeset), target
      end
    end
  end

  test "an assignment's priority replaces its post-processor's in the run order" do
    low = post_processor_fixture(%{name: "Low", priority: 1})
    high = post_processor_fixture(%{name: "High", priority: 5})
    downloader = downloader_fixture(%{post_processor_assignments: assignments([low, high])})
    download = download_fixture(%{downloader_id: downloader.id})

    assert Enum.map(PostProcessors.for_download(download), & &1.post_processor.name) == ["High", "Low"]

    [first, second] = Downloaders.get_downloader!(downloader.id).post_processor_assignments

    {:ok, _downloader} =
      Downloaders.update_downloader(downloader, %{
        "post_processor_assignments" => %{
          "0" => %{"id" => first.id, "post_processor_id" => low.id, "priority" => "10"},
          "1" => %{"id" => second.id, "post_processor_id" => high.id, "priority" => ""}
        }
      })

    assert Enum.map(PostProcessors.for_download(download), & &1.post_processor.name) == ["Low", "High"]
  end
end

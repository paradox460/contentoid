defmodule ContentoidWeb.DownloadersLiveTest do
  # Docker is `Contentoid.FakeDocker`, shared with the LiveView process; hence not async.
  use ContentoidWeb.ConnCase, async: false

  import Contentoid.DownloadsFixtures
  import Phoenix.LiveViewTest

  alias Contentoid.Downloaders
  alias Contentoid.FakeDocker

  setup do
    Req.Test.set_req_test_to_shared()
    FakeDocker.start(image?: false)
    :ok
  end

  describe "the list" do
    test "shows every downloader and marks images not pulled yet", %{conn: conn} do
      downloader = downloader_fixture(%{name: "Listed"})
      {:ok, view, _html} = live(conn, ~p"/downloaders")

      assert has_element?(view, "#downloaders-#{downloader.id}", "Listed")
      assert has_element?(view, "#downloaders-#{downloader.id} .container-image--missing", "fake/downloader:1")
      # The default downloaders.
      assert has_element?(view, "#downloaders", "yt-dlp")
    end

    test "switches a downloader off and on", %{conn: conn} do
      downloader = downloader_fixture()
      {:ok, view, _html} = live(conn, ~p"/downloaders")

      view |> element("#downloaders-#{downloader.id} button", "On") |> render_click()
      refute Downloaders.get_downloader!(downloader.id).enabled
      assert has_element?(view, "#downloaders-#{downloader.id} button", "Off")

      view |> element("#downloaders-#{downloader.id} button", "Off") |> render_click()
      assert Downloaders.get_downloader!(downloader.id).enabled
      assert has_element?(view, "#downloaders-#{downloader.id} button", "On")
    end

    test "deletes a downloader, but not one with downloads in flight", %{conn: conn} do
      idle = downloader_fixture()
      busy = downloader_fixture()
      download_fixture(%{downloader_id: busy.id})
      {:ok, view, _html} = live(conn, ~p"/downloaders")

      view |> element("#downloaders-#{busy.id} button", "Delete") |> render_click()
      assert render(view) =~ "It has downloads queued or running"
      assert Downloaders.get_downloader(busy.id)

      view |> element("#downloaders-#{idle.id} button", "Delete") |> render_click()
      refute has_element?(view, "#downloaders-#{idle.id}")
      refute Downloaders.get_downloader(idle.id)
    end
  end

  describe "the form" do
    test "creates a downloader, with the slug following the name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloaders/new")

      view |> form("#downloader-form", downloader: %{name: "Bandcamp Albums"}) |> render_change()
      assert has_element?(view, ~s(input[name="downloader[slug]"][value="bandcamp-albums"]))

      {:ok, _view, html} =
        view
        |> form("#downloader-form",
          downloader: %{
            name: "Bandcamp Albums",
            url_pattern: "^https://[^/]+\\.bandcamp\\.com/",
            image: "example/bandcamp:1",
            script: "exec bandcamp-dl \"$CONTENTOID_URL\"",
            output: %{source: "bandcamp", target: "/music"},
            # Above the default yt-dlp catch-all.
            priority: 50
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/downloaders")

      assert html =~ "Saved Bandcamp Albums."

      assert %{slug: "bandcamp-albums", output: %{source: "bandcamp", target: "/music"}} =
               Downloaders.match("https://x.bandcamp.com/a")
    end

    test "an arguments downloader has no pattern to fill in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloaders/new")
      assert has_element?(view, ~s(input[name="downloader[url_pattern]"]))

      view |> form("#downloader-form", downloader: %{input: "arguments"}) |> render_change()
      refute has_element?(view, ~s(input[name="downloader[url_pattern]"]))

      {:ok, _view, _html} =
        view
        |> form("#downloader-form",
          downloader: %{
            name: "Subscriptions",
            input: "arguments",
            image: "example/subs:1",
            script: "exec subs \"$@\"",
            output: %{source: "subs", target: "/out"}
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/downloaders")

      assert [%{input: :arguments, url_pattern: nil}] =
               Enum.filter(Downloaders.list_downloaders(), &(&1.name == "Subscriptions"))
    end

    test "a slug typed in stays, whatever the name becomes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloaders/new")

      render_change(view, "validate", %{
        "_target" => ["downloader", "slug"],
        "downloader" => %{"name" => "A", "slug" => "mine"}
      })

      render_change(view, "validate", %{
        "_target" => ["downloader", "name"],
        "downloader" => %{"name" => "Something else", "slug" => "mine"}
      })

      assert has_element?(view, ~s(input[name="downloader[slug]"][value="mine"]))
    end

    test "adds a file with its contents and keeps it", %{conn: conn} do
      downloader = downloader_fixture()
      {:ok, view, _html} = live(conn, ~p"/downloaders/#{downloader}/edit")

      view |> form("#downloader-form") |> render_change(%{downloader: %{files_sort: ["new"]}})
      assert has_element?(view, ~s(textarea[name="downloader[files][0][contents]"]))

      view
      |> form("#downloader-form",
        downloader: %{files: %{"0" => %{name: "config", directory: "/config/yt-dlp", contents: "--no-mtime"}}}
      )
      |> render_submit()

      assert [%{name: "config", directory: "/config/yt-dlp", contents: "--no-mtime"}] =
               Downloaders.get_downloader!(downloader.id).files
    end

    test "adds and removes mount and volume rows", %{conn: conn} do
      downloader = downloader_fixture(%{mounts: [%{source: "a", target: "/a"}]})
      {:ok, view, _html} = live(conn, ~p"/downloaders/#{downloader}/edit")

      # The buttons dispatch a change carrying their sort/drop value; send that change directly.
      view |> form("#downloader-form") |> render_change(%{downloader: %{volumes_sort: ["new"]}})
      assert has_element?(view, ~s(input[name="downloader[volumes][0][name]"]))

      view |> form("#downloader-form") |> render_change(%{downloader: %{mounts_drop: ["0"]}})
      refute has_element?(view, ~s(input[name="downloader[mounts][0][source]"]))
    end

    test "checks a URL against the pattern being edited", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloaders/new")

      render_change(view, "validate", %{
        "downloader" => %{"url_pattern" => "^https://a\\.test/"},
        "try_url" => "https://a.test/x"
      })

      assert has_element?(view, "#try-result", "Matches")

      render_change(view, "validate", %{
        "downloader" => %{"url_pattern" => "^https://b\\.test/"},
        "try_url" => "https://a.test/x"
      })

      assert has_element?(view, "#try-result", "Doesn't match")

      render_change(view, "validate", %{
        "downloader" => %{"url_pattern" => "(unclosed"},
        "try_url" => "https://a.test/x"
      })

      assert has_element?(view, "#try-result", "Pattern doesn't compile")
    end

    test "shows what's wrong and saves nothing", %{conn: conn} do
      downloader = downloader_fixture()
      {:ok, view, _html} = live(conn, ~p"/downloaders/#{downloader}/edit")

      html = view |> form("#downloader-form", downloader: %{url_pattern: "(unclosed"}) |> render_submit()

      assert html =~ "isn&#39;t a valid regex"
      assert Downloaders.get_downloader!(downloader.id).url_pattern == downloader.url_pattern
    end
  end

  test "assigns a post-processor twice with different arguments, then removes one", %{conn: conn} do
    post_processor = post_processor_fixture(%{name: "Move to library"})
    downloader = downloader_fixture()
    {:ok, view, _html} = live(conn, ~p"/downloaders/#{downloader}/edit")

    # What "Add post-processor" sends, twice.
    for _row <- 1..2 do
      view |> element("#downloader-form") |> render_change(%{downloader: %{post_processor_assignments_sort: ["new"]}})
    end

    assert has_element?(view, ~s(#downloader-post-processors option[value="#{post_processor.id}"]), "Move to library")

    view
    |> form("#downloader-form",
      downloader: %{
        post_processor_assignments: %{
          "0" => %{post_processor_id: post_processor.id, arguments: "/library/films"},
          "1" => %{post_processor_id: post_processor.id, arguments: ~s("/library/tv shows")}
        }
      }
    )
    |> render_submit()

    # Not followed: a mounted index would ask the fake Docker about images after the test ends.
    assert_redirect(view, ~p"/downloaders")

    assert [%{arguments: "/library/films"}, %{arguments: ~s("/library/tv shows")}] =
             Downloaders.get_downloader!(downloader.id).post_processor_assignments

    # Removing the first row ("x") keeps the other.
    {:ok, view, _html} = live(conn, ~p"/downloaders/#{downloader}/edit")
    view |> element("#downloader-form") |> render_change(%{downloader: %{post_processor_assignments_drop: ["0"]}})
    view |> form("#downloader-form") |> render_submit()
    assert_redirect(view, ~p"/downloaders")

    assert [%{arguments: ~s("/library/tv shows")}] =
             Downloaders.get_downloader!(downloader.id).post_processor_assignments
  end
end

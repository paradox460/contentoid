defmodule ContentoidWeb.PostProcessorsLiveTest do
  # Docker is `Contentoid.FakeDocker`, shared with the LiveView process; hence not async.
  use ContentoidWeb.ConnCase, async: false

  import Contentoid.DownloadsFixtures
  import Phoenix.LiveViewTest

  alias Contentoid.FakeDocker
  alias Contentoid.PostProcessors

  setup do
    Req.Test.set_req_test_to_shared()
    FakeDocker.start(image?: false)
    :ok
  end

  test "creates a post-processor and lists it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/post-processors/new")

    {:ok, view, html} =
      view
      |> form("#post-processor-form",
        post_processor: %{name: "Move to library", image: "alpine:3.20", priority: 5, trigger: "always"}
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/post-processors")

    assert html =~ "Saved Move to library."
    assert [%{name: "Move to library", trigger: :always} = post_processor] = PostProcessors.list_post_processors()
    assert has_element?(view, "#post-processors-#{post_processor.id}", "After every download")
    assert has_element?(view, ~s(#app-nav a[href="/post-processors"][aria-current="page"]))
  end

  test "switches a post-processor off", %{conn: conn} do
    post_processor = post_processor_fixture()
    {:ok, view, _html} = live(conn, ~p"/post-processors")

    view |> element("#post-processors-#{post_processor.id} button", "On") |> render_click()
    refute PostProcessors.get_post_processor!(post_processor.id).enabled
    assert has_element?(view, "#post-processors-#{post_processor.id} button", "Off")
  end
end

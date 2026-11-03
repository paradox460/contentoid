defmodule ContentoidWeb.DownloadedLiveTest do
  use ContentoidWeb.ConnCase, async: true

  import Contentoid.DownloadsFixtures
  import Phoenix.LiveViewTest

  alias Contentoid.Downloads

  test "lists what was downloaded, newest first, searchable by URL, and adds new files live", %{conn: conn} do
    download = download_fixture()
    Downloads.record_item(download, "https://videos.test/watch?v=old", "/lib/old.mp4")
    Downloads.record_item(download, "https://images.test/a.jpg", "/lib/a.jpg")

    {:ok, view, _html} = live(conn, ~p"/downloaded")
    assert has_element?(view, "#items", "https://videos.test/watch?v=old")
    assert has_element?(view, "#items", "/lib/a.jpg")

    view |> form("#downloaded-search", search: "VIDEOS.test") |> render_change()
    assert has_element?(view, "#items", "watch?v=old")
    refute has_element?(view, "#items", "a.jpg")

    # Only new files matching the search appear.
    Downloads.record_item(download, "https://videos.test/watch?v=new", "/lib/new.mp4")
    Downloads.record_item(download, "https://images.test/b.jpg", "/lib/b.jpg")
    assert has_element?(view, "#items", "watch?v=new")
    refute has_element?(view, "#items", "b.jpg")
  end

  test "a search with LIKE wildcards matches them literally", %{conn: conn} do
    download = download_fixture()
    Downloads.record_item(download, "https://x.test/100%_real", "/lib/a")
    Downloads.record_item(download, "https://x.test/100abc", "/lib/b")

    {:ok, view, _html} = live(conn, ~p"/downloaded")
    view |> form("#downloaded-search", search: "100%_") |> render_change()

    assert has_element?(view, "#items", "100%_real")
    refute has_element?(view, "#items", "100abc")
  end

  test "a deleted download's files leave the list", %{conn: conn} do
    failed = failed_download_fixture()
    Downloads.record_item(failed, "https://x.test/gone", "/lib/gone")
    Downloads.record_item(download_fixture(), "https://x.test/kept", "/lib/kept")
    {:ok, view, _html} = live(conn, ~p"/downloaded")

    {:ok, _deleted} = Downloads.delete_download(failed)

    refute has_element?(view, "#items", "x.test/gone")
    assert has_element?(view, "#items", "x.test/kept")
  end

  test "Remove deletes only that record", %{conn: conn} do
    download = download_fixture()
    gone = Downloads.record_item(download, "https://x.test/gone", "/lib/gone")
    kept = Downloads.record_item(download, "https://x.test/kept", "/lib/kept")
    {:ok, view, _html} = live(conn, ~p"/downloaded")

    view |> element("#items-#{gone.id} button", "Remove") |> render_click()

    refute has_element?(view, "#items-#{gone.id}")
    assert has_element?(view, "#items-#{kept.id}")
    assert Enum.map(Downloads.list_items(), & &1.id) == [kept.id]
  end

  test "Clear matching deletes the records the search shows", %{conn: conn} do
    download = download_fixture()
    Downloads.record_item(download, "https://videos.test/a", "/lib/a.mp4")
    Downloads.record_item(download, "https://videos.test/b", "/lib/b.mp4")
    image = Downloads.record_item(download, "https://images.test/c.jpg", "/lib/c.jpg")
    {:ok, view, _html} = live(conn, ~p"/downloaded")
    assert has_element?(view, "#clear-downloaded", "Clear all")

    view |> form("#downloaded-search", search: "videos") |> render_change()
    assert has_element?(view, "#clear-downloaded", "Clear matching")
    assert view |> element("#clear-downloaded") |> render_click() =~ "Cleared 2 records."

    refute has_element?(view, "#clear-downloaded")
    assert Enum.map(Downloads.list_items(), & &1.id) == [image.id]
  end
end

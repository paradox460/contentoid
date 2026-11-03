defmodule ContentoidWeb.SettingsLiveTest do
  # Saving a changed download limit would reach the app-wide `Contentoid.Downloads.Slots`; not async.
  use ContentoidWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contentoid.Settings

  test "is the current navigation item", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, ~s(#app-nav a[href="/settings"][aria-current="page"]), "Settings")
  end

  test "saves, then shows the directory in use", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_submit(element(view, "#settings-form"), %{setting: %{download_dir: "/srv/contentoid", log_lines: "50"}})

    assert %{download_dir: "/srv/contentoid", log_lines: 50} = Settings.get_settings()
    assert has_element?(view, "#download-dir-status", "/srv/contentoid")
  end

  test "shows errors as values are edited", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_change(element(view, "#settings-form"), %{setting: %{stop_grace_seconds: "31"}})

    assert has_element?(view, "#settings-form", "must be less than or equal to 30")
  end
end

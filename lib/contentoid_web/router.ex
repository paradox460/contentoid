defmodule ContentoidWeb.Router do
  use ContentoidWeb, :router

  alias Localize.Plug.PutLocale
  alias Localize.Plug.PutSession

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    # The browser's language, never a saved one: there's no switcher, so the session only carries
    # the locale to LiveViews (`ContentoidWeb.Locale.on_mount/4`).
    plug PutLocale, from: [:accept_language], gettext: ContentoidWeb.Gettext
    plug PutSession
    plug :fetch_live_flash
    plug :put_root_layout, html: {ContentoidWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ContentoidWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/downloads", DownloadsLive, :index
    live "/downloads/:id", DownloadsLive, :show
    live "/downloaded", DownloadedLive, :index
    live "/downloaders", DownloadersLive.Index, :index
    live "/downloaders/new", DownloadersLive.Form, :new
    live "/downloaders/:id/edit", DownloadersLive.Form, :edit
    live "/schedules", SchedulesLive.Index, :index
    live "/schedules/new", SchedulesLive.Form, :new
    live "/schedules/:id/edit", SchedulesLive.Form, :edit
    live "/post-processors", PostProcessorsLive.Index, :index
    live "/post-processors/new", PostProcessorsLive.Form, :new
    live "/post-processors/:id/edit", PostProcessorsLive.Form, :edit
    live "/settings", SettingsLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", ContentoidWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:contentoid, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ContentoidWeb.Telemetry
    end
  end
end

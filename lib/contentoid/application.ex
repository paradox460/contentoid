defmodule Contentoid.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Contentoid.Downloads.Janitor
  alias Contentoid.Downloads.Queues
  alias Contentoid.Downloads.Slots
  alias Contentoid.Downloads.TaskSupervisor

  @impl true
  def start(_type, _args) do
    children = [
      ContentoidWeb.Telemetry,
      Contentoid.Repo,
      {DNSCluster, query: Application.get_env(:contentoid, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Contentoid.PubSub},
      # The runners' container watchdogs (`Contentoid.Downloads.Runner`).
      {Task.Supervisor, name: TaskSupervisor},
      # The global download limit, which workers wait on.
      Slots,
      # Before Oban, so it starts first and stops last: at boot it removes leftover containers and
      # requeues the downloads a restart interrupted; at shutdown it removes the containers of the
      # jobs Oban just stopped.
      Janitor,
      {Oban, Application.fetch_env!(:contentoid, Oban)},
      # Every downloader has its own queue, started at runtime once Oban is up.
      Supervisor.child_spec({Task, &Queues.start_all/0}, id: Queues, restart: :temporary),
      # Start to serve requests, typically the last entry
      ContentoidWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Contentoid.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ContentoidWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

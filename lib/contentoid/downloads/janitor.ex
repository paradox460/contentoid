defmodule Contentoid.Downloads.Janitor do
  @moduledoc """
  Keeps download containers from outliving Contentoid.

  At boot it removes containers the previous run left behind (a crash leaves them running), then
  requeues the downloads they belonged to (`Contentoid.Downloads.recover_interrupted/0`). It does
  this in `init/1`, so it finishes before the next child starts: it must sit after the Repo and
  before Oban, whose queues would otherwise pick up fresh jobs that this would mistake for
  interrupted ones.

  Sitting before Oban also means it stops after Oban: when Contentoid shuts down, Oban has already
  stopped every job, and this removes the containers they leave behind (`Contentoid.Downloads.Docker`
  containers don't stop with their runner). Their downloads stay `running` for the next boot to
  requeue; the downloaders resume from their partial files.

  The tests turn it off (`config :contentoid, Contentoid.Downloads.Janitor, enabled: false`): they
  call `Contentoid.Downloads.recover_interrupted/0` themselves, against a fake Docker.
  """
  # Shutdown removes containers with Settings' `stop_grace_seconds` (at most 30) plus Docker call
  # timeouts (`Contentoid.Downloads.Docker.remove_all/0`), which must fit inside this.
  use GenServer, shutdown: 60_000

  alias Contentoid.Downloads
  alias Contentoid.Downloads.Docker

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Keyword.get(Application.get_env(:contentoid, __MODULE__, []), :enabled, true) do
      # Trapping exits is what gets `terminate/2` called at shutdown.
      Process.flag(:trap_exit, true)
      remove_containers("left by the last run")
      requeue_interrupted()
      {:ok, nil}
    else
      :ignore
    end
  end

  @impl true
  def terminate(_reason, _state), do: remove_containers("at shutdown")

  defp remove_containers(context) do
    case Docker.remove_all() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("Removed #{count} download container(s) #{context}")
      {:error, message} -> Logger.warning("Couldn't remove download containers #{context}: #{message}")
    end
  end

  defp requeue_interrupted do
    case Downloads.recover_interrupted() do
      {:ok, %{downloads: 0}} -> :ok
      {:ok, %{downloads: count}} -> Logger.info("Requeued #{count} download(s) interrupted by a restart")
    end
  end
end

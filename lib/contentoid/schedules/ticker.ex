defmodule Contentoid.Schedules.Ticker do
  @moduledoc """
  Runs the schedules that are due (`Contentoid.Schedules.run_due/1`). Oban's cron plugin starts it
  every minute (`config/config.exs`), in the one-slot `scheduler` queue, so ticks never overlap.
  """
  use Oban.Worker, queue: :scheduler, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Contentoid.Schedules.run_due()
    :ok
  end
end

defmodule Contentoid.Downloads.Runner.Writer do
  @moduledoc false
  # Writes a running container's progress, files and log to its download
  # (`Contentoid.Downloads.record_progress/2`) at most every @interval ms, always ending on the
  # latest. The runner can't do this itself: while a container runs it's blocked reading the log
  # stream, so it can only act when output arrives, and a timer for the last update before a quiet
  # stretch would never fire. One writer per container run, linked to the runner and stopped by it
  # (`stop/1` writes what's pending first) before it moves on.

  use GenServer

  alias Contentoid.Downloads
  alias Contentoid.Downloads.Runner

  @interval 500

  def start_link(download), do: GenServer.start_link(__MODULE__, download)

  @doc false
  # The runner's latest `Runner.Output`; written now, or when the interval is up.
  def update(writer, output), do: GenServer.cast(writer, {:update, output})

  @doc false
  # Writes what's pending, then stops.
  def stop(writer), do: GenServer.call(writer, :stop)

  @impl true
  def init(download), do: {:ok, %{download: download, pending: nil, written_at: nil, timer: nil}}

  @impl true
  def handle_cast({:update, output}, state) do
    state = %{state | pending: output}
    now = System.monotonic_time(:millisecond)

    cond do
      state.timer ->
        {:noreply, state}

      state.written_at == nil or now - state.written_at >= @interval ->
        {:noreply, write(state)}

      true ->
        {:noreply, %{state | timer: Process.send_after(self(), :write, @interval - (now - state.written_at))}}
    end
  end

  @impl true
  def handle_info(:write, state), do: {:noreply, write(%{state | timer: nil})}

  @impl true
  def handle_call(:stop, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:stop, :normal, :ok, write(%{state | timer: nil})}
  end

  defp write(%{pending: nil} = state), do: state

  defp write(state) do
    Downloads.record_progress(state.download, Runner.live_changes(state.pending))
    %{state | pending: nil, written_at: System.monotonic_time(:millisecond)}
  end
end

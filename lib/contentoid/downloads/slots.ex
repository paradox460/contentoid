defmodule Contentoid.Downloads.Slots do
  @moduledoc """
  The gate every download passes before it runs. A waiter gets a slot when all three limits allow:

    * the global limit, `max_concurrent_downloads` downloads at once across all downloaders
      (`Contentoid.Settings`, default 4), so together they can't saturate the network link or the disk;
    * its downloader's `concurrency`, given with each waiter and kept up to date by
      `set_concurrency/2` (`Contentoid.Downloaders`);
    * the pause (`set_paused/1`, `Contentoid.Downloads.pause_queue/0`): while paused nothing is handed
      out, even with free slots.

  A worker takes a slot with `acquire/1`, which waits until it may start, and gives it back with
  `release/0`. Waiters are served in line order, the downloads' `position`
  (`Contentoid.Downloads.line_order/1`); a waiter whose downloader is at its concurrency is skipped,
  so those behind it may still start. A holder is never asked to give its slot up: neither a pause,
  a lowered limit nor a lowered concurrency stops anything running, they only hold new takers. A slot
  is also given back when its holder dies (a cancelled job is killed), and a waiter that dies leaves
  the line.
  """
  use GenServer

  alias Contentoid.Settings

  @type waiter :: %{download_id: term(), downloader_id: term(), concurrency: pos_integer()}

  @doc """
  Options: `limit` and `paused` (defaults from Settings), `order` (a function from waiting download
  ids to the same ids in serving order; default `Contentoid.Downloads.line_order/1`), `name`
  (default `#{inspect(__MODULE__)}`; nil for none).
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Waits until `waiter` may start, then takes a slot for the calling process."
  @spec acquire(waiter()) :: :ok
  def acquire(%{download_id: _, downloader_id: _, concurrency: _} = waiter),
    do: GenServer.call(__MODULE__, {:acquire, waiter}, :infinity)

  @doc "Gives back the calling process's slot."
  @spec release() :: :ok
  def release, do: GenServer.call(__MODULE__, :release)

  @doc "The limit, how many slots are taken, how many processes are waiting and whether it's paused."
  @spec info() :: %{limit: pos_integer(), taken: non_neg_integer(), waiting: non_neg_integer(), paused: boolean()}
  def info, do: GenServer.call(__MODULE__, :info)

  @doc "Changes the global limit."
  @spec set_limit(pos_integer()) :: :ok
  def set_limit(limit) when is_integer(limit) and limit > 0, do: GenServer.call(__MODULE__, {:set_limit, limit})

  @doc "Pauses (nothing new starts) or resumes handing out slots."
  @spec set_paused(boolean()) :: :ok
  def set_paused(paused) when is_boolean(paused), do: GenServer.call(__MODULE__, {:set_paused, paused})

  @doc "Changes how many of a downloader's downloads may hold a slot at once."
  @spec set_concurrency(term(), pos_integer()) :: :ok
  def set_concurrency(downloader_id, concurrency) when is_integer(concurrency) and concurrency > 0,
    do: GenServer.call(__MODULE__, {:set_concurrency, downloader_id, concurrency})

  @impl true
  def init(opts) do
    limit = Keyword.get_lazy(opts, :limit, fn -> Settings.get_settings().max_concurrent_downloads end)
    paused = Keyword.get_lazy(opts, :paused, fn -> Settings.get_settings().queue_paused end)
    order = Keyword.get(opts, :order, &Contentoid.Downloads.line_order/1)

    # `holders`: pid => downloader id. `waiting`: in arrival order.
    {:ok, %{limit: limit, paused: paused, order: order, holders: %{}, waiting: [], refs: %{}, concurrency: %{}}}
  end

  @impl true
  def handle_call({:acquire, waiter}, {pid, _tag} = from, state) do
    entry = %{download_id: waiter.download_id, downloader_id: waiter.downloader_id, from: from}

    state =
      state
      |> monitor(pid)
      |> Map.update!(:concurrency, &Map.put(&1, waiter.downloader_id, waiter.concurrency))
      |> Map.update!(:waiting, &(&1 ++ [entry]))

    {:noreply, grant(state)}
  end

  def handle_call(:release, {pid, _tag}, state) do
    {:reply, :ok, state |> forget(pid) |> grant()}
  end

  def handle_call(:info, _from, state) do
    info = %{limit: state.limit, taken: map_size(state.holders), waiting: length(state.waiting), paused: state.paused}
    {:reply, info, state}
  end

  def handle_call({:set_limit, limit}, _from, state) do
    {:reply, :ok, grant(%{state | limit: limit})}
  end

  def handle_call({:set_paused, paused}, _from, state) do
    {:reply, :ok, grant(%{state | paused: paused})}
  end

  def handle_call({:set_concurrency, downloader_id, concurrency}, _from, state) do
    {:reply, :ok, grant(%{state | concurrency: Map.put(state.concurrency, downloader_id, concurrency)})}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, state |> forget(pid) |> grant()}
  end

  defp monitor(state, pid) do
    if Map.has_key?(state.refs, pid), do: state, else: %{state | refs: Map.put(state.refs, pid, Process.monitor(pid))}
  end

  # Drops `pid` as a holder and from the line.
  defp forget(state, pid) do
    {ref, refs} = Map.pop(state.refs, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    waiting = Enum.reject(state.waiting, fn %{from: {waiter, _tag}} -> waiter == pid end)
    %{state | holders: Map.delete(state.holders, pid), waiting: waiting, refs: refs}
  end

  # Hands free slots down the line, skipping waiters whose downloader is at its concurrency.
  defp grant(%{paused: true} = state), do: state
  defp grant(%{waiting: []} = state), do: state
  defp grant(state) when map_size(state.holders) >= state.limit, do: state
  defp grant(state), do: state |> in_line() |> Enum.reduce(state, &grant_one/2)

  defp grant_one(_waiter, state) when map_size(state.holders) >= state.limit, do: state

  defp grant_one(%{downloader_id: downloader_id, from: {pid, _tag} = from} = waiter, state) do
    held = Enum.count(state.holders, fn {_pid, holding} -> holding == downloader_id end)

    if held < Map.get(state.concurrency, downloader_id, 1) do
      GenServer.reply(from, :ok)
      %{state | holders: Map.put(state.holders, pid, downloader_id), waiting: List.delete(state.waiting, waiter)}
    else
      state
    end
  end

  # The waiters in serving order; those `order` leaves out go last, in arrival order.
  defp in_line(%{waiting: [_only] = waiting}), do: waiting

  defp in_line(%{waiting: waiting, order: order}) do
    rank = waiting |> Enum.map(& &1.download_id) |> order.() |> Enum.with_index() |> Map.new()
    # Stable, and any number sorts before `:last`.
    Enum.sort_by(waiting, &Map.get(rank, &1.download_id, :last))
  end
end

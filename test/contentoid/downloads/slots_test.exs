defmodule Contentoid.Downloads.SlotsTest do
  use ExUnit.Case, async: true

  alias Contentoid.Downloads.Slots

  # Serving order by tag; tags not listed go last, in arrival order.
  @ranks %{urgent: 0, normal: 1, normal_later: 2, low: 3}

  setup do
    %{slots: start_supervised!({Slots, limit: 2, paused: false, order: &order/1, name: nil})}
  end

  test "hands out at most the limit, then serves waiters first come first served", %{slots: slots} do
    [holder, _other] = for _ <- 1..2, do: take(slots)
    wait(slots, :first)
    wait(slots, :second)

    assert %{taken: 2, waiting: 2} = info(slots)

    send(holder, :release)
    assert_receive {:granted, :first}
    refute_receive {:granted, :second}, 50
  end

  test "serves waiters in the order `order` gives, without taking a slot from any holder", %{slots: slots} do
    [first_holder, second_holder] = for _ <- 1..2, do: take(slots)
    wait(slots, :low)
    normal = wait(slots, :normal)
    urgent = wait(slots, :urgent)
    wait(slots, :normal_later)

    # Arriving later doesn't take a slot from anyone.
    refute_receive {:granted, _tag}, 50

    for {release, next} <- [
          {first_holder, :urgent},
          {second_holder, :normal},
          {urgent, :normal_later},
          {normal, :low}
        ] do
      send(release, :release)
      assert_receive {:granted, ^next}
    end
  end

  test "a holder that dies gives its slot back", %{slots: slots} do
    [holder, _other] = for _ <- 1..2, do: take(slots)
    wait(slots, :next)

    Process.exit(holder, :kill)
    assert_receive {:granted, :next}
  end

  test "a waiter that dies leaves the line", %{slots: slots} do
    [holder, _other] = for _ <- 1..2, do: take(slots)
    gone = wait(slots, :gone)
    wait(slots, :next)

    Process.exit(gone, :kill)
    send(holder, :release)

    assert_receive {:granted, :next}
    refute_received {:granted, :gone}
  end

  test "a raised limit lets waiters in; a lowered one holds new takers", %{slots: slots} do
    [holder, _other] = for _ <- 1..2, do: take(slots)
    wait(slots, :first)

    :ok = GenServer.call(slots, {:set_limit, 3})
    assert_receive {:granted, :first}

    :ok = GenServer.call(slots, {:set_limit, 1})
    send(holder, :release)
    until(fn -> info(slots).taken == 2 end)
    wait(slots, :next)
    refute_receive {:granted, :next}, 50
  end

  test "a waiter whose downloader is at its concurrency is skipped; the next one of another downloader starts",
       %{slots: slots} do
    take(slots, :a, 1)
    wait(slots, :urgent, :a, 1)
    wait(slots, :normal, :b, 1)

    assert_receive {:granted, :normal}
    refute_received {:granted, :urgent}
    assert %{taken: 2, waiting: 1} = info(slots)
  end

  test "paused hands out nothing, even with free slots, and stops no holder; resumed serves the line",
       %{slots: slots} do
    holder = take(slots)

    :ok = GenServer.call(slots, {:set_paused, true})
    wait(slots, :normal)
    wait(slots, :urgent)
    send(holder, :release)

    refute_receive {:granted, _tag}, 50
    assert %{taken: 0, waiting: 2, paused: true} = info(slots)

    :ok = GenServer.call(slots, {:set_paused, false})
    assert_receive {:granted, :urgent}
    assert_receive {:granted, :normal}
  end

  test "a raised concurrency lets that downloader's waiter in at once", %{slots: slots} do
    take(slots, :a, 1)
    wait(slots, :next, :a, 1)
    refute_receive {:granted, :next}, 50

    :ok = GenServer.call(slots, {:set_concurrency, :a, 2})
    assert_receive {:granted, :next}
  end

  defp order(ids), do: Enum.sort_by(ids, &Map.get(@ranks, &1, 100))

  # A process that takes a slot, reports it, and gives it back when sent `:release`.
  defp take(slots, downloader \\ :a, concurrency \\ 10) do
    pid = holder(slots, :held, downloader, concurrency)
    assert_receive {:granted, :held}
    pid
  end

  # A process waiting in line for a slot; reports `{:granted, tag}` when it gets one.
  defp wait(slots, tag, downloader \\ :a, concurrency \\ 10) do
    waiting = info(slots).waiting
    taken = info(slots).taken
    pid = holder(slots, tag, downloader, concurrency)

    until(fn ->
      %{waiting: w, taken: t} = info(slots)
      w + t == waiting + taken + 1
    end)

    pid
  end

  defp holder(slots, tag, downloader, concurrency) do
    test = self()

    spawn(fn ->
      waiter = %{download_id: tag, downloader_id: downloader, concurrency: concurrency}
      :ok = GenServer.call(slots, {:acquire, waiter}, :infinity)
      send(test, {:granted, tag})

      receive do
        :release -> GenServer.call(slots, :release)
      end

      Process.sleep(:infinity)
    end)
  end

  defp info(slots), do: GenServer.call(slots, :info)

  defp until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(5) && until(fun, attempts - 1)
    end
  end
end

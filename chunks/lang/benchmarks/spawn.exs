defmodule Counter do
  def start do
    spawn(fn -> loop(0) end)
  end

  defp loop(count) do
    receive do
      {:increment, from} ->
        send(from, count + 1)
        loop(count + 1)
    end
  end

  def increment(pid) do
    send(pid, {:increment, self()})
    receive do
      result -> result
    end
  end
end

{time, _} = :timer.tc(fn ->
  Enum.each(1..100, fn _ ->
    pid = Counter.start()
    Counter.increment(pid)
  end)
end)

IO.puts("100 actors, 100 sends (#{Float.round(time / 1000, 1)}ms)")

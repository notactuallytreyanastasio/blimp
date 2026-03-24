defmodule RingNode do
  def start do
    spawn(fn -> loop(0) end)
  end

  defp loop(hops) do
    receive do
      {:pass, token, from} ->
        send(from, token + 1)
        loop(hops + 1)
    end
  end

  def pass(pid, token) do
    send(pid, {:pass, token, self()})
    receive do
      result -> result
    end
  end
end

{time, total} = :timer.tc(fn ->
  nodes = Enum.map(1..10, fn _ -> RingNode.start() end)

  Enum.reduce(1..100, 0, fn _, acc ->
    Enum.reduce(nodes, acc, fn node, token ->
      RingNode.pass(node, token)
    end)
  end)
end)

IO.puts("#{total} (#{Float.round(time / 1000, 1)}ms)")

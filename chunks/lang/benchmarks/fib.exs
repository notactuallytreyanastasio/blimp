defmodule Fib do
  def fib(0), do: 0
  def fib(1), do: 1
  def fib(n), do: fib(n - 1) + fib(n - 2)
end

{time, result} = :timer.tc(fn -> Fib.fib(30) end)
IO.puts("#{result} (#{Float.round(time / 1000, 1)}ms)")

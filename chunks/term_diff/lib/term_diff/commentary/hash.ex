defmodule TermDiff.Commentary.Hash do
  @moduledoc "Pure SHA256 hashing for diff content staleness tracking."

  @spec hash_diff(String.t()) :: String.t()
  def hash_diff(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end

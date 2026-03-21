defmodule TermDiff.Commentary.Hash do
  @moduledoc "Pure SHA256 hashing for diff content staleness tracking."

  @spec hash_diff(String.t()) :: String.t()
  def hash_diff(content) do
    content
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

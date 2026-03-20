defmodule TermDiff.Commentary.HashTest do
  use ExUnit.Case, async: true

  alias TermDiff.Commentary.Hash

  describe "hash_diff/1" do
    test "returns a hex string" do
      hash = Hash.hash_diff("some diff content")
      assert is_binary(hash)
      assert Regex.match?(~r/^[a-f0-9]{64}$/, hash)
    end

    test "same input produces same hash" do
      assert Hash.hash_diff("hello") == Hash.hash_diff("hello")
    end

    test "different input produces different hash" do
      refute Hash.hash_diff("hello") == Hash.hash_diff("world")
    end

    test "empty string produces a valid hash" do
      hash = Hash.hash_diff("")
      assert Regex.match?(~r/^[a-f0-9]{64}$/, hash)
    end
  end
end

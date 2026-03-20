defmodule TermDiff.Commentary.PromptTest do
  use ExUnit.Case, async: true

  alias TermDiff.Commentary.Prompt

  describe "build/1" do
    test "returns a string containing the diff" do
      prompt = Prompt.build("diff --git a/foo.ex")
      assert prompt =~ "diff --git a/foo.ex"
    end

    test "includes JSON format instructions" do
      prompt = Prompt.build("some diff")
      assert prompt =~ "JSON"
      assert prompt =~ "summary"
      assert prompt =~ "annotations"
    end
  end
end

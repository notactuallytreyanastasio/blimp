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

  describe "json_schema/0" do
    test "returns valid JSON" do
      schema = Prompt.json_schema()
      assert {:ok, decoded} = Jason.decode(schema)
      assert decoded["type"] == "object"
      assert "summary" in decoded["required"]
      assert "annotations" in decoded["required"]
    end

    test "annotations schema has correct item properties" do
      {:ok, decoded} = Jason.decode(Prompt.json_schema())
      items = decoded["properties"]["annotations"]["items"]
      assert items["properties"]["file"]["type"] == "string"
      assert items["properties"]["start_line"]["type"] == "integer"
      assert items["properties"]["severity"]["enum"] == ["info", "warning", "issue"]
    end
  end
end

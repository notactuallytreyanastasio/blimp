defmodule TermDiff.AI.ClaudeTest do
  use ExUnit.Case, async: true

  alias TermDiff.AI.Claude

  describe "build_args/2" do
    test "includes -p flag" do
      args = Claude.build_args("review this", "/tmp/repo")
      assert "-p" in args
    end

    test "includes the prompt" do
      args = Claude.build_args("review this", "/tmp/repo")
      assert "review this" in args
    end

    test "includes default allowed tools" do
      args = Claude.build_args("review this", "/tmp/repo")
      idx = Enum.find_index(args, &(&1 == "--allowedTools"))
      assert idx != nil
      tools_val = Enum.at(args, idx + 1)
      assert tools_val =~ "Read"
      assert tools_val =~ "Bash"
    end

    test "includes system prompt when provided" do
      args = Claude.build_args("hi", "/tmp/repo", system_prompt: "you are a reviewer")
      idx = Enum.find_index(args, &(&1 == "--system-prompt"))
      assert idx != nil
      assert Enum.at(args, idx + 1) == "you are a reviewer"
    end

    test "uses custom allowed tools when provided" do
      args = Claude.build_args("hi", "/tmp/repo", allowed_tools: "Read,Grep")
      idx = Enum.find_index(args, &(&1 == "--allowedTools"))
      assert Enum.at(args, idx + 1) == "Read,Grep"
    end

    test "includes model flag when provided" do
      args = Claude.build_args("hi", "/tmp/repo", model: "sonnet")
      idx = Enum.find_index(args, &(&1 == "--model"))
      assert idx != nil
      assert Enum.at(args, idx + 1) == "sonnet"
    end

    test "omits model flag when not provided" do
      args = Claude.build_args("hi", "/tmp/repo")
      refute "--model" in args
    end

    test "includes json-schema when provided" do
      schema = ~s|{"type":"object"}|
      args = Claude.build_args("hi", "/tmp/repo", json_schema: schema)
      idx = Enum.find_index(args, &(&1 == "--json-schema"))
      assert idx != nil
      assert Enum.at(args, idx + 1) == schema
    end

    test "omits json-schema when not provided" do
      args = Claude.build_args("hi", "/tmp/repo")
      refute "--json-schema" in args
    end

    test "includes output format json" do
      args = Claude.build_args("hi", "/tmp/repo")
      assert "--output-format" in args
      idx = Enum.find_index(args, &(&1 == "--output-format"))
      assert Enum.at(args, idx + 1) == "json"
    end
  end

  describe "find_executable/0" do
    test "returns path to claude binary" do
      path = Claude.find_executable()
      assert is_binary(path) or is_nil(path)
    end
  end

  describe "default_allowed_tools/0" do
    test "returns a comma-separated string of tool names" do
      tools = Claude.default_allowed_tools()
      assert is_binary(tools)
      assert tools =~ "Read"
    end
  end
end

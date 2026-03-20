defmodule TermDiff.AI.CodeReviewerTest do
  use ExUnit.Case, async: true

  alias TermDiff.AI.CodeReviewer

  describe "system_prompt/0" do
    test "returns a non-empty string" do
      prompt = CodeReviewer.system_prompt()
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "mentions code review in the prompt" do
      prompt = CodeReviewer.system_prompt()
      assert prompt =~ "code"
    end
  end

  describe "tools/1" do
    test "returns a list of LangChain functions" do
      tools = CodeReviewer.tools("/tmp/fake_repo")
      assert is_list(tools)
      assert length(tools) > 0
    end

    test "includes read_file tool" do
      tools = CodeReviewer.tools("/tmp/fake_repo")
      names = Enum.map(tools, & &1.name)
      assert "read_file" in names
    end

    test "includes git_diff tool" do
      tools = CodeReviewer.tools("/tmp/fake_repo")
      names = Enum.map(tools, & &1.name)
      assert "git_diff" in names
    end

    test "includes git_status tool" do
      tools = CodeReviewer.tools("/tmp/fake_repo")
      names = Enum.map(tools, & &1.name)
      assert "git_status" in names
    end

    test "includes list_files tool" do
      tools = CodeReviewer.tools("/tmp/fake_repo")
      names = Enum.map(tools, & &1.name)
      assert "list_files" in names
    end
  end

  describe "build_chain/1" do
    test "returns an LLMChain struct" do
      chain = CodeReviewer.build_chain("/tmp/fake_repo")
      assert %LangChain.Chains.LLMChain{} = chain
    end

    test "chain has tools attached" do
      chain = CodeReviewer.build_chain("/tmp/fake_repo")
      assert length(chain.tools) > 0
    end

    test "accepts custom model and endpoint" do
      chain = CodeReviewer.build_chain("/tmp/fake_repo",
        model: "codellama:7b",
        endpoint: "http://gpu-box:11434/api/chat"
      )

      assert chain.llm.model == "codellama:7b"
      assert chain.llm.endpoint == "http://gpu-box:11434/api/chat"
    end
  end

  describe "review/2" do
    test "returns error tuple when Ollama is not reachable" do
      result = CodeReviewer.review("/tmp/fake_repo", "review this",
        endpoint: "http://localhost:99999/api/chat",
        receive_timeout: 500
      )

      assert {:error, _reason} = result
    end
  end
end

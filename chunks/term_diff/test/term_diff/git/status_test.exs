defmodule TermDiff.Git.StatusTest do
  use ExUnit.Case, async: true

  alias TermDiff.Git.Status
  alias TermDiff.Git.Types.FileEntry

  describe "parse/1" do
    test "parses modified unstaged file" do
      assert [%FileEntry{path: "lib/app.ex", staged_status: nil, unstaged_status: :modified}] =
               Status.parse(" M lib/app.ex")
    end

    test "parses staged added file" do
      assert [%FileEntry{path: "lib/new.ex", staged_status: :added, unstaged_status: nil}] =
               Status.parse("A  lib/new.ex")
    end

    test "parses untracked file" do
      assert [%FileEntry{path: "tmp/debug.log", staged_status: :untracked, unstaged_status: :untracked}] =
               Status.parse("?? tmp/debug.log")
    end

    test "parses deleted file" do
      assert [%FileEntry{path: "old.ex", staged_status: :deleted, unstaged_status: nil}] =
               Status.parse("D  old.ex")
    end

    test "parses both staged and unstaged modifications" do
      assert [%FileEntry{path: "lib/app.ex", staged_status: :modified, unstaged_status: :modified}] =
               Status.parse("MM lib/app.ex")
    end

    test "parses multiple files" do
      input = " M lib/a.ex\nA  lib/b.ex\n?? lib/c.ex"
      result = Status.parse(input)
      assert length(result) == 3
      assert Enum.map(result, & &1.path) == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    end

    test "handles empty input" do
      assert [] = Status.parse("")
    end
  end
end

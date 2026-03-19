defmodule TermDiff.Git.DiffTest do
  use ExUnit.Case, async: true

  alias TermDiff.Git.Diff
  alias TermDiff.Git.Types.{FileDiff, Hunk, DiffLine}

  @sample_diff """
  diff --git a/lib/app.ex b/lib/app.ex
  index abc1234..def5678 100644
  --- a/lib/app.ex
  +++ b/lib/app.ex
  @@ -1,4 +1,5 @@
   defmodule App do
  -  def hello, do: :world
  +  def hello, do: :blimp
  +  def goodbye, do: :later
   end
  """

  describe "parse/1" do
    test "parses a single file diff" do
      [%FileDiff{} = file_diff] = Diff.parse(@sample_diff)
      assert file_diff.path == "lib/app.ex"
      assert file_diff.additions == 2
      assert file_diff.deletions == 1
      assert length(file_diff.hunks) == 1
    end

    test "parses hunk header" do
      [%FileDiff{hunks: [%Hunk{} = hunk]}] = Diff.parse(@sample_diff)
      assert hunk.old_start == 1
      assert hunk.old_count == 4
      assert hunk.new_start == 1
      assert hunk.new_count == 5
    end

    test "parses diff lines with correct types" do
      [%FileDiff{hunks: [%Hunk{lines: lines}]}] = Diff.parse(@sample_diff)

      types = Enum.map(lines, & &1.type)
      assert :context in types
      assert :addition in types
      assert :deletion in types
    end

    test "context lines have both line numbers" do
      [%FileDiff{hunks: [%Hunk{lines: lines}]}] = Diff.parse(@sample_diff)

      context_lines = Enum.filter(lines, &(&1.type == :context))
      assert Enum.all?(context_lines, fn l -> l.old_line_number && l.new_line_number end)
    end

    test "addition lines have only new line number" do
      [%FileDiff{hunks: [%Hunk{lines: lines}]}] = Diff.parse(@sample_diff)

      additions = Enum.filter(lines, &(&1.type == :addition))
      assert Enum.all?(additions, fn l -> l.new_line_number && is_nil(l.old_line_number) end)
    end

    test "deletion lines have only old line number" do
      [%FileDiff{hunks: [%Hunk{lines: lines}]}] = Diff.parse(@sample_diff)

      deletions = Enum.filter(lines, &(&1.type == :deletion))
      assert Enum.all?(deletions, fn l -> l.old_line_number && is_nil(l.new_line_number) end)
    end

    test "handles empty input" do
      assert [] = Diff.parse("")
    end

    test "handles binary files" do
      input = """
      diff --git a/image.png b/image.png
      Binary files a/image.png and b/image.png differ
      """

      [%FileDiff{} = file_diff] = Diff.parse(input)
      assert file_diff.path == "image.png"
      assert file_diff.binary == true
    end
  end
end

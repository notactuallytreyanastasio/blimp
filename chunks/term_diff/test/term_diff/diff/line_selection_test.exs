defmodule TermDiff.Diff.LineSelectionTest do
  use ExUnit.Case, async: true

  alias TermDiff.Diff.LineSelection

  describe "start/3" do
    test "creates an active selection at the given line" do
      sel = LineSelection.start(%LineSelection{}, "lib/foo.ex", 10)
      assert sel.active
      assert sel.file_path == "lib/foo.ex"
      assert sel.anchor_line == 10
      assert sel.focus_line == 10
    end

    test "replaces any existing selection" do
      sel =
        %LineSelection{}
        |> LineSelection.start("lib/foo.ex", 5)
        |> LineSelection.start("lib/bar.ex", 20)

      assert sel.file_path == "lib/bar.ex"
      assert sel.anchor_line == 20
      assert sel.focus_line == 20
    end
  end

  describe "extend/2" do
    test "extends the focus line" do
      sel =
        %LineSelection{}
        |> LineSelection.start("lib/foo.ex", 10)
        |> LineSelection.extend(15)

      assert sel.anchor_line == 10
      assert sel.focus_line == 15
    end

    test "can extend backward" do
      sel =
        %LineSelection{}
        |> LineSelection.start("lib/foo.ex", 10)
        |> LineSelection.extend(3)

      assert sel.anchor_line == 10
      assert sel.focus_line == 3
    end

    test "does nothing when not active" do
      sel = LineSelection.extend(%LineSelection{}, 10)
      refute sel.active
      assert sel.focus_line == nil
    end
  end

  describe "clear/1" do
    test "resets to inactive" do
      sel =
        %LineSelection{}
        |> LineSelection.start("lib/foo.ex", 10)
        |> LineSelection.clear()

      refute sel.active
      assert sel.file_path == nil
      assert sel.anchor_line == nil
      assert sel.focus_line == nil
    end
  end

  describe "selected_range/1" do
    test "returns sorted {start, end} tuple" do
      sel =
        %LineSelection{}
        |> LineSelection.start("lib/foo.ex", 10)
        |> LineSelection.extend(15)

      assert LineSelection.selected_range(sel) == {10, 15}
    end

    test "handles backward selection" do
      sel =
        %LineSelection{}
        |> LineSelection.start("lib/foo.ex", 15)
        |> LineSelection.extend(10)

      assert LineSelection.selected_range(sel) == {10, 15}
    end

    test "single line selection" do
      sel = LineSelection.start(%LineSelection{}, "lib/foo.ex", 10)
      assert LineSelection.selected_range(sel) == {10, 10}
    end

    test "returns nil when not active" do
      assert LineSelection.selected_range(%LineSelection{}) == nil
    end
  end

  describe "line_selected?/2" do
    test "true for lines in range" do
      sel =
        %LineSelection{}
        |> LineSelection.start("lib/foo.ex", 10)
        |> LineSelection.extend(15)

      assert LineSelection.line_selected?(sel, 10)
      assert LineSelection.line_selected?(sel, 12)
      assert LineSelection.line_selected?(sel, 15)
    end

    test "false for lines outside range" do
      sel =
        %LineSelection{}
        |> LineSelection.start("lib/foo.ex", 10)
        |> LineSelection.extend(15)

      refute LineSelection.line_selected?(sel, 9)
      refute LineSelection.line_selected?(sel, 16)
    end

    test "false when not active" do
      refute LineSelection.line_selected?(%LineSelection{}, 10)
    end

    test "handles nil line number" do
      sel = LineSelection.start(%LineSelection{}, "lib/foo.ex", 10)
      refute LineSelection.line_selected?(sel, nil)
    end
  end
end

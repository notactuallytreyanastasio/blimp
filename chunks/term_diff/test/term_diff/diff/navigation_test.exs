defmodule TermDiff.Diff.NavigationTest do
  use ExUnit.Case, async: true

  alias TermDiff.Diff.Navigation

  describe "handle_key/2" do
    test "j moves down in file list" do
      nav = %Navigation{focus: :file_list, file_index: 0, file_count: 3}
      assert %{file_index: 1} = Navigation.handle_key(nav, "j")
    end

    test "k moves up in file list" do
      nav = %Navigation{focus: :file_list, file_index: 2, file_count: 3}
      assert %{file_index: 1} = Navigation.handle_key(nav, "k")
    end

    test "j does not go past last file" do
      nav = %Navigation{focus: :file_list, file_index: 2, file_count: 3}
      assert %{file_index: 2} = Navigation.handle_key(nav, "j")
    end

    test "k does not go below zero" do
      nav = %Navigation{focus: :file_list, file_index: 0, file_count: 3}
      assert %{file_index: 0} = Navigation.handle_key(nav, "k")
    end

    test "Enter switches to diff view" do
      nav = %Navigation{focus: :file_list, file_index: 1, file_count: 3}
      assert %{focus: :diff_view, hunk_index: 0} = Navigation.handle_key(nav, "Enter")
    end

    test "Enter does nothing when file list is empty" do
      nav = %Navigation{focus: :file_list, file_index: 0, file_count: 0}
      assert %{focus: :file_list} = Navigation.handle_key(nav, "Enter")
    end

    test "q returns to file list from diff view" do
      nav = %Navigation{focus: :diff_view}
      assert %{focus: :file_list} = Navigation.handle_key(nav, "q")
    end

    test "q is a no-op in file list" do
      nav = %Navigation{focus: :file_list}
      assert %{focus: :file_list} = Navigation.handle_key(nav, "q")
    end

    test "Tab toggles focus" do
      nav = %Navigation{focus: :file_list}
      assert %{focus: :diff_view} = Navigation.handle_key(nav, "Tab")

      nav = %Navigation{focus: :diff_view}
      assert %{focus: :file_list} = Navigation.handle_key(nav, "Tab")
    end

    test "F toggles follow mode" do
      nav = %Navigation{following: false}
      assert %{following: true} = Navigation.handle_key(nav, "F")

      nav = %Navigation{following: true}
      assert %{following: false} = Navigation.handle_key(nav, "F")
    end

    test "unknown keys are ignored" do
      nav = %Navigation{}
      assert nav == Navigation.handle_key(nav, "x")
    end

    test "s sets stage_file from file_list" do
      nav = %Navigation{focus: :file_list, selected_file: "foo.ex"}
      result = Navigation.handle_key(nav, "s")
      assert result.stage_file == "foo.ex"
    end

    test "u sets unstage_file from file_list" do
      nav = %Navigation{focus: :file_list, selected_file: "foo.ex"}
      result = Navigation.handle_key(nav, "u")
      assert result.unstage_file == "foo.ex"
    end

    test "s works from diff_view too" do
      nav = %Navigation{focus: :diff_view, selected_file: "bar.ex"}
      result = Navigation.handle_key(nav, "s")
      assert result.stage_file == "bar.ex"
    end

    test "u works from diff_view too" do
      nav = %Navigation{focus: :diff_view, selected_file: "bar.ex"}
      result = Navigation.handle_key(nav, "u")
      assert result.unstage_file == "bar.ex"
    end

    test "s is noop with nil selected_file" do
      nav = %Navigation{focus: :file_list, selected_file: nil}
      result = Navigation.handle_key(nav, "s")
      assert result.stage_file == nil
    end

    test "u is noop from log_view" do
      nav = %Navigation{focus: :log_view, selected_file: "foo.ex"}
      result = Navigation.handle_key(nav, "u")
      assert result.unstage_file == nil
    end
  end

  describe "sync_to_files/2" do
    test "resolves file_index from selected_file path" do
      files = ["a.ex", "b.ex", "c.ex"]
      nav = %Navigation{selected_file: "b.ex", file_index: 0, file_count: 0}
      result = Navigation.sync_to_files(nav, files)

      assert result.file_index == 1
      assert result.file_count == 3
      assert result.selected_file == "b.ex"
    end

    test "keeps cursor at 0 when selected_file is first" do
      files = ["a.ex", "b.ex"]
      nav = %Navigation{selected_file: "a.ex", file_index: 5}
      result = Navigation.sync_to_files(nav, files)

      assert result.file_index == 0
    end

    test "clamps to last file when selected_file is gone" do
      files = ["a.ex", "b.ex"]
      nav = %Navigation{selected_file: "deleted.ex", file_index: 5}
      result = Navigation.sync_to_files(nav, files)

      assert result.file_index == 1
      assert result.selected_file == "b.ex"
      assert result.file_count == 2
    end

    test "handles empty file list" do
      nav = %Navigation{selected_file: "a.ex", file_index: 3}
      result = Navigation.sync_to_files(nav, [])

      assert result.file_index == 0
      assert result.file_count == 0
      assert result.selected_file == nil
    end

    test "preserves index position when selected_file is nil" do
      files = ["a.ex", "b.ex", "c.ex"]
      nav = %Navigation{selected_file: nil, file_index: 1}
      result = Navigation.sync_to_files(nav, files)

      assert result.file_index == 1
      assert result.selected_file == "b.ex"
      assert result.file_count == 3
    end

    test "clamps index when list shrinks and selected_file is nil" do
      files = ["a.ex"]
      nav = %Navigation{selected_file: nil, file_index: 5}
      result = Navigation.sync_to_files(nav, files)

      assert result.file_index == 0
      assert result.selected_file == "a.ex"
    end
  end

  describe "follow_to_latest/3" do
    test "jumps to latest file and last hunk when following" do
      nav = %Navigation{following: true, focus: :file_list, file_index: 0}
      result = Navigation.follow_to_latest(nav, "lib/app.ex", 3)

      assert result.selected_file == "lib/app.ex"
      assert result.focus == :diff_view
      assert result.hunk_index == 2
    end

    test "does nothing when not following" do
      nav = %Navigation{following: false, focus: :file_list, file_index: 0}
      assert nav == Navigation.follow_to_latest(nav, "lib/app.ex", 3)
    end

    test "does nothing with nil file" do
      nav = %Navigation{following: true}
      assert nav == Navigation.follow_to_latest(nav, nil, 0)
    end
  end
end

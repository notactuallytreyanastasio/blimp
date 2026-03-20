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

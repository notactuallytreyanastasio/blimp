defmodule TermDiff.Diff.FileStateTest do
  use ExUnit.Case, async: true

  alias TermDiff.Diff.FileState

  describe "from_status/2" do
    test "parses untracked file" do
      state = FileState.from_status("??", "new.ex")
      assert state.path == "new.ex"
      assert state.status == :untracked
    end

    test "parses staged new file" do
      state = FileState.from_status("A ", "new.ex")
      assert state.status == :staged_new
    end

    test "parses unstaged modified" do
      state = FileState.from_status(" M", "foo.ex")
      assert state.status == :unstaged_modified
    end

    test "parses staged modified" do
      state = FileState.from_status("M ", "foo.ex")
      assert state.status == :staged_modified
    end

    test "parses staged+unstaged modified" do
      state = FileState.from_status("MM", "foo.ex")
      assert state.status == :partial_modified
    end

    test "parses unstaged deleted" do
      state = FileState.from_status(" D", "foo.ex")
      assert state.status == :unstaged_deleted
    end

    test "parses staged deleted" do
      state = FileState.from_status("D ", "foo.ex")
      assert state.status == :staged_deleted
    end

    test "parses renamed" do
      state = FileState.from_status("R ", "new.ex")
      assert state.status == :staged_renamed
    end
  end

  describe "stage_command/1" do
    test "untracked -> git add" do
      state = FileState.from_status("??", "new.ex")
      assert FileState.stage_command(state) == {:add, "new.ex"}
    end

    test "unstaged modified -> git add" do
      state = FileState.from_status(" M", "foo.ex")
      assert FileState.stage_command(state) == {:add, "foo.ex"}
    end

    test "unstaged deleted -> git add" do
      state = FileState.from_status(" D", "foo.ex")
      assert FileState.stage_command(state) == {:add, "foo.ex"}
    end

    test "partial modified -> git add" do
      state = FileState.from_status("MM", "foo.ex")
      assert FileState.stage_command(state) == {:add, "foo.ex"}
    end

    test "already fully staged -> noop" do
      state = FileState.from_status("M ", "foo.ex")
      assert FileState.stage_command(state) == :noop
    end

    test "staged new -> noop" do
      state = FileState.from_status("A ", "foo.ex")
      assert FileState.stage_command(state) == :noop
    end
  end

  describe "unstage_command/1" do
    test "staged new -> git rm --cached" do
      state = FileState.from_status("A ", "new.ex")
      assert FileState.unstage_command(state) == {:rm_cached, "new.ex"}
    end

    test "staged modified -> git restore --staged" do
      state = FileState.from_status("M ", "foo.ex")
      assert FileState.unstage_command(state) == {:restore_staged, "foo.ex"}
    end

    test "staged deleted -> git restore --staged" do
      state = FileState.from_status("D ", "foo.ex")
      assert FileState.unstage_command(state) == {:restore_staged, "foo.ex"}
    end

    test "staged renamed -> git restore --staged" do
      state = FileState.from_status("R ", "new.ex")
      assert FileState.unstage_command(state) == {:restore_staged, "new.ex"}
    end

    test "partial modified -> git restore --staged" do
      state = FileState.from_status("MM", "foo.ex")
      assert FileState.unstage_command(state) == {:restore_staged, "foo.ex"}
    end

    test "unstaged modified -> noop (nothing staged)" do
      state = FileState.from_status(" M", "foo.ex")
      assert FileState.unstage_command(state) == :noop
    end

    test "untracked -> noop" do
      state = FileState.from_status("??", "foo.ex")
      assert FileState.unstage_command(state) == :noop
    end
  end

  describe "stageable?/1 and unstageable?/1" do
    test "untracked is stageable but not unstageable" do
      state = FileState.from_status("??", "f.ex")
      assert FileState.stageable?(state)
      refute FileState.unstageable?(state)
    end

    test "staged modified is unstageable but not stageable" do
      state = FileState.from_status("M ", "f.ex")
      refute FileState.stageable?(state)
      assert FileState.unstageable?(state)
    end

    test "partial modified is both stageable and unstageable" do
      state = FileState.from_status("MM", "f.ex")
      assert FileState.stageable?(state)
      assert FileState.unstageable?(state)
    end
  end
end

defmodule TermDiff.Diff.CommitStateTest do
  use ExUnit.Case, async: true

  alias TermDiff.Diff.CommitState

  describe "new/0" do
    test "starts in idle phase" do
      assert %CommitState{phase: :idle} = CommitState.new()
    end
  end

  describe "enter/2 for regular commit" do
    test "transitions to editing when staged files exist" do
      state = CommitState.enter(:commit, staged_count: 1)
      assert state.phase == :editing
      assert state.mode == :commit
      assert state.error == nil
    end

    test "transitions to error when no staged files" do
      state = CommitState.enter(:commit, staged_count: 0)
      assert state.phase == :error
      assert state.error =~ "Nothing staged"
    end
  end

  describe "enter/2 for amend" do
    test "transitions to editing with last message pre-filled" do
      state = CommitState.enter(:amend, last_message: "previous msg")
      assert state.phase == :editing
      assert state.mode == :amend
      assert state.message == "previous msg"
    end

    test "transitions to editing even with nothing staged (amend allows it)" do
      state = CommitState.enter(:amend, last_message: "msg", staged_count: 0)
      assert state.phase == :editing
    end

    test "transitions to error when no previous commit" do
      state = CommitState.enter(:amend, last_message: nil)
      assert state.phase == :error
      assert state.error =~ "No commit"
    end
  end

  describe "update_message/2" do
    test "updates message in editing phase" do
      state = CommitState.enter(:commit, staged_count: 1)
      state = CommitState.update_message(state, "new message")
      assert state.message == "new message"
    end

    test "no-op when not editing" do
      state = CommitState.new()
      assert CommitState.update_message(state, "hello") == state
    end
  end

  describe "submit/1" do
    test "transitions to submitting when message is non-empty" do
      state =
        CommitState.enter(:commit, staged_count: 1)
        |> CommitState.update_message("feat: add thing")
        |> CommitState.submit()

      assert state.phase == :submitting
    end

    test "transitions to error when message is empty" do
      state =
        CommitState.enter(:commit, staged_count: 1)
        |> CommitState.submit()

      assert state.phase == :error
      assert state.error =~ "empty"
    end

    test "transitions to error when message is only whitespace" do
      state =
        CommitState.enter(:commit, staged_count: 1)
        |> CommitState.update_message("   \n  ")
        |> CommitState.submit()

      assert state.phase == :error
      assert state.error =~ "empty"
    end
  end

  describe "complete/1" do
    test "transitions from submitting to idle" do
      state =
        CommitState.enter(:commit, staged_count: 1)
        |> CommitState.update_message("msg")
        |> CommitState.submit()
        |> CommitState.complete()

      assert state.phase == :idle
      assert state.message == ""
      assert state.error == nil
    end
  end

  describe "fail/2" do
    test "transitions from submitting to error with message" do
      state =
        CommitState.enter(:commit, staged_count: 1)
        |> CommitState.update_message("msg")
        |> CommitState.submit()
        |> CommitState.fail("git: nothing to commit")

      assert state.phase == :error
      assert state.error == "git: nothing to commit"
    end
  end

  describe "cancel/1" do
    test "returns to idle from editing" do
      state =
        CommitState.enter(:commit, staged_count: 1)
        |> CommitState.cancel()

      assert state.phase == :idle
      assert state.message == ""
    end

    test "returns to idle from error" do
      state =
        CommitState.enter(:commit, staged_count: 0)
        |> CommitState.cancel()

      assert state.phase == :idle
    end
  end

  describe "active?/1" do
    test "true when editing or submitting" do
      assert CommitState.active?(CommitState.enter(:commit, staged_count: 1))

      state =
        CommitState.enter(:commit, staged_count: 1)
        |> CommitState.update_message("msg")
        |> CommitState.submit()

      assert CommitState.active?(state)
    end

    test "false when idle" do
      refute CommitState.active?(CommitState.new())
    end

    test "true when error (still in commit flow)" do
      assert CommitState.active?(CommitState.enter(:commit, staged_count: 0))
    end
  end
end

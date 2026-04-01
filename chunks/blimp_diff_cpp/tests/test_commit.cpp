#include "state/commit.h"
#include "test_framework.h"

TEST(commit_initial_idle) {
    blimp::state::CommitState cs;
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Idle);
    ASSERT_TRUE(cs.message().empty());
}

TEST(commit_editing) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Editing);
    cs.insert_char('h');
    cs.insert_char('i');
    ASSERT_EQ(cs.message(), "hi");
}

TEST(commit_backspace) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.insert_char('a');
    cs.insert_char('b');
    cs.backspace();
    ASSERT_EQ(cs.message(), "a");
    cs.backspace();
    ASSERT_TRUE(cs.message().empty());
    cs.backspace(); // No crash on empty
    ASSERT_TRUE(cs.message().empty());
}

TEST(commit_newline) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.insert_char('a');
    cs.newline();
    cs.insert_char('b');
    ASSERT_EQ(cs.message(), "a\nb");
}

TEST(commit_empty_rejects) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    ASSERT_FALSE(cs.try_submit());
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Error);
}

TEST(commit_whitespace_only_rejects) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.insert_char(' ');
    cs.insert_char('\t');
    ASSERT_FALSE(cs.try_submit());
}

TEST(commit_valid_submits) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.insert_char('f');
    cs.insert_char('i');
    cs.insert_char('x');
    ASSERT_TRUE(cs.try_submit());
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Submitting);
}

TEST(commit_cancel_resets) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.insert_char('x');
    cs.cancel();
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Idle);
    ASSERT_TRUE(cs.message().empty());
}

TEST(commit_error_state) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.set_error("something broke");
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Error);
    ASSERT_EQ(cs.error(), "something broke");
}

// ── Edge case tests ────────────────────────────────────────────────────────

TEST(commit_double_submit_while_submitting) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.insert_char('f');
    cs.insert_char('i');
    cs.insert_char('x');
    ASSERT_TRUE(cs.try_submit());
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Submitting);
    // try_submit while already Submitting -- message is non-empty so it
    // would go to Submitting again (no guard on phase), but the message
    // check should still pass
    bool result = cs.try_submit();
    // Phase should still be Submitting regardless
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Submitting);
}

TEST(commit_insert_after_cancel_noop) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.insert_char('h');
    cs.cancel();
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Idle);
    // insert_char should be a no-op when not in Editing phase
    cs.insert_char('x');
    ASSERT_TRUE(cs.message().empty()); // cancel already cleared it
}

TEST(commit_error_then_retry) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.set_error("git failed");
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Error);
    ASSERT_EQ(cs.error(), "git failed");
    // begin_editing again should reset and allow retry
    cs.begin_editing();
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Editing);
    ASSERT_TRUE(cs.message().empty());
    ASSERT_TRUE(cs.error().empty());
    cs.insert_char('r');
    cs.insert_char('e');
    cs.insert_char('t');
    cs.insert_char('r');
    cs.insert_char('y');
    ASSERT_TRUE(cs.try_submit());
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Submitting);
}

TEST(commit_very_long_message) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    // Insert 1500 characters
    for (int i = 0; i < 1500; i++) {
        cs.insert_char('a');
    }
    ASSERT_EQ(cs.message().size(), 1500u);
    ASSERT_TRUE(cs.try_submit());
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Submitting);
}

TEST(commit_message_with_only_newlines) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.newline();
    cs.newline();
    cs.newline();
    // Message is "\n\n\n" -- only whitespace, should reject
    ASSERT_FALSE(cs.try_submit());
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Error);
}

TEST(commit_succeed_resets_everything) {
    blimp::state::CommitState cs;
    cs.begin_editing();
    cs.insert_char('d');
    cs.insert_char('o');
    cs.insert_char('n');
    cs.insert_char('e');
    ASSERT_TRUE(cs.try_submit());
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Submitting);
    cs.succeed();
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Idle);
    ASSERT_TRUE(cs.message().empty());
    ASSERT_TRUE(cs.error().empty());
}

TEST(commit_backspace_in_idle_noop) {
    blimp::state::CommitState cs;
    // Not in editing mode -- backspace should not crash
    cs.backspace();
    ASSERT_TRUE(cs.message().empty());
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Idle);
}

TEST(commit_newline_in_idle_noop) {
    blimp::state::CommitState cs;
    cs.newline();
    ASSERT_TRUE(cs.message().empty());
    ASSERT_EQ(cs.phase(), blimp::state::CommitPhase::Idle);
}

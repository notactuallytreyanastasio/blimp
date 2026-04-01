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

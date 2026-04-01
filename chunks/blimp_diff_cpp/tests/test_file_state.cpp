#include "state/file_state.h"
#include "test_framework.h"

TEST(file_state_untracked) {
    blimp::FileEntry e{.path = "new.txt", .unstaged = blimp::Status::Untracked};
    ASSERT_EQ(blimp::state::classify(e), blimp::state::FileState::Untracked);
    ASSERT_TRUE(blimp::state::stage_command(e).has_value());
    ASSERT_FALSE(blimp::state::unstage_command(e).has_value());
}

TEST(file_state_staged_new) {
    blimp::FileEntry e{.path = "new.txt", .staged = blimp::Status::Added};
    ASSERT_EQ(blimp::state::classify(e), blimp::state::FileState::StagedNew);
    ASSERT_FALSE(blimp::state::stage_command(e).has_value());
    ASSERT_TRUE(blimp::state::unstage_command(e).has_value());
}

TEST(file_state_unstaged_modified) {
    blimp::FileEntry e{.path = "mod.txt", .unstaged = blimp::Status::Modified};
    ASSERT_EQ(blimp::state::classify(e), blimp::state::FileState::UnstagedModified);
    ASSERT_TRUE(blimp::state::stage_command(e).has_value());
}

TEST(file_state_staged_modified) {
    blimp::FileEntry e{.path = "mod.txt", .staged = blimp::Status::Modified};
    ASSERT_EQ(blimp::state::classify(e), blimp::state::FileState::StagedModified);
    ASSERT_FALSE(blimp::state::stage_command(e).has_value());
    ASSERT_TRUE(blimp::state::unstage_command(e).has_value());
}

TEST(file_state_partial_modified) {
    blimp::FileEntry e{.path = "both.txt",
                       .staged = blimp::Status::Modified,
                       .unstaged = blimp::Status::Modified};
    ASSERT_EQ(blimp::state::classify(e), blimp::state::FileState::PartialModified);
    ASSERT_TRUE(blimp::state::stage_command(e).has_value());
    ASSERT_TRUE(blimp::state::unstage_command(e).has_value());
}

TEST(file_state_deleted) {
    blimp::FileEntry e{.path = "gone.txt", .unstaged = blimp::Status::Deleted};
    ASSERT_EQ(blimp::state::classify(e), blimp::state::FileState::UnstagedDeleted);

    blimp::FileEntry e2{.path = "gone2.txt", .staged = blimp::Status::Deleted};
    ASSERT_EQ(blimp::state::classify(e2), blimp::state::FileState::StagedDeleted);
}

TEST(file_state_renamed) {
    blimp::FileEntry e{.path = "new.txt",
                       .orig_path = "old.txt",
                       .staged = blimp::Status::Renamed};
    ASSERT_EQ(blimp::state::classify(e), blimp::state::FileState::StagedRenamed);
    ASSERT_TRUE(blimp::state::unstage_command(e).has_value());
}

// ── Edge case tests ────────────────────────────────────────────────────────

TEST(file_state_none_none_fallback) {
    // File with no status at all -- both staged and unstaged are None
    blimp::FileEntry e{.path = "mystery.txt"};
    // Both default to Status::None, so has_staged=false, has_unstaged=false
    // Falls through to the fallback: UnstagedModified
    auto state = blimp::state::classify(e);
    ASSERT_EQ(state, blimp::state::FileState::UnstagedModified);
}

TEST(file_state_multiple_classifications_in_sequence) {
    // Classify different entries in sequence, ensure no state leaks
    blimp::FileEntry e1{.path = "a.txt", .unstaged = blimp::Status::Untracked};
    blimp::FileEntry e2{.path = "b.txt", .staged = blimp::Status::Added};
    blimp::FileEntry e3{.path = "c.txt", .unstaged = blimp::Status::Modified};
    blimp::FileEntry e4{.path = "d.txt", .staged = blimp::Status::Deleted};

    ASSERT_EQ(blimp::state::classify(e1), blimp::state::FileState::Untracked);
    ASSERT_EQ(blimp::state::classify(e2), blimp::state::FileState::StagedNew);
    ASSERT_EQ(blimp::state::classify(e3), blimp::state::FileState::UnstagedModified);
    ASSERT_EQ(blimp::state::classify(e4), blimp::state::FileState::StagedDeleted);
}

TEST(file_state_stage_command_for_already_staged_nullopt) {
    // StagedNew -- already staged, stage_command should be nullopt
    blimp::FileEntry e1{.path = "new.txt", .staged = blimp::Status::Added};
    ASSERT_FALSE(blimp::state::stage_command(e1).has_value());

    // StagedModified -- already staged, stage_command should be nullopt
    blimp::FileEntry e2{.path = "mod.txt", .staged = blimp::Status::Modified};
    ASSERT_FALSE(blimp::state::stage_command(e2).has_value());

    // StagedDeleted -- already staged, stage_command should be nullopt
    blimp::FileEntry e3{.path = "del.txt", .staged = blimp::Status::Deleted};
    ASSERT_FALSE(blimp::state::stage_command(e3).has_value());

    // StagedRenamed -- already staged, stage_command should be nullopt
    blimp::FileEntry e4{.path = "new.txt", .orig_path = "old.txt",
                        .staged = blimp::Status::Renamed};
    ASSERT_FALSE(blimp::state::stage_command(e4).has_value());
}

TEST(file_state_unstage_command_for_unstaged_nullopt) {
    // Untracked -- not staged, unstage_command should be nullopt
    blimp::FileEntry e1{.path = "new.txt", .unstaged = blimp::Status::Untracked};
    ASSERT_FALSE(blimp::state::unstage_command(e1).has_value());

    // UnstagedModified -- not staged, unstage_command should be nullopt
    blimp::FileEntry e2{.path = "mod.txt", .unstaged = blimp::Status::Modified};
    ASSERT_FALSE(blimp::state::unstage_command(e2).has_value());

    // UnstagedDeleted -- not staged, unstage_command should be nullopt
    blimp::FileEntry e3{.path = "del.txt", .unstaged = blimp::Status::Deleted};
    ASSERT_FALSE(blimp::state::unstage_command(e3).has_value());
}

TEST(file_state_partial_has_both_commands) {
    blimp::FileEntry e{.path = "both.txt",
                       .staged = blimp::Status::Modified,
                       .unstaged = blimp::Status::Modified};
    ASSERT_TRUE(blimp::state::stage_command(e).has_value());
    ASSERT_TRUE(blimp::state::unstage_command(e).has_value());
}

TEST(file_state_stage_command_args_correct) {
    blimp::FileEntry e{.path = "foo.txt", .unstaged = blimp::Status::Modified};
    auto cmd = blimp::state::stage_command(e);
    ASSERT_TRUE(cmd.has_value());
    ASSERT_EQ(cmd->args.size(), 2u);
    ASSERT_EQ(cmd->args[0], "add");
    ASSERT_EQ(cmd->args[1], "foo.txt");
}

TEST(file_state_unstage_staged_new_uses_rm_cached) {
    blimp::FileEntry e{.path = "new.txt", .staged = blimp::Status::Added};
    auto cmd = blimp::state::unstage_command(e);
    ASSERT_TRUE(cmd.has_value());
    ASSERT_EQ(cmd->args.size(), 3u);
    ASSERT_EQ(cmd->args[0], "rm");
    ASSERT_EQ(cmd->args[1], "--cached");
    ASSERT_EQ(cmd->args[2], "new.txt");
}

TEST(file_state_unstage_staged_modified_uses_restore) {
    blimp::FileEntry e{.path = "mod.txt", .staged = blimp::Status::Modified};
    auto cmd = blimp::state::unstage_command(e);
    ASSERT_TRUE(cmd.has_value());
    ASSERT_EQ(cmd->args.size(), 3u);
    ASSERT_EQ(cmd->args[0], "restore");
    ASSERT_EQ(cmd->args[1], "--staged");
    ASSERT_EQ(cmd->args[2], "mod.txt");
}

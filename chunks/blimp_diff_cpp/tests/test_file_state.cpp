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

#include "state/interaction.h"
#include "test_framework.h"

TEST(interaction_initial_mode) {
    blimp::state::Interaction inter;
    ASSERT_EQ(inter.mode(), blimp::state::Mode::FileList);
}

TEST(interaction_set_mode) {
    blimp::state::Interaction inter;
    inter.set_mode(blimp::state::Mode::DiffView);
    ASSERT_EQ(inter.mode(), blimp::state::Mode::DiffView);
}

TEST(interaction_key_mapping_file_list) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'j', false, false), Action::Down);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'k', false, false), Action::Up);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, '\n', false, false), Action::Select);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'q', false, false), Action::Back);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 's', false, false), Action::StageFile);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'u', false, false), Action::UnstageFile);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'f', false, false), Action::ToggleFollow);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'l', false, false), Action::OpenLog);
}

TEST(interaction_ctrl_c_quits) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'c', true, false), Action::Quit);
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 'c', true, false), Action::Quit);
    ASSERT_EQ(Interaction::action_for_key(Mode::Committing, 'c', true, false), Action::Quit);
}

TEST(interaction_committing_keys) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::Committing, 27, false, false), Action::Cancel);
    ASSERT_EQ(Interaction::action_for_key(Mode::Committing, '\n', true, false), Action::Submit);
    ASSERT_EQ(Interaction::action_for_key(Mode::Committing, '\n', false, false), Action::NewLine);
    ASSERT_EQ(Interaction::action_for_key(Mode::Committing, 'x', false, false), Action::InsertChar);
}

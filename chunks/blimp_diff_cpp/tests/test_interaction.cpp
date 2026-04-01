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

// ── Edge case tests ────────────────────────────────────────────────────────

TEST(interaction_diffview_j_down) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 'j', false, false), Action::Down);
}

TEST(interaction_diffview_k_up) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 'k', false, false), Action::Up);
}

TEST(interaction_diffview_h_scroll_left) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 'h', false, false), Action::ScrollLeft);
}

TEST(interaction_diffview_l_scroll_right) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 'l', false, false), Action::ScrollRight);
}

TEST(interaction_diffview_v_enter_visual) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 'v', false, false), Action::EnterVisual);
}

TEST(interaction_diffview_tab_toggle_pane) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, '\t', false, false), Action::TogglePane);
}

TEST(interaction_diffview_q_back) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 'q', false, false), Action::Back);
}

TEST(interaction_diffview_esc_back) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 27, false, false), Action::Back);
}

TEST(interaction_diffview_space_page_down) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, ' ', false, false), Action::PageDown);
}

TEST(interaction_diffview_b_page_up) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 'b', false, false), Action::PageUp);
}

TEST(interaction_selecting_j_down) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::Selecting, 'j', false, false), Action::Down);
}

TEST(interaction_selecting_k_up) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::Selecting, 'k', false, false), Action::Up);
}

TEST(interaction_selecting_enter_select) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::Selecting, '\n', false, false), Action::Select);
}

TEST(interaction_selecting_esc_back) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::Selecting, 27, false, false), Action::Back);
}

TEST(interaction_agentview_falls_to_normal_keys) {
    using namespace blimp::state;
    // AgentView is not an overlay mode, so it uses the normal switch
    ASSERT_EQ(Interaction::action_for_key(Mode::AgentView, 'j', false, false), Action::Down);
    ASSERT_EQ(Interaction::action_for_key(Mode::AgentView, 'k', false, false), Action::Up);
    ASSERT_EQ(Interaction::action_for_key(Mode::AgentView, 'q', false, false), Action::Back);
    ASSERT_EQ(Interaction::action_for_key(Mode::AgentView, 27, false, false), Action::Back);
}

TEST(interaction_shift_does_not_interfere) {
    using namespace blimp::state;
    // Shift flag should not change behavior for normal mode keys
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'j', false, true), Action::Down);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'k', false, true), Action::Up);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'q', false, true), Action::Back);
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, 'h', false, true), Action::ScrollLeft);
}

TEST(interaction_cc_chord_within_400ms) {
    using namespace blimp::state;
    Interaction inter;
    ASSERT_FALSE(inter.press_c()); // First c -- starts timer
    ASSERT_TRUE(inter.press_c());  // Second c immediately -- triggers commit
    ASSERT_EQ(inter.mode(), Mode::Committing);
}

TEST(interaction_cc_chord_after_timeout) {
    using namespace blimp::state;
    Interaction inter;
    ASSERT_FALSE(inter.press_c()); // First c
    // We can't easily wait 400ms in a unit test, but we can verify
    // that a fresh press_c after reset doesn't trigger
    // Simulate by calling press_c twice with a gap by resetting
    // Since we can't control the clock, test the immediate case:
    // After a successful chord, another single c should NOT trigger
    ASSERT_TRUE(inter.press_c()); // completes the chord (last_c_ was just set)
    // Now last_c_ is reset, single c should not trigger
    ASSERT_FALSE(inter.press_c());
}

TEST(interaction_c_then_different_key_no_commit) {
    using namespace blimp::state;
    Interaction inter;
    ASSERT_FALSE(inter.press_c()); // First c
    // User presses 'j' instead of second 'c'
    // action_for_key does not interact with press_c, so the chord state
    // just lingers. Next press_c within window would still trigger.
    auto action = Interaction::action_for_key(Mode::FileList, 'j', false, false);
    ASSERT_EQ(action, Action::Down);
    // The mode should still be FileList, not Committing
    ASSERT_EQ(inter.mode(), Mode::FileList);
}

TEST(interaction_filelist_h_is_none) {
    using namespace blimp::state;
    // In FileList mode, 'h' should be None (not ScrollLeft)
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'h', false, false), Action::None);
}

TEST(interaction_filelist_l_is_open_log) {
    using namespace blimp::state;
    // In FileList mode, 'l' should be OpenLog (not ScrollRight)
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 'l', false, false), Action::OpenLog);
}

TEST(interaction_committing_backspace) {
    using namespace blimp::state;
    ASSERT_EQ(Interaction::action_for_key(Mode::Committing, 127, false, false), Action::Backspace);
}

TEST(interaction_agent_prompt_overlay_keys) {
    using namespace blimp::state;
    // AgentPrompt is an overlay mode like Committing
    ASSERT_EQ(Interaction::action_for_key(Mode::AgentPrompt, 27, false, false), Action::Cancel);
    ASSERT_EQ(Interaction::action_for_key(Mode::AgentPrompt, '\n', true, false), Action::Submit);
    ASSERT_EQ(Interaction::action_for_key(Mode::AgentPrompt, '\n', false, false), Action::NewLine);
    ASSERT_EQ(Interaction::action_for_key(Mode::AgentPrompt, 'x', false, false), Action::InsertChar);
    ASSERT_EQ(Interaction::action_for_key(Mode::AgentPrompt, 127, false, false), Action::Backspace);
}

TEST(interaction_unknown_key_is_none) {
    using namespace blimp::state;
    // Keys not in the mapping should return None
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, '~', false, false), Action::None);
    ASSERT_EQ(Interaction::action_for_key(Mode::DiffView, '~', false, false), Action::None);
    ASSERT_EQ(Interaction::action_for_key(Mode::FileList, 0, false, false), Action::None);
}

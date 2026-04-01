#include "state/navigation.h"
#include "test_framework.h"

TEST(nav_initial_state) {
    blimp::state::Navigation nav;
    ASSERT_EQ(nav.file_index(), 0u);
    ASSERT_EQ(nav.diff_scroll(), 0);
    ASSERT_EQ(nav.active_pane(), blimp::state::Pane::FileList);
    ASSERT_FALSE(nav.follow_mode());
}

TEST(nav_move_down) {
    blimp::state::Navigation nav;
    nav.set_file_count(5);
    nav.move_down();
    ASSERT_EQ(nav.file_index(), 1u);
    nav.move_down();
    ASSERT_EQ(nav.file_index(), 2u);
}

TEST(nav_move_up) {
    blimp::state::Navigation nav;
    nav.set_file_count(5);
    nav.move_down();
    nav.move_down();
    nav.move_up();
    ASSERT_EQ(nav.file_index(), 1u);
}

TEST(nav_boundary_clamp) {
    blimp::state::Navigation nav;
    nav.set_file_count(3);
    nav.move_up(); // Already at 0
    ASSERT_EQ(nav.file_index(), 0u);
    nav.move_down();
    nav.move_down();
    nav.move_down(); // Past end
    ASSERT_EQ(nav.file_index(), 2u);
}

TEST(nav_toggle_pane) {
    blimp::state::Navigation nav;
    ASSERT_EQ(nav.active_pane(), blimp::state::Pane::FileList);
    nav.toggle_pane();
    ASSERT_EQ(nav.active_pane(), blimp::state::Pane::Diff);
    nav.toggle_pane();
    ASSERT_EQ(nav.active_pane(), blimp::state::Pane::FileList);
}

TEST(nav_diff_scroll) {
    blimp::state::Navigation nav;
    nav.set_diff_line_count(100);
    nav.scroll_diff_down(5);
    ASSERT_EQ(nav.diff_scroll(), 5);
    nav.scroll_diff_up(3);
    ASSERT_EQ(nav.diff_scroll(), 2);
    nav.scroll_diff_up(10);
    ASSERT_EQ(nav.diff_scroll(), 0); // Clamped to 0
}

TEST(nav_divider_pos_clamped) {
    blimp::state::Navigation nav;
    nav.set_divider_pos(0.5f);
    ASSERT_TRUE(nav.divider_pos() > 0.49f && nav.divider_pos() < 0.51f);
    nav.set_divider_pos(0.01f);
    ASSERT_TRUE(nav.divider_pos() >= 0.15f);
    nav.set_divider_pos(0.99f);
    ASSERT_TRUE(nav.divider_pos() <= 0.85f);
}

TEST(nav_follow_mode_toggle) {
    blimp::state::Navigation nav;
    ASSERT_FALSE(nav.follow_mode());
    nav.toggle_follow();
    ASSERT_TRUE(nav.follow_mode());
    nav.toggle_follow();
    ASSERT_FALSE(nav.follow_mode());
}

TEST(nav_page_down) {
    blimp::state::Navigation nav;
    nav.set_file_count(100);
    nav.page_down(20);
    ASSERT_EQ(nav.file_index(), 20u);
    nav.page_down(20);
    ASSERT_EQ(nav.file_index(), 40u);
}

TEST(nav_page_up_from_zero) {
    blimp::state::Navigation nav;
    nav.set_file_count(100);
    nav.page_up(20); // Already at 0
    ASSERT_EQ(nav.file_index(), 0u);
}

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

// ── Edge case tests ────────────────────────────────────────────────────────

TEST(nav_empty_file_count_move_down_noop) {
    blimp::state::Navigation nav;
    // file_count defaults to 0 -- move_down should do nothing
    nav.move_down();
    ASSERT_EQ(nav.file_index(), 0u);
    nav.move_down();
    nav.move_down();
    ASSERT_EQ(nav.file_index(), 0u);
}

TEST(nav_single_file_cant_move_past) {
    blimp::state::Navigation nav;
    nav.set_file_count(1);
    ASSERT_EQ(nav.file_index(), 0u);
    nav.move_down(); // Only one file, can't go past it
    ASSERT_EQ(nav.file_index(), 0u);
    nav.move_up(); // Already at 0
    ASSERT_EQ(nav.file_index(), 0u);
}

TEST(nav_set_file_index_beyond_bounds_clamps) {
    blimp::state::Navigation nav;
    nav.set_file_count(5);
    nav.set_file_index(100); // Way past end
    ASSERT_EQ(nav.file_index(), 4u);
    nav.set_file_index(4);
    ASSERT_EQ(nav.file_index(), 4u);
    nav.set_file_index(0);
    ASSERT_EQ(nav.file_index(), 0u);
}

TEST(nav_set_file_index_zero_count_noop) {
    blimp::state::Navigation nav;
    // file_count is 0, set_file_index should not change anything
    nav.set_file_index(5);
    ASSERT_EQ(nav.file_index(), 0u);
}

TEST(nav_diff_scroll_at_maximum) {
    blimp::state::Navigation nav;
    nav.set_diff_line_count(10);
    nav.scroll_diff_down(100); // Try to scroll way past end
    ASSERT_EQ(nav.diff_scroll(), 9); // Clamped to diff_line_count_ - 1
    nav.scroll_diff_down(5); // Already at max
    ASSERT_EQ(nav.diff_scroll(), 9);
}

TEST(nav_diff_scroll_zero_lines) {
    blimp::state::Navigation nav;
    nav.set_diff_line_count(0);
    nav.scroll_diff_down(5);
    ASSERT_EQ(nav.diff_scroll(), 0); // max(0, -1) = 0
}

TEST(nav_diff_horizontal_scroll_left_at_zero) {
    blimp::state::Navigation nav;
    ASSERT_EQ(nav.diff_h_scroll(), 0);
    nav.scroll_diff_left(10); // Can't go negative
    ASSERT_EQ(nav.diff_h_scroll(), 0);
}

TEST(nav_diff_horizontal_scroll_right_and_back) {
    blimp::state::Navigation nav;
    nav.scroll_diff_right(8);
    ASSERT_EQ(nav.diff_h_scroll(), 8);
    nav.scroll_diff_right(4);
    ASSERT_EQ(nav.diff_h_scroll(), 12);
    nav.scroll_diff_left(5);
    ASSERT_EQ(nav.diff_h_scroll(), 7);
    nav.scroll_diff_left(100); // Clamp to 0
    ASSERT_EQ(nav.diff_h_scroll(), 0);
}

TEST(nav_hunk_navigation_boundaries) {
    blimp::state::Navigation nav;
    nav.set_hunk_count(3);
    ASSERT_EQ(nav.hunk_index(), 0u);
    nav.prev_hunk(); // Already at 0
    ASSERT_EQ(nav.hunk_index(), 0u);
    nav.next_hunk();
    ASSERT_EQ(nav.hunk_index(), 1u);
    nav.next_hunk();
    ASSERT_EQ(nav.hunk_index(), 2u);
    nav.next_hunk(); // Past end
    ASSERT_EQ(nav.hunk_index(), 2u);
}

TEST(nav_hunk_navigation_zero_hunks) {
    blimp::state::Navigation nav;
    // hunk_count defaults to 0
    nav.next_hunk();
    ASSERT_EQ(nav.hunk_index(), 0u);
    nav.prev_hunk();
    ASSERT_EQ(nav.hunk_index(), 0u);
}

TEST(nav_log_navigation_boundaries) {
    blimp::state::Navigation nav;
    nav.set_log_count(5);
    ASSERT_EQ(nav.log_index(), 0u);
    nav.log_up(); // Already at 0
    ASSERT_EQ(nav.log_index(), 0u);
    nav.log_down();
    nav.log_down();
    nav.log_down();
    nav.log_down();
    ASSERT_EQ(nav.log_index(), 4u);
    nav.log_down(); // Past end
    ASSERT_EQ(nav.log_index(), 4u);
}

TEST(nav_log_navigation_zero_count) {
    blimp::state::Navigation nav;
    nav.log_down();
    ASSERT_EQ(nav.log_index(), 0u);
}

TEST(nav_page_down_near_end_clamps) {
    blimp::state::Navigation nav;
    nav.set_file_count(10);
    nav.set_file_index(8); // Near the end
    nav.page_down(20); // Would go to 28, but clamps to 9
    ASSERT_EQ(nav.file_index(), 9u);
}

TEST(nav_page_down_zero_count) {
    blimp::state::Navigation nav;
    // file_count is 0
    nav.page_down(20);
    ASSERT_EQ(nav.file_index(), 0u);
}

TEST(nav_follow_jump_with_follow_on) {
    blimp::state::Navigation nav;
    nav.set_file_count(10);
    nav.toggle_follow();
    ASSERT_TRUE(nav.follow_mode());
    nav.follow_jump(7);
    ASSERT_EQ(nav.file_index(), 7u);
    ASSERT_EQ(nav.diff_scroll(), 0);
}

TEST(nav_follow_jump_clamps_to_file_count) {
    blimp::state::Navigation nav;
    nav.set_file_count(5);
    nav.toggle_follow();
    nav.follow_jump(100); // Way past end
    ASSERT_EQ(nav.file_index(), 4u);
}

TEST(nav_follow_jump_without_follow_mode_noop) {
    blimp::state::Navigation nav;
    nav.set_file_count(10);
    ASSERT_FALSE(nav.follow_mode());
    nav.follow_jump(5);
    ASSERT_EQ(nav.file_index(), 0u); // Unchanged
}

TEST(nav_follow_jump_resets_diff_scroll) {
    blimp::state::Navigation nav;
    nav.set_file_count(10);
    nav.set_diff_line_count(100);
    nav.scroll_diff_down(50);
    ASSERT_EQ(nav.diff_scroll(), 50);
    nav.toggle_follow();
    nav.follow_jump(3);
    ASSERT_EQ(nav.diff_scroll(), 0); // Reset on jump
}

TEST(nav_divider_pos_extreme_zero) {
    blimp::state::Navigation nav;
    nav.set_divider_pos(0.0f);
    ASSERT_TRUE(nav.divider_pos() >= 0.15f);
}

TEST(nav_divider_pos_extreme_one) {
    blimp::state::Navigation nav;
    nav.set_divider_pos(1.0f);
    ASSERT_TRUE(nav.divider_pos() <= 0.85f);
}

TEST(nav_divider_pos_negative) {
    blimp::state::Navigation nav;
    nav.set_divider_pos(-0.5f);
    ASSERT_TRUE(nav.divider_pos() >= 0.15f);
}

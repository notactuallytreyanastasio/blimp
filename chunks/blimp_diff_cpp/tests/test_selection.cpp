#include "state/selection.h"
#include "test_framework.h"

TEST(selection_initial_inactive) {
    blimp::state::LineSelection sel;
    ASSERT_FALSE(sel.active());
}

TEST(selection_start) {
    blimp::state::LineSelection sel;
    sel.start(5);
    ASSERT_TRUE(sel.active());
    ASSERT_EQ(sel.anchor().value(), 5u);
    ASSERT_EQ(sel.cursor().value(), 5u);
}

TEST(selection_extend) {
    blimp::state::LineSelection sel;
    sel.start(5);
    sel.extend(10);
    auto [lo, hi] = sel.range();
    ASSERT_EQ(lo, 5u);
    ASSERT_EQ(hi, 10u);
}

TEST(selection_extend_backwards) {
    blimp::state::LineSelection sel;
    sel.start(10);
    sel.extend(3);
    auto [lo, hi] = sel.range();
    ASSERT_EQ(lo, 3u);
    ASSERT_EQ(hi, 10u);
}

TEST(selection_contains) {
    blimp::state::LineSelection sel;
    sel.start(5);
    sel.extend(10);
    ASSERT_TRUE(sel.contains(5));
    ASSERT_TRUE(sel.contains(7));
    ASSERT_TRUE(sel.contains(10));
    ASSERT_FALSE(sel.contains(4));
    ASSERT_FALSE(sel.contains(11));
}

TEST(selection_clear) {
    blimp::state::LineSelection sel;
    sel.start(5);
    sel.extend(10);
    sel.clear();
    ASSERT_FALSE(sel.active());
    ASSERT_FALSE(sel.contains(7));
}

// ── Edge case tests ────────────────────────────────────────────────────────

TEST(selection_single_point_no_extend) {
    blimp::state::LineSelection sel;
    sel.start(5);
    ASSERT_TRUE(sel.active());
    auto [lo, hi] = sel.range();
    ASSERT_EQ(lo, 5u);
    ASSERT_EQ(hi, 5u);
    // Single point should contain only that line
    ASSERT_TRUE(sel.contains(5));
    ASSERT_FALSE(sel.contains(4));
    ASSERT_FALSE(sel.contains(6));
}

TEST(selection_range_after_clear_is_zero) {
    blimp::state::LineSelection sel;
    sel.start(3);
    sel.extend(8);
    sel.clear();
    auto [lo, hi] = sel.range();
    ASSERT_EQ(lo, 0u);
    ASSERT_EQ(hi, 0u);
}

TEST(selection_extend_without_start_noop) {
    blimp::state::LineSelection sel;
    // Never called start -- extend should be a no-op
    sel.extend(10);
    ASSERT_FALSE(sel.active());
    ASSERT_FALSE(sel.cursor().has_value());
    auto [lo, hi] = sel.range();
    ASSERT_EQ(lo, 0u);
    ASSERT_EQ(hi, 0u);
}

TEST(selection_multiple_extends_cursor_moves_anchor_stays) {
    blimp::state::LineSelection sel;
    sel.start(5);
    ASSERT_EQ(sel.anchor().value(), 5u);
    ASSERT_EQ(sel.cursor().value(), 5u);

    sel.extend(10);
    ASSERT_EQ(sel.anchor().value(), 5u);
    ASSERT_EQ(sel.cursor().value(), 10u);

    sel.extend(20);
    ASSERT_EQ(sel.anchor().value(), 5u);
    ASSERT_EQ(sel.cursor().value(), 20u);

    sel.extend(2);
    ASSERT_EQ(sel.anchor().value(), 5u);
    ASSERT_EQ(sel.cursor().value(), 2u);

    auto [lo, hi] = sel.range();
    ASSERT_EQ(lo, 2u);
    ASSERT_EQ(hi, 5u);
}

TEST(selection_contains_on_empty_always_false) {
    blimp::state::LineSelection sel;
    ASSERT_FALSE(sel.contains(0));
    ASSERT_FALSE(sel.contains(1));
    ASSERT_FALSE(sel.contains(100));
    ASSERT_FALSE(sel.contains(SIZE_MAX));
}

TEST(selection_start_at_zero) {
    blimp::state::LineSelection sel;
    sel.start(0);
    ASSERT_TRUE(sel.active());
    ASSERT_EQ(sel.anchor().value(), 0u);
    sel.extend(0);
    ASSERT_TRUE(sel.contains(0));
    ASSERT_FALSE(sel.contains(1));
}

TEST(selection_restart_after_clear) {
    blimp::state::LineSelection sel;
    sel.start(5);
    sel.extend(10);
    sel.clear();
    sel.start(20);
    sel.extend(25);
    auto [lo, hi] = sel.range();
    ASSERT_EQ(lo, 20u);
    ASSERT_EQ(hi, 25u);
    ASSERT_FALSE(sel.contains(5));
    ASSERT_TRUE(sel.contains(22));
}

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

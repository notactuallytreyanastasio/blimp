#include "state/selection.h"

namespace blimp::state {

void LineSelection::start(size_t line) {
    anchor_ = line;
    cursor_ = line;
}

void LineSelection::extend(size_t line) {
    if (anchor_) cursor_ = line;
}

void LineSelection::clear() {
    anchor_.reset();
    cursor_.reset();
}

std::pair<size_t, size_t> LineSelection::range() const {
    if (!anchor_ || !cursor_) return {0, 0};
    return {std::min(*anchor_, *cursor_), std::max(*anchor_, *cursor_)};
}

bool LineSelection::contains(size_t line) const {
    if (!active()) return false;
    auto [lo, hi] = range();
    return line >= lo && line <= hi;
}

} // namespace blimp::state

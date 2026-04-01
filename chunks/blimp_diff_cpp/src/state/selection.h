#pragma once
#include <algorithm>
#include <cstddef>
#include <optional>
#include <utility>

namespace blimp::state {

class LineSelection {
public:
    void start(size_t line);
    void extend(size_t line);
    void clear();

    [[nodiscard]] bool active() const { return anchor_.has_value(); }
    [[nodiscard]] std::optional<size_t> anchor() const { return anchor_; }
    [[nodiscard]] std::optional<size_t> cursor() const { return cursor_; }

    // Returns (start, end) inclusive, normalized
    [[nodiscard]] std::pair<size_t, size_t> range() const;
    [[nodiscard]] bool contains(size_t line) const;

private:
    std::optional<size_t> anchor_;
    std::optional<size_t> cursor_;
};

} // namespace blimp::state

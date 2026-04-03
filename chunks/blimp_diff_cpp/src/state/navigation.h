#pragma once
#include <cstddef>
#include <optional>
#include <string>

namespace blimp::state {

enum class Pane : uint8_t { FileList, Diff };

class Navigation {
public:
    // File list
    [[nodiscard]] size_t file_index() const { return file_index_; }
    void set_file_count(size_t n) { file_count_ = n; }
    void move_down();
    void move_up();
    void page_down(size_t page_size);
    void page_up(size_t page_size);
    void set_file_index(size_t i);

    // Diff scroll/cursor
    [[nodiscard]] int diff_scroll() const { return diff_scroll_; }
    [[nodiscard]] int diff_cursor() const { return diff_cursor_; }
    [[nodiscard]] int diff_h_scroll() const { return diff_h_scroll_; }
    void set_diff_line_count(int n) { diff_line_count_ = n; }
    [[nodiscard]] int diff_line_count_debug() const { return diff_line_count_; }
    void set_diff_visible_height(int h) { diff_visible_h_ = h; }
    void reset_diff_scroll();
    void scroll_diff_down(int amount = 1);
    void scroll_diff_up(int amount = 1);
    void scroll_diff_left(int amount = 4);
    void scroll_diff_right(int amount = 4);

    // Hunk navigation
    [[nodiscard]] size_t hunk_index() const { return hunk_index_; }
    void set_hunk_count(size_t n) { hunk_count_ = n; }
    void next_hunk();
    void prev_hunk();

    // Pane focus
    [[nodiscard]] Pane active_pane() const { return active_pane_; }
    void toggle_pane();
    void set_active_pane(Pane p) { active_pane_ = p; }

    // Follow mode
    [[nodiscard]] bool follow_mode() const { return follow_mode_; }
    void toggle_follow() { follow_mode_ = !follow_mode_; }
    void follow_jump(size_t file_idx);

    // Pane divider position (fraction 0.0-1.0)
    [[nodiscard]] float divider_pos() const { return divider_pos_; }
    void set_divider_pos(float p);

    // Log
    [[nodiscard]] size_t log_index() const { return log_index_; }
    void set_log_count(size_t n) { log_count_ = n; }
    void log_down();
    void log_up();

private:
    size_t file_index_ = 0;
    size_t file_count_ = 0;

    int diff_scroll_ = 0;
    int diff_cursor_ = 0;
    int diff_h_scroll_ = 0;
    int diff_line_count_ = 0;
    int diff_visible_h_ = 40;

    size_t hunk_index_ = 0;
    size_t hunk_count_ = 0;

    Pane active_pane_ = Pane::FileList;
    bool follow_mode_ = false;

    float divider_pos_ = 0.3f;

    size_t log_index_ = 0;
    size_t log_count_ = 0;
};

} // namespace blimp::state

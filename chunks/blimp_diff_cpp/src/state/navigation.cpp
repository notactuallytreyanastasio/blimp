#include "state/navigation.h"
#include <algorithm>

namespace blimp::state {

void Navigation::move_down() {
    if (file_count_ > 0 && file_index_ + 1 < file_count_)
        file_index_++;
}

void Navigation::move_up() {
    if (file_index_ > 0)
        file_index_--;
}

void Navigation::page_down(size_t page_size) {
    if (file_count_ == 0) return;
    file_index_ = std::min(file_index_ + page_size, file_count_ - 1);
}

void Navigation::page_up(size_t page_size) {
    if (page_size > file_index_)
        file_index_ = 0;
    else
        file_index_ -= page_size;
}

void Navigation::set_file_index(size_t i) {
    if (file_count_ > 0)
        file_index_ = std::min(i, file_count_ - 1);
}

void Navigation::scroll_diff_down(int amount) {
    diff_cursor_ = std::min(diff_cursor_ + amount,
                            std::max(0, diff_line_count_ - 1));
    // Keep cursor centered in viewport
    int half = diff_visible_h_ / 2;
    diff_scroll_ = std::max(0, diff_cursor_ - half);
}

void Navigation::scroll_diff_up(int amount) {
    diff_cursor_ = std::max(0, diff_cursor_ - amount);
    int half = diff_visible_h_ / 2;
    diff_scroll_ = std::max(0, diff_cursor_ - half);
}

void Navigation::scroll_diff_left(int amount) {
    diff_h_scroll_ = std::max(0, diff_h_scroll_ - amount);
}

void Navigation::scroll_diff_right(int amount) {
    diff_h_scroll_ += amount;
}

void Navigation::next_hunk() {
    if (hunk_count_ > 0 && hunk_index_ + 1 < hunk_count_)
        hunk_index_++;
}

void Navigation::prev_hunk() {
    if (hunk_index_ > 0)
        hunk_index_--;
}

void Navigation::toggle_pane() {
    active_pane_ = (active_pane_ == Pane::FileList) ? Pane::Diff : Pane::FileList;
}

void Navigation::follow_jump(size_t file_idx) {
    if (follow_mode_ && file_count_ > 0) {
        file_index_ = std::min(file_idx, file_count_ - 1);
        diff_scroll_ = 0;
    }
}

void Navigation::set_divider_pos(float p) {
    divider_pos_ = std::clamp(p, 0.15f, 0.85f);
}

void Navigation::log_down() {
    if (log_count_ > 0 && log_index_ + 1 < log_count_)
        log_index_++;
}

void Navigation::log_up() {
    if (log_index_ > 0)
        log_index_--;
}

} // namespace blimp::state

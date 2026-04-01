#include "git/watcher.h"
#include <filesystem>

namespace blimp::git {

namespace fs = std::filesystem;

Watcher::Watcher(fs::path repo_root, std::chrono::milliseconds debounce)
    : root_(std::move(repo_root))
    , debounce_(debounce)
    , last_index_mtime_(get_index_mtime())
    , last_head_mtime_(std::filesystem::file_time_type::min())
    , thread_([this] { watch_loop(); }) {}

Watcher::~Watcher() {
    stop();
}

void Watcher::stop() {
    running_ = false;
    if (thread_.joinable()) thread_.join();
}

bool Watcher::poll_changed() {
    return changed_.exchange(false);
}

fs::file_time_type Watcher::get_index_mtime() const {
    auto index_path = root_ / ".git" / "index";
    std::error_code ec;
    auto mtime = fs::last_write_time(index_path, ec);
    if (ec) return fs::file_time_type::min();
    return mtime;
}

void Watcher::watch_loop() {
    while (running_) {
        std::this_thread::sleep_for(debounce_);

        auto current = get_index_mtime();
        if (current != last_index_mtime_) {
            last_index_mtime_ = current;
            changed_ = true;
        }

        // Also check HEAD and refs
        auto head_path = root_ / ".git" / "HEAD";
        std::error_code ec;
        auto head_mtime = fs::last_write_time(head_path, ec);
        if (!ec) {
            if (head_mtime != last_head_mtime_) {
                last_head_mtime_ = head_mtime;
                changed_ = true;
            }
        }
    }
}

} // namespace blimp::git

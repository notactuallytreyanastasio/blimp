#pragma once
#include <atomic>
#include <chrono>
#include <filesystem>
#include <functional>
#include <mutex>
#include <thread>

namespace blimp::git {

// File watcher using kqueue/stat polling.
// Checks .git/index mtime and working tree for changes.
class Watcher {
public:
    explicit Watcher(std::filesystem::path repo_root,
                     std::chrono::milliseconds debounce = std::chrono::milliseconds(200));
    ~Watcher();

    // Non-blocking: returns true if repo changed since last check
    [[nodiscard]] bool poll_changed();

    void stop();

private:
    void watch_loop();
    [[nodiscard]] std::filesystem::file_time_type get_index_mtime() const;

    std::filesystem::path root_;
    std::chrono::milliseconds debounce_;
    std::atomic<bool> changed_{false};
    std::atomic<bool> running_{true};
    std::filesystem::file_time_type last_index_mtime_;
    std::filesystem::file_time_type last_head_mtime_;
    std::thread thread_;
};

} // namespace blimp::git

#pragma once
#include <atomic>
#include <chrono>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

namespace blimp::git {

// File watcher using kqueue (macOS) to watch for filesystem changes.
// Watches the working tree and .git directory for any modifications.
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

    std::filesystem::path root_;
    std::chrono::milliseconds debounce_;
    std::atomic<bool> changed_{false};
    std::atomic<bool> running_{true};
    int kq_ = -1;  // kqueue fd
    std::vector<int> watch_fds_; // open fds being watched
    std::thread thread_;
};

} // namespace blimp::git

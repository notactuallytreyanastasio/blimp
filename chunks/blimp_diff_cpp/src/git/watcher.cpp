#include "git/watcher.h"

#include <fcntl.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>
#include <dirent.h>
#include <cstring>

namespace blimp::git {

namespace fs = std::filesystem;

// Recursively collect directory fds to watch.
// We watch directories (not individual files) for NOTE_WRITE events,
// which fire when any file in the directory is created/modified/deleted.
static void collect_dirs(const fs::path& dir, std::vector<int>& fds,
                          int max_depth = 4) {
    if (max_depth <= 0) return;

    int fd = open(dir.c_str(), O_RDONLY | O_DIRECTORY);
    if (fd < 0) return;
    fds.push_back(fd);

    std::error_code ec;
    for (auto& entry : fs::directory_iterator(dir, ec)) {
        if (ec) break;
        if (!entry.is_directory(ec)) continue;

        auto name = entry.path().filename().string();
        // Skip .git internals (we watch .git/index and .git/HEAD directly)
        // Skip build dirs and node_modules
        if (name == ".git" || name == "build" || name == "target" ||
            name == "node_modules" || name == ".deciduous") continue;

        collect_dirs(entry.path(), fds, max_depth - 1);
    }
}

Watcher::Watcher(fs::path repo_root, std::chrono::milliseconds debounce)
    : root_(std::move(repo_root))
    , debounce_(debounce) {

    kq_ = kqueue();
    if (kq_ < 0) return;

    // Watch .git/index and .git/HEAD specifically
    int idx_fd = open((root_ / ".git" / "index").c_str(), O_RDONLY);
    if (idx_fd >= 0) watch_fds_.push_back(idx_fd);

    int head_fd = open((root_ / ".git" / "HEAD").c_str(), O_RDONLY);
    if (head_fd >= 0) watch_fds_.push_back(head_fd);

    // Watch .git/refs directory for branch changes
    int refs_fd = open((root_ / ".git" / "refs").c_str(), O_RDONLY | O_DIRECTORY);
    if (refs_fd >= 0) watch_fds_.push_back(refs_fd);

    // Watch working tree directories (up to 4 levels deep)
    collect_dirs(root_, watch_fds_);

    // Register all fds with kqueue
    std::vector<struct kevent> changes;
    for (int fd : watch_fds_) {
        struct kevent ev{};
        EV_SET(&ev, static_cast<uintptr_t>(fd), EVFILT_VNODE,
               EV_ADD | EV_CLEAR,
               NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB,
               0, nullptr);
        changes.push_back(ev);
    }

    if (!changes.empty()) {
        kevent(kq_, changes.data(), static_cast<int>(changes.size()),
               nullptr, 0, nullptr);
    }

    thread_ = std::thread([this] { watch_loop(); });
}

Watcher::~Watcher() {
    stop();
}

void Watcher::stop() {
    running_ = false;
    if (thread_.joinable()) thread_.join();

    for (int fd : watch_fds_) {
        close(fd);
    }
    watch_fds_.clear();

    if (kq_ >= 0) {
        close(kq_);
        kq_ = -1;
    }
}

bool Watcher::poll_changed() {
    return changed_.exchange(false);
}

void Watcher::watch_loop() {
    if (kq_ < 0) return;

    struct kevent events[8];

    while (running_) {
        // Wait for filesystem events with a timeout so we can check running_
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = static_cast<long>(debounce_.count()) * 1'000'000;

        int n = kevent(kq_, nullptr, 0, events, 8, &ts);

        if (n > 0) {
            // Got filesystem events -- debounce by waiting a bit then signaling
            // (coalesces rapid changes like save-all)
            std::this_thread::sleep_for(debounce_);
            changed_ = true;

            // Drain any additional events that arrived during debounce
            struct timespec zero = {0, 0};
            while (kevent(kq_, nullptr, 0, events, 8, &zero) > 0) {}
        }
    }
}

} // namespace blimp::git

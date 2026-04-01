#pragma once
#include "types.h"
#include "git/runner.h"
#include "git/watcher.h"
#include "state/navigation.h"
#include "state/interaction.h"
#include "state/commit.h"
#include "state/selection.h"
#include "state/agent.h"
#include "ui/theme.h"
#include "ui/diff_cache.h"

#include <notcurses/notcurses.h>
#include <atomic>
#include <filesystem>
#include <future>
#include <mutex>
#include <string>
#include <vector>

namespace blimp {

// Result of a background git refresh -- built off-thread, swapped in on main thread
struct RefreshResult {
    std::vector<FileEntry> files;
    std::unordered_map<std::string, FileDiff> diffs;
    std::string branch;
};

class App {
public:
    explicit App(std::filesystem::path repo_root);

    // Run the main event loop. Returns exit code.
    int run();

private:
    // Synchronous refresh (blocks -- used for initial load and after mutations)
    void refresh_sync();
    // Kick off async refresh in background thread
    void refresh_async();
    // Check if async refresh is done and swap results in
    void poll_async_refresh();
    // Build a RefreshResult from git (safe to call from any thread)
    RefreshResult build_refresh();
    // Apply a RefreshResult to app state (main thread only)
    void apply_refresh(RefreshResult&& result);

    // Lightweight: just update nav counts for currently selected file (no git calls)
    void update_selected_diff();
    // Rebuild the diff cache when the selected file changes
    void rebuild_diff_cache();

    void merge_diffs(std::vector<FileDiff>& unstaged, std::vector<FileDiff>& staged,
                     std::unordered_map<std::string, FileDiff>& out);

    // Input dispatch
    void dispatch(state::Action action, uint32_t codepoint = 0);
    void dispatch_file_list(state::Action action);
    void dispatch_diff_view(state::Action action);
    void dispatch_log(state::Action action);
    void dispatch_committing(state::Action action, uint32_t codepoint);
    void dispatch_selecting(state::Action action);
    void dispatch_agent_prompt(state::Action action, uint32_t codepoint);
    void dispatch_agent_view(state::Action action);

    // Extract selected lines from diff cache as text
    std::vector<std::string> extract_selected_lines();

    // Event processing (extracted from run loop)
    void process_key(struct notcurses* nc, uint32_t key, const struct ncinput& ni);

    // Overlay plane management
    void show_overlay();
    void hide_overlay();

    // Git operations
    void do_stage();
    void do_unstage();
    void do_commit();

    std::filesystem::path root_;
    git::Runner runner_;
    git::Watcher watcher_;

    RepoState repo_;
    std::vector<LogEntry> log_entries_;

    state::Navigation nav_;
    state::Interaction interaction_;
    state::CommitState commit_state_;
    state::LineSelection selection_;
    state::AgentState agent_state_;
    ui::ThemeCycler themes_;

    ui::DiffCache diff_cache_;
    std::string status_message_;
    bool should_quit_ = false;

    // Overlay plane for commit dialog (created on enter, destroyed on exit)
    struct ncplane* overlay_plane_ = nullptr;
    struct ncplane* std_plane_ = nullptr; // cached for overlay creation

    // Async refresh
    std::future<RefreshResult> pending_refresh_;
    std::atomic<bool> refresh_in_flight_{false};
};

} // namespace blimp

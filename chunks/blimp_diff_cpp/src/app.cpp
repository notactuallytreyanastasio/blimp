#include "app.h"
#include "git/status_parser.h"
#include "git/diff_parser.h"
#include "git/log_parser.h"
#include "state/file_state.h"
#include "ui/renderer.h"
#include "ui/overlays.h"

#include <notcurses/notcurses.h>
#include <algorithm>
#include <csignal>
#include <cstdio>
#include <termios.h>
#include <unistd.h>

// Global signal flag -- set by SIGINT handler, checked by event loop
static std::atomic<bool> g_sigint_received{false};

static void sigint_handler(int) {
    g_sigint_received.store(true, std::memory_order_relaxed);
}

namespace blimp {

App::App(std::filesystem::path repo_root)
    : root_(std::move(repo_root))
    , runner_(root_)
    , watcher_(root_) {}

// ── Refresh: git data loading ───────────────────────────────────────────────

// Build refresh result from git. Safe to call from any thread (Runner uses popen
// which is thread-safe on POSIX).
RefreshResult App::build_refresh() {
    RefreshResult r;

    auto status_result = runner_.status();
    r.files = git::parse_status(status_result.stdout_str);

    auto branch_result = runner_.branch();
    r.branch = branch_result.stdout_str;
    if (!r.branch.empty() && r.branch.back() == '\n')
        r.branch.pop_back();

    auto diff_result = runner_.diff();
    auto staged_result = runner_.diff_staged();

    auto unstaged_diffs = git::parse_diff(diff_result.stdout_str);
    auto staged_diffs = git::parse_diff(staged_result.stdout_str);

    merge_diffs(unstaged_diffs, staged_diffs, r.diffs);

    // Pre-diff all untracked files so navigation never blocks
    for (const auto& file : r.files) {
        if (file.unstaged == Status::Untracked &&
            r.diffs.find(file.path) == r.diffs.end()) {
            auto untracked = runner_.diff_untracked(file.path);
            auto parsed = git::parse_diff(untracked.stdout_str);
            for (auto& d : parsed) {
                d.path = file.path;
                r.diffs[d.path] = std::move(d);
            }
        }
    }

    return r;
}

// Apply a refresh result to the app state. Main thread only.
void App::apply_refresh(RefreshResult&& result) {
    // Detect which file changed for follow mode
    std::string prev_selected;
    if (!repo_.files.empty() && nav_.file_index() < repo_.files.size()) {
        prev_selected = repo_.files[nav_.file_index()].path;
    }

    repo_.files = std::move(result.files);
    repo_.diffs = std::move(result.diffs);
    repo_.branch = std::move(result.branch);
    nav_.set_file_count(repo_.files.size());

    // Follow mode: jump to the first file whose diff changed
    if (nav_.follow_mode() && !repo_.files.empty()) {
        // Find a file that has a diff and wasn't previously selected
        for (size_t i = 0; i < repo_.files.size(); i++) {
            const auto& path = repo_.files[i].path;
            if (path != prev_selected && repo_.diffs.count(path)) {
                nav_.follow_jump(i);
                break;
            }
        }
    }

    // Force cache rebuild since diffs may have changed
    diff_cache_.clear();
    update_selected_diff();
}

// Synchronous refresh -- blocks the event loop. Use only for initial load
// and after mutations (stage/unstage/commit) where we need the result immediately.
void App::refresh_sync() {
    apply_refresh(build_refresh());
}

// Kick off an async refresh. Non-blocking -- the result will be picked up
// by poll_async_refresh() in the event loop.
void App::refresh_async() {
    if (refresh_in_flight_) return; // already running
    refresh_in_flight_ = true;
    pending_refresh_ = std::async(std::launch::async, [this] {
        return build_refresh();
    });
}

// Check if the async refresh is done. If so, swap results in.
void App::poll_async_refresh() {
    if (!refresh_in_flight_) return;
    if (!pending_refresh_.valid()) {
        refresh_in_flight_ = false;
        return;
    }
    // Check if future is ready (non-blocking)
    auto status = pending_refresh_.wait_for(std::chrono::milliseconds(0));
    if (status == std::future_status::ready) {
        apply_refresh(pending_refresh_.get());
        refresh_in_flight_ = false;
    }
}

// Lightweight: just recompute line/hunk counts for the selected file.
// Zero subprocess calls. Pure index math.
void App::update_selected_diff() {
    if (repo_.files.empty()) return;
    size_t idx = nav_.file_index();
    if (idx >= repo_.files.size()) return;

    auto it = repo_.diffs.find(repo_.files[idx].path);
    if (it != repo_.diffs.end()) {
        int total = 0;
        for (const auto& hunk : it->second.hunks) {
            total += 1 + static_cast<int>(hunk.lines.size());
        }
        nav_.set_diff_line_count(total);
        nav_.set_hunk_count(it->second.hunks.size());
    } else {
        nav_.set_diff_line_count(0);
        nav_.set_hunk_count(0);
    }

    rebuild_diff_cache();
}

void App::rebuild_diff_cache() {
    if (repo_.files.empty()) {
        diff_cache_.clear();
        return;
    }
    size_t idx = nav_.file_index();
    if (idx >= repo_.files.size()) return;

    const auto& path = repo_.files[idx].path;

    // Only rebuild if the file changed
    if (diff_cache_.cached_path() == path) return;

    auto it = repo_.diffs.find(path);
    if (it != repo_.diffs.end()) {
        diff_cache_.rebuild(it->second, path);
    } else {
        diff_cache_.clear();
    }
}

void App::merge_diffs(std::vector<FileDiff>& unstaged, std::vector<FileDiff>& staged,
                      std::unordered_map<std::string, FileDiff>& out) {
    out.clear();

    for (auto& d : unstaged) {
        out[d.path] = std::move(d);
    }

    for (auto& d : staged) {
        auto it = out.find(d.path);
        if (it == out.end()) {
            out[d.path] = std::move(d);
        } else {
            for (auto& hunk : d.hunks) {
                it->second.hunks.push_back(std::move(hunk));
            }
            it->second.additions += d.additions;
            it->second.deletions += d.deletions;
        }
    }
}

// ── Overlay plane management ────────────────────────────────────────────────

void App::show_overlay() {
    if (overlay_plane_) return; // already showing
    if (!std_plane_) return;
    unsigned rows, cols;
    ncplane_dim_yx(std_plane_, &rows, &cols);
    overlay_plane_ = ui::create_overlay_plane(
        std_plane_, static_cast<int>(rows), static_cast<int>(cols));
}

void App::hide_overlay() {
    if (overlay_plane_) {
        ncplane_destroy(overlay_plane_);
        overlay_plane_ = nullptr;
    }
}

// ── Input dispatch ──────────────────────────────────────────────────────────

void App::dispatch(state::Action action, uint32_t codepoint) {
    if (action == state::Action::Quit) {
        should_quit_ = true;
        return;
    }
    if (action == state::Action::CycleTheme) {
        themes_.next();
        // No cache clear needed -- highlighting is per-frame from theme
        return;
    }

    switch (interaction_.mode()) {
        case state::Mode::FileList:
            dispatch_file_list(action);
            break;
        case state::Mode::DiffView:
            dispatch_diff_view(action);
            break;
        case state::Mode::LogList:
        case state::Mode::LogDetail:
            dispatch_log(action);
            break;
        case state::Mode::Committing:
            dispatch_committing(action, codepoint);
            break;
        case state::Mode::Selecting:
            dispatch_selecting(action);
            break;
        case state::Mode::AgentPrompt:
            dispatch_agent_prompt(action, codepoint);
            break;
        case state::Mode::AgentView:
            dispatch_agent_view(action);
            break;
        default:
            break;
    }
}

void App::dispatch_file_list(state::Action action) {
    switch (action) {
        case state::Action::Down:
            nav_.move_down();
            update_selected_diff();
            break;
        case state::Action::Up:
            nav_.move_up();
            update_selected_diff();
            break;
        case state::Action::Select:
            interaction_.set_mode(state::Mode::DiffView);
            break;
        case state::Action::Back:
            should_quit_ = true;
            break;
        case state::Action::TogglePane:
            nav_.toggle_pane();
            if (nav_.active_pane() == state::Pane::Diff)
                interaction_.set_mode(state::Mode::DiffView);
            break;
        case state::Action::PageDown:
            nav_.page_down(20);
            update_selected_diff();
            break;
        case state::Action::PageUp:
            nav_.page_up(20);
            update_selected_diff();
            break;
        case state::Action::ToggleFollow:
            nav_.toggle_follow();
            break;
        case state::Action::OpenLog:
            interaction_.set_mode(state::Mode::LogList);
            {
                auto log_result = runner_.log_oneline();
                log_entries_ = git::parse_log(log_result.stdout_str);
                nav_.set_log_count(log_entries_.size());
            }
            break;
        case state::Action::OpenEditor:
            if (!repo_.files.empty() && nav_.file_index() < repo_.files.size()) {
                runner_.open_editor(repo_.files[nav_.file_index()].path);
            }
            break;
        case state::Action::StageFile:
            do_stage();
            break;
        case state::Action::UnstageFile:
            do_unstage();
            break;
        case state::Action::EnterAmend:
            interaction_.set_mode(state::Mode::Committing);
            commit_state_.begin_editing();
            show_overlay();
            break;
        case state::Action::OpenAgent:
            // Switch to agent tab if agent is active
            if (agent_state_.phase() != state::AgentPhase::Idle) {
                interaction_.set_mode(state::Mode::AgentView);
            }
            break;
        default:
            break;
    }
}

void App::dispatch_diff_view(state::Action action) {
    switch (action) {
        case state::Action::Down:
            nav_.scroll_diff_down();
            break;
        case state::Action::Up:
            nav_.scroll_diff_up();
            break;
        case state::Action::Back:
            interaction_.set_mode(state::Mode::FileList);
            nav_.set_active_pane(state::Pane::FileList);
            break;
        case state::Action::TogglePane:
            nav_.toggle_pane();
            if (nav_.active_pane() == state::Pane::FileList)
                interaction_.set_mode(state::Mode::FileList);
            break;
        case state::Action::PageDown:
            nav_.scroll_diff_down(20);
            break;
        case state::Action::PageUp:
            nav_.scroll_diff_up(20);
            break;
        case state::Action::ScrollLeft:
            nav_.scroll_diff_left();
            break;
        case state::Action::ScrollRight:
            nav_.scroll_diff_right();
            break;
        case state::Action::EnterVisual:
            interaction_.set_mode(state::Mode::Selecting);
            selection_.start(static_cast<size_t>(nav_.diff_scroll()));
            break;
        case state::Action::StageFile:
            do_stage();
            break;
        case state::Action::UnstageFile:
            do_unstage();
            break;
        default:
            break;
    }
}

void App::dispatch_log(state::Action action) {
    switch (action) {
        case state::Action::Down:
            nav_.log_down();
            break;
        case state::Action::Up:
            nav_.log_up();
            break;
        case state::Action::Back:
            interaction_.set_mode(state::Mode::FileList);
            break;
        default:
            break;
    }
}

void App::dispatch_committing(state::Action action, uint32_t codepoint) {
    switch (action) {
        case state::Action::Cancel:
            commit_state_.cancel();
            interaction_.set_mode(state::Mode::FileList);
            hide_overlay();
            break;
        case state::Action::Submit:
            do_commit();
            break;
        case state::Action::Backspace:
            commit_state_.backspace();
            break;
        case state::Action::NewLine:
            commit_state_.newline();
            break;
        case state::Action::InsertChar:
            if (codepoint >= 32 && codepoint < 127) {
                commit_state_.insert_char(static_cast<char>(codepoint));
            }
            break;
        default:
            break;
    }
}

void App::dispatch_selecting(state::Action action) {
    switch (action) {
        case state::Action::Down:
            nav_.scroll_diff_down();
            selection_.extend(static_cast<size_t>(nav_.diff_scroll()));
            break;
        case state::Action::Up:
            nav_.scroll_diff_up();
            selection_.extend(static_cast<size_t>(nav_.diff_scroll()));
            break;
        case state::Action::Select: {
            // Enter: capture selected lines and enter agent prompt
            auto lines = extract_selected_lines();
            if (!lines.empty()) {
                agent_state_.begin_prompting(std::move(lines));
                interaction_.set_mode(state::Mode::AgentPrompt);
                show_overlay(); // reuse overlay for prompt input
            }
            break;
        }
        case state::Action::Back:
            selection_.clear();
            interaction_.set_mode(state::Mode::DiffView);
            break;
        default:
            break;
    }
}

void App::dispatch_agent_prompt(state::Action action, uint32_t codepoint) {
    switch (action) {
        case state::Action::Cancel:
            agent_state_.cancel();
            selection_.clear();
            hide_overlay();
            interaction_.set_mode(state::Mode::DiffView);
            break;
        case state::Action::Submit: {
            // Ctrl+Enter: spawn claude and switch to agent view
            std::string path;
            if (!repo_.files.empty() && nav_.file_index() < repo_.files.size()) {
                path = repo_.files[nav_.file_index()].path;
            }
            agent_state_.submit(path);
            selection_.clear();
            hide_overlay();
            interaction_.set_mode(state::Mode::AgentView);
            break;
        }
        case state::Action::Backspace:
            agent_state_.backspace();
            break;
        case state::Action::NewLine:
            agent_state_.newline();
            break;
        case state::Action::InsertChar:
            if (codepoint >= 32 && codepoint < 127) {
                agent_state_.insert_char(static_cast<char>(codepoint));
            }
            break;
        default:
            break;
    }
}

void App::dispatch_agent_view(state::Action action) {
    switch (action) {
        case state::Action::Down:
            agent_state_.scroll_response_down();
            break;
        case state::Action::Up:
            agent_state_.scroll_response_up();
            break;
        case state::Action::PageDown:
            agent_state_.scroll_response_down(20);
            break;
        case state::Action::PageUp:
            agent_state_.scroll_response_up(20);
            break;
        case state::Action::Back:
            // Esc: dismiss agent, go back to diff
            agent_state_.dismiss();
            interaction_.set_mode(state::Mode::DiffView);
            break;
        case state::Action::TogglePane:
            // Tab: flip back to diff view (agent keeps running)
            interaction_.set_mode(state::Mode::DiffView);
            nav_.set_active_pane(state::Pane::FileList);
            break;
        default:
            break;
    }
}

std::vector<std::string> App::extract_selected_lines() {
    std::vector<std::string> result;
    if (!selection_.active()) return result;

    auto [lo, hi] = selection_.range();
    const auto& lines = diff_cache_.lines();

    for (size_t i = lo; i <= hi && i < lines.size(); i++) {
        const auto& cl = lines[i];
        if (cl.type == ui::CachedLine::HunkHeader) continue;

        // Reconstruct the line text with +/- prefix
        char prefix = ' ';
        if (cl.kind == LineKind::Addition) prefix = '+';
        else if (cl.kind == LineKind::Deletion) prefix = '-';

        std::string text;
        text += prefix;
        text += cl.text;
        result.push_back(std::move(text));
    }
    return result;
}

// ── Git mutations ───────────────────────────────────────────────────────────

void App::do_stage() {
    if (repo_.files.empty()) return;
    size_t idx = nav_.file_index();
    if (idx >= repo_.files.size()) return;

    auto cmd = state::stage_command(repo_.files[idx]);
    if (cmd) {
        (void)runner_.stage(repo_.files[idx].path);
        refresh_sync(); // must be sync -- UI needs to reflect the change now
        status_message_ = "Staged: " + repo_.files[idx].path;
    }
}

void App::do_unstage() {
    if (repo_.files.empty()) return;
    size_t idx = nav_.file_index();
    if (idx >= repo_.files.size()) return;

    auto cmd = state::unstage_command(repo_.files[idx]);
    if (cmd) {
        auto fstate = state::classify(repo_.files[idx]);
        if (fstate == state::FileState::StagedNew) {
            (void)runner_.unstage_rm_cached(repo_.files[idx].path);
        } else {
            (void)runner_.unstage_restore(repo_.files[idx].path);
        }
        refresh_sync();
        status_message_ = "Unstaged: " + repo_.files[idx].path;
    }
}

void App::do_commit() {
    if (!commit_state_.try_submit()) return;

    auto result = (interaction_.commit_mode() == state::CommitMode::Amend)
        ? runner_.commit_amend(commit_state_.message())
        : runner_.commit(commit_state_.message());

    if (result.exit_code != 0) {
        commit_state_.set_error(result.stderr_str);
    } else {
        commit_state_.succeed();
        interaction_.set_mode(state::Mode::FileList);
        hide_overlay();
        status_message_ = "Commit successful";
        refresh_sync();
    }
}

// ── Main event loop ─────────────────────────────────────────────────────────

int App::run() {
    // Save terminal state BEFORE notcurses touches it.
    // This is our ground truth for restoration.
    struct termios saved_termios;
    tcgetattr(STDIN_FILENO, &saved_termios);

    // Install our own SIGINT handler that just sets a flag.
    // We tell notcurses NOT to install its own quit handlers --
    // its handler calls notcurses_stop() which races with our cleanup.
    struct sigaction sa{};
    sa.sa_handler = sigint_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);

    struct notcurses_options opts{};
    opts.flags = NCOPTION_SUPPRESS_BANNERS | NCOPTION_NO_QUIT_SIGHANDLERS;

    struct notcurses* nc = notcurses_init(&opts, nullptr);
    if (!nc) {
        // Restore terminal in case init partially ran
        tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
        fprintf(stderr, "Failed to initialize notcurses\n");
        return 1;
    }

    notcurses_mice_enable(nc, NCMICE_ALL_EVENTS);
    struct ncplane* std_plane = notcurses_stdplane(nc);
    std_plane_ = std_plane; // cache for overlay creation

    refresh_sync();

    struct timespec timeout;
    timeout.tv_sec = 0;
    timeout.tv_nsec = 16'000'000; // 16ms

    struct ncinput ni;
    while (!should_quit_ && !g_sigint_received.load(std::memory_order_relaxed)) {
        poll_async_refresh();
        agent_state_.poll();

        ui::render(std_plane, overlay_plane_, themes_.current(), repo_, nav_,
                   interaction_, commit_state_, selection_, diff_cache_,
                   log_entries_, agent_state_, status_message_);
        notcurses_render(nc);

        uint32_t key = notcurses_get(nc, &timeout, &ni);

        // Check signal between get and processing
        if (g_sigint_received.load(std::memory_order_relaxed)) break;

        if (key != 0 && key != static_cast<uint32_t>(-1)) {
            if (ni.evtype != NCTYPE_RELEASE) {
                process_key(nc, key, ni);
            }

            struct timespec zero = {0, 0};
            while (!should_quit_ && !g_sigint_received.load(std::memory_order_relaxed)) {
                struct ncinput ni2;
                uint32_t k2 = notcurses_get(nc, &zero, &ni2);
                if (k2 == 0 || k2 == static_cast<uint32_t>(-1)) break;
                if (ni2.evtype == NCTYPE_RELEASE) continue;
                process_key(nc, k2, ni2);
            }
        }

        if (interaction_.mode() != state::Mode::Committing &&
            interaction_.mode() != state::Mode::AgentPrompt) {
            if (watcher_.poll_changed()) {
                refresh_async();
            }
        }
    }

    // ── Clean shutdown (always runs, even on SIGINT) ─────────────────────

    // Stop background work first
    watcher_.stop();
    hide_overlay();
    if (refresh_in_flight_ && pending_refresh_.valid()) {
        pending_refresh_.wait();
    }

    // Let notcurses tear down (alternate screen, cursor, etc.)
    notcurses_mice_disable(nc);
    notcurses_stop(nc);

    // Force-restore saved terminal state. This is the nuclear option:
    // no matter what notcurses or signal handlers did, the terminal
    // goes back to exactly how it was before we started.
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_termios);

    // Drain any in-flight escape sequence responses from the terminal
    // emulator (mouse tracking acks, kitty keyboard responses, etc.)
    {
        struct termios drain_t;
        tcgetattr(STDIN_FILENO, &drain_t);
        drain_t.c_lflag &= ~(ICANON | ECHO);
        drain_t.c_cc[VMIN] = 0;
        drain_t.c_cc[VTIME] = 1; // 100ms
        tcsetattr(STDIN_FILENO, TCSANOW, &drain_t);

        char junk[512];
        while (read(STDIN_FILENO, junk, sizeof(junk)) > 0) {}

        // Restore again after drain
        tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
    }

    return 0;
}

// Apply US keyboard shift map when notcurses reports base key + shift modifier
// separately (kitty keyboard protocol).
static uint32_t apply_shift(uint32_t key) {
    // Letters: a-z -> A-Z
    if (key >= 'a' && key <= 'z') return key - 32;

    // Number row and symbols
    switch (key) {
        case '1': return '!';
        case '2': return '@';
        case '3': return '#';
        case '4': return '$';
        case '5': return '%';
        case '6': return '^';
        case '7': return '&';
        case '8': return '*';
        case '9': return '(';
        case '0': return ')';
        case '-': return '_';
        case '=': return '+';
        case '[': return '{';
        case ']': return '}';
        case '\\': return '|';
        case ';': return ':';
        case '\'': return '"';
        case ',': return '<';
        case '.': return '>';
        case '/': return '?';
        case '`': return '~';
        default: return key;
    }
}

void App::process_key(struct notcurses* nc, uint32_t key, const struct ncinput& ni) {
    // Handle terminal resize -- SIGWINCH generates this synthetic event
    if (key == NCKEY_RESIZE) {
        unsigned rows, cols;
        notcurses_stddim_yx(nc, &rows, &cols);
        // Standard plane auto-resizes. Recreate overlay if active.
        if (overlay_plane_) {
            hide_overlay();
            show_overlay();
        }
        diff_cache_.clear();
        update_selected_diff();
        return;
    }

    bool ctrl = (ni.modifiers & NCKEY_MOD_CTRL) != 0;
    bool shift = (ni.modifiers & NCKEY_MOD_SHIFT) != 0;

    // Ctrl+L: full screen refresh (tradition per notcurses guide)
    if (ctrl && key == 'l') {
        notcurses_refresh(nc, nullptr, nullptr);
        return;
    }

    // Apply shift map for printable characters when modifier is reported separately
    uint32_t codepoint = key;
    if (shift && key >= 0x20 && key < 0x7f) {
        codepoint = apply_shift(key);
    }

    // Handle 'c' chord for commit (use codepoint so Shift+C doesn't trigger)
    if (key == 'c' && !shift && !ctrl &&
        interaction_.mode() == state::Mode::FileList) {
        if (interaction_.press_c()) {
            commit_state_.begin_editing();
            show_overlay();
            return;
        }
        return;
    }

    auto action = state::Interaction::action_for_key(
        interaction_.mode(), static_cast<int>(key), ctrl, shift);
    dispatch(action, codepoint);
}

} // namespace blimp

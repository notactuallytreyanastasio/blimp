#include "app.h"
#include "git/status_parser.h"
#include "git/diff_parser.h"
#include "git/log_parser.h"
#include "state/file_state.h"
#include "ui/renderer.h"

#include <notcurses/notcurses.h>
#include <algorithm>
#include <csignal>
#include <cstdio>
#include <termios.h>
#include <unistd.h>

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
    repo_.files = std::move(result.files);
    repo_.diffs = std::move(result.diffs);
    repo_.branch = std::move(result.branch);
    nav_.set_file_count(repo_.files.size());
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

// ── Input dispatch ──────────────────────────────────────────────────────────

void App::dispatch(state::Action action, uint32_t codepoint) {
    if (action == state::Action::Quit) {
        should_quit_ = true;
        return;
    }
    if (action == state::Action::CycleTheme) {
        themes_.next();
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
        case state::Action::Back:
            selection_.clear();
            interaction_.set_mode(state::Mode::DiffView);
            break;
        default:
            break;
    }
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
        status_message_ = "Commit successful";
        refresh_sync();
    }
}

// ── Main event loop ─────────────────────────────────────────────────────────

int App::run() {
    struct notcurses_options opts{};
    opts.flags = NCOPTION_SUPPRESS_BANNERS;

    struct notcurses* nc = notcurses_init(&opts, nullptr);
    if (!nc) {
        fprintf(stderr, "Failed to initialize notcurses\n");
        return 1;
    }

    notcurses_mice_enable(nc, NCMICE_ALL_EVENTS);
    struct ncplane* std_plane = notcurses_stdplane(nc);

    // Initial data load (sync -- nothing to show yet)
    refresh_sync();

    // 16ms timeout for ~60fps
    struct timespec timeout;
    timeout.tv_sec = 0;
    timeout.tv_nsec = 16'000'000;

    struct ncinput ni;
    while (!should_quit_) {
        // Check if async refresh completed
        poll_async_refresh();

        // Render
        ui::render(std_plane, themes_.current(), repo_, nav_, interaction_,
                   commit_state_, selection_, status_message_);
        notcurses_render(nc);

        // Block up to 16ms for first event
        uint32_t key = notcurses_get(nc, &timeout, &ni);

        if (key != 0 && key != static_cast<uint32_t>(-1)) {
            // Process this event
            if (ni.evtype != NCTYPE_RELEASE) {
                process_key(nc, key, ni);
            }

            // Drain all remaining pending events (non-blocking)
            struct timespec zero = {0, 0};
            while (!should_quit_) {
                struct ncinput ni2;
                uint32_t k2 = notcurses_get(nc, &zero, &ni2);
                if (k2 == 0 || k2 == static_cast<uint32_t>(-1)) break;
                if (ni2.evtype == NCTYPE_RELEASE) continue;
                process_key(nc, k2, ni2);
            }
        }

        // Watcher: kick off async refresh (never blocks the event loop)
        if (interaction_.mode() != state::Mode::Committing &&
            interaction_.mode() != state::Mode::AgentPrompt) {
            if (watcher_.poll_changed()) {
                refresh_async();
            }
        }
    }

    // ── Clean shutdown ────────────────────────────────────────────────────

    // 1. Stop watcher thread before touching the terminal
    watcher_.stop();

    // 2. Wait for any in-flight async refresh
    if (refresh_in_flight_ && pending_refresh_.valid()) {
        pending_refresh_.wait();
    }

    // 3. Disable mouse tracking before stopping notcurses
    notcurses_mice_disable(nc);

    // 4. Drain any buffered notcurses input
    {
        struct timespec zero = {0, 0};
        struct ncinput drain;
        while (notcurses_get(nc, &zero, &drain) > 0) {}
    }

    // 5. Let notcurses restore the terminal (alternate screen, cursor, etc.)
    notcurses_stop(nc);

    // 6. Flush any escape sequence responses still in-flight from the terminal.
    //    The terminal emulator may still be sending responses to our mouse/keyboard
    //    protocol queries. We need to eat those before the shell gets them.
    //    Brief raw-mode drain on stdin.
    {
        struct termios oldt, newt;
        tcgetattr(STDIN_FILENO, &oldt);
        newt = oldt;
        newt.c_lflag &= ~(ICANON | ECHO);
        newt.c_cc[VMIN] = 0;
        newt.c_cc[VTIME] = 1; // 100ms timeout
        tcsetattr(STDIN_FILENO, TCSANOW, &newt);

        char junk[256];
        while (read(STDIN_FILENO, junk, sizeof(junk)) > 0) {}

        tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
    }

    // 7. Belt-and-suspenders: write explicit terminal reset sequences
    //    in case notcurses missed any.
    fprintf(stdout,
        "\033[?1000l"  // disable mouse click tracking
        "\033[?1002l"  // disable mouse drag tracking
        "\033[?1003l"  // disable mouse all-movement tracking
        "\033[?1006l"  // disable SGR mouse mode
        "\033[?2004l"  // disable bracketed paste
        "\033[>4;0m"   // reset kitty keyboard flags
        "\033[?25h"    // show cursor
    );
    fflush(stdout);

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

void App::process_key(struct notcurses* /*nc*/, uint32_t key, const struct ncinput& ni) {
    bool ctrl = (ni.modifiers & NCKEY_MOD_CTRL) != 0;
    bool shift = (ni.modifiers & NCKEY_MOD_SHIFT) != 0;

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
            return;
        }
        return;
    }

    auto action = state::Interaction::action_for_key(
        interaction_.mode(), static_cast<int>(key), ctrl, shift);
    dispatch(action, codepoint);
}

} // namespace blimp

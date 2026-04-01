#include "git/runner.h"
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <sstream>

namespace blimp::git {

Runner::Runner(std::filesystem::path repo_root)
    : root_(std::move(repo_root)) {}

CmdResult Runner::run(const std::vector<std::string>& args,
                       bool allow_nonzero) const {
    std::ostringstream cmd;
    cmd << "cd " << root_.string() << " && git";
    for (const auto& arg : args) {
        cmd << " ";
        // Always single-quote args to handle spaces, newlines, special chars.
        // Single quotes protect everything except single quotes themselves.
        cmd << "'";
        for (char c : arg) {
            if (c == '\'') cmd << "'\\''";
            else cmd << c;
        }
        cmd << "'";
    }
    cmd << " 2>&1";

    CmdResult result;
    std::array<char, 4096> buffer{};
    FILE* pipe = popen(cmd.str().c_str(), "r");
    if (!pipe) {
        result.exit_code = -1;
        result.stderr_str = "Failed to open pipe";
        return result;
    }
    while (fgets(buffer.data(), buffer.size(), pipe) != nullptr) {
        result.stdout_str += buffer.data();
    }
    int raw = pclose(pipe);
    result.exit_code = WEXITSTATUS(raw);

    if (result.exit_code != 0 && !allow_nonzero) {
        result.stderr_str = result.stdout_str;
    }
    return result;
}

CmdResult Runner::status() const {
    return run({"status", "--porcelain=v1"});
}

CmdResult Runner::diff() const {
    return run({"diff"});
}

CmdResult Runner::diff_staged() const {
    return run({"diff", "--staged"});
}

CmdResult Runner::diff_untracked(const std::string& path) const {
    return run({"diff", "--no-index", "/dev/null", path}, /*allow_nonzero=*/true);
}

CmdResult Runner::branch() const {
    return run({"branch", "--show-current"});
}

CmdResult Runner::log_oneline(int count) const {
    return run({"log", "--oneline", "-n", std::to_string(count)});
}

CmdResult Runner::log_show(const std::string& hash) const {
    return run({"show", "--stat", hash});
}

CmdResult Runner::log_diff(const std::string& hash) const {
    return run({"show", "--format=", hash});
}

CmdResult Runner::stage(const std::string& path) const {
    return run({"add", path});
}

CmdResult Runner::unstage_restore(const std::string& path) const {
    return run({"restore", "--staged", path});
}

CmdResult Runner::unstage_rm_cached(const std::string& path) const {
    return run({"rm", "--cached", path});
}

CmdResult Runner::commit(const std::string& message) const {
    return run({"commit", "-m", message});
}

CmdResult Runner::commit_amend(const std::string& message) const {
    return run({"commit", "--amend", "-m", message});
}

void Runner::open_editor(const std::string& path) const {
    const char* editor = std::getenv("EDITOR");
    if (!editor) editor = "vim";
    std::string cmd = std::string(editor) + " " + (root_ / path).string() + " &";
    std::system(cmd.c_str());
}

} // namespace blimp::git

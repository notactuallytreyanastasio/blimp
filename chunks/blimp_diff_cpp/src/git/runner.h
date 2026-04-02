#pragma once
#include "types.h"
#include <filesystem>
#include <string>
#include <vector>

namespace blimp::git {

struct CmdResult {
    std::string stdout_str;
    std::string stderr_str;
    int exit_code = 0;
};

class Runner {
public:
    explicit Runner(std::filesystem::path repo_root);

    // Queries
    [[nodiscard]] CmdResult status() const;
    [[nodiscard]] CmdResult diff() const;
    [[nodiscard]] CmdResult diff_staged() const;
    [[nodiscard]] CmdResult diff_untracked(const std::string& path) const;
    [[nodiscard]] CmdResult branch() const;
    [[nodiscard]] CmdResult log_oneline(int count = 50) const;
    [[nodiscard]] CmdResult log_show(const std::string& hash) const;
    [[nodiscard]] CmdResult log_diff(const std::string& hash) const;

    // Mutations
    [[nodiscard]] CmdResult stage(const std::string& path) const;
    [[nodiscard]] CmdResult unstage_restore(const std::string& path) const;
    [[nodiscard]] CmdResult unstage_rm_cached(const std::string& path) const;
    [[nodiscard]] CmdResult commit(const std::string& message) const;
    [[nodiscard]] CmdResult commit_amend(const std::string& message) const;
    [[nodiscard]] CmdResult discard(const std::string& path) const;
    [[nodiscard]] CmdResult stash() const;
    [[nodiscard]] CmdResult stash_pop() const;

    void open_editor(const std::string& path) const;

private:
    [[nodiscard]] CmdResult run(const std::vector<std::string>& args,
                                 bool allow_nonzero = false) const;
    std::filesystem::path root_;
};

} // namespace blimp::git

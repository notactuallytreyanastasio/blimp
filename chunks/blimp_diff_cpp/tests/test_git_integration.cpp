#include "test_framework.h"
#include "git/runner.h"
#include "git/status_parser.h"
#include "git/diff_parser.h"
#include "git/log_parser.h"
#include "state/file_state.h"
#include "ui/diff_cache.h"

#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <unistd.h>
#include <fstream>
#include <string>

// RAII wrapper that cleans up a temp directory on destruction.
// Ensures cleanup even when ASSERT macros return early.
struct TempRepo {
    std::filesystem::path path;
    blimp::git::Runner runner;

    TempRepo() : path(make_temp()), runner(path) {
        // git init + configure user for commits
        run_sys("git init -b main");
        run_sys("git config user.name 'Test'");
        run_sys("git config user.email 'test@test.com'");
    }

    ~TempRepo() {
        std::filesystem::remove_all(path);
    }

    // No copies
    TempRepo(const TempRepo&) = delete;
    TempRepo& operator=(const TempRepo&) = delete;

    // Create a file with content
    void write_file(const std::string& name, const std::string& content) {
        std::ofstream f(path / name);
        f << content;
    }

    // Run a shell command inside the repo dir
    void run_sys(const std::string& cmd) {
        std::string full = "cd " + path.string() + " && " + cmd + " >/dev/null 2>&1";
        std::system(full.c_str());
    }

private:
    static std::filesystem::path make_temp() {
        std::string tmpl = "/tmp/blimp_test_XXXXXX";
        char* dir = mkdtemp(tmpl.data());
        if (!dir) {
            fprintf(stderr, "mkdtemp failed\n");
            std::abort();
        }
        return std::filesystem::path(dir);
    }
};

// ── Git Runner: status tests ────────────────────────────────────────────────

TEST(runner_status_empty_repo) {
    TempRepo repo;
    // Make an initial commit so the repo is truly "clean"
    repo.write_file("init", "");
    repo.run_sys("git add init && git commit -m 'init'");

    auto result = repo.runner.status();
    ASSERT_EQ(result.exit_code, 0);
    ASSERT_TRUE(result.stdout_str.empty());
}

TEST(runner_status_untracked) {
    TempRepo repo;
    repo.write_file("hello.txt", "hello world\n");

    auto result = repo.runner.status();
    ASSERT_EQ(result.exit_code, 0);
    ASSERT_TRUE(result.stdout_str.find("??") != std::string::npos);
    ASSERT_TRUE(result.stdout_str.find("hello.txt") != std::string::npos);
}

TEST(runner_status_staged) {
    TempRepo repo;
    repo.write_file("new_file.cpp", "#include <iostream>\n");
    repo.run_sys("git add new_file.cpp");

    auto result = repo.runner.status();
    ASSERT_EQ(result.exit_code, 0);
    // Porcelain v1: staged added = "A " in columns 0-1
    ASSERT_TRUE(result.stdout_str.find("A ") != std::string::npos);
    ASSERT_TRUE(result.stdout_str.find("new_file.cpp") != std::string::npos);
}

TEST(runner_status_modified) {
    TempRepo repo;
    repo.write_file("tracked.txt", "original\n");
    repo.run_sys("git add tracked.txt && git commit -m 'add tracked'");

    // Now modify it
    repo.write_file("tracked.txt", "modified content\n");

    auto result = repo.runner.status();
    ASSERT_EQ(result.exit_code, 0);
    // Porcelain v1: unstaged modified = " M"
    ASSERT_TRUE(result.stdout_str.find(" M") != std::string::npos);
    ASSERT_TRUE(result.stdout_str.find("tracked.txt") != std::string::npos);
}

// ── Git Runner: branch ──────────────────────────────────────────────────────

TEST(runner_branch) {
    TempRepo repo;
    // Need at least one commit for branch to show
    repo.write_file("init", "");
    repo.run_sys("git add init && git commit -m 'init'");

    auto result = repo.runner.branch();
    ASSERT_EQ(result.exit_code, 0);
    // We init with -b main, so it should be "main\n"
    std::string branch = result.stdout_str;
    // Trim trailing newline
    while (!branch.empty() && branch.back() == '\n') branch.pop_back();
    ASSERT_EQ(branch, "main");
}

// ── Git Runner: diff tests ──────────────────────────────────────────────────

TEST(runner_diff_modified) {
    TempRepo repo;
    repo.write_file("file.txt", "line one\n");
    repo.run_sys("git add file.txt && git commit -m 'initial'");

    repo.write_file("file.txt", "line one\nline two\n");

    auto result = repo.runner.diff();
    ASSERT_EQ(result.exit_code, 0);
    ASSERT_FALSE(result.stdout_str.empty());
    ASSERT_TRUE(result.stdout_str.find("+line two") != std::string::npos);
}

TEST(runner_diff_staged) {
    TempRepo repo;
    repo.write_file("file.txt", "original\n");
    repo.run_sys("git add file.txt && git commit -m 'initial'");

    repo.write_file("file.txt", "changed\n");
    repo.run_sys("git add file.txt");

    auto result = repo.runner.diff_staged();
    ASSERT_EQ(result.exit_code, 0);
    ASSERT_FALSE(result.stdout_str.empty());
    ASSERT_TRUE(result.stdout_str.find("-original") != std::string::npos);
    ASSERT_TRUE(result.stdout_str.find("+changed") != std::string::npos);
}

TEST(runner_diff_untracked) {
    TempRepo repo;
    repo.write_file("brand_new.txt", "fresh content\n");

    auto result = repo.runner.diff_untracked("brand_new.txt");
    // diff --no-index returns exit_code 1 when there are differences
    ASSERT_TRUE(result.exit_code == 0 || result.exit_code == 1);
    ASSERT_FALSE(result.stdout_str.empty());
    ASSERT_TRUE(result.stdout_str.find("+fresh content") != std::string::npos);
}

// ── Git Runner: commit tests ────────────────────────────────────────────────

TEST(runner_commit) {
    TempRepo repo;
    repo.write_file("to_commit.txt", "data\n");
    repo.run_sys("git add to_commit.txt");

    auto result = repo.runner.commit("test commit message");
    ASSERT_EQ(result.exit_code, 0);

    // Verify the repo is clean after commit
    auto status = repo.runner.status();
    ASSERT_TRUE(status.stdout_str.empty());
}

TEST(runner_commit_empty_fails) {
    TempRepo repo;
    // Need an initial commit so HEAD exists
    repo.write_file("init", "");
    repo.run_sys("git add init && git commit -m 'init'");

    // Try to commit with nothing staged -- should fail
    auto result = repo.runner.commit("empty commit");
    ASSERT_TRUE(result.exit_code != 0);
}

// ── Git Runner: log ─────────────────────────────────────────────────────────

TEST(runner_log) {
    TempRepo repo;
    repo.write_file("file.txt", "content\n");
    repo.run_sys("git add file.txt && git commit -m 'first commit'");

    auto result = repo.runner.log_oneline(10);
    ASSERT_EQ(result.exit_code, 0);
    ASSERT_FALSE(result.stdout_str.empty());
    ASSERT_TRUE(result.stdout_str.find("first commit") != std::string::npos);
}

// ── Git Runner: stage/unstage ───────────────────────────────────────────────

TEST(runner_stage_unstage) {
    TempRepo repo;
    repo.write_file("toggle.txt", "content\n");

    // Stage it
    auto stage_result = repo.runner.stage("toggle.txt");
    ASSERT_EQ(stage_result.exit_code, 0);

    // Verify staged
    auto status1 = repo.runner.status();
    ASSERT_TRUE(status1.stdout_str.find("A ") != std::string::npos);

    // Unstage it (new file, so use rm --cached)
    auto unstage_result = repo.runner.unstage_rm_cached("toggle.txt");
    ASSERT_EQ(unstage_result.exit_code, 0);

    // Verify back to untracked
    auto status2 = repo.runner.status();
    ASSERT_TRUE(status2.stdout_str.find("??") != std::string::npos);
}

// ── End-to-end: parse status from runner ────────────────────────────────────

TEST(e2e_parse_status_from_runner) {
    TempRepo repo;
    repo.write_file("untracked.txt", "hello\n");
    repo.write_file("staged.cpp", "int main() {}\n");
    repo.run_sys("git add staged.cpp");

    auto raw = repo.runner.status();
    ASSERT_EQ(raw.exit_code, 0);

    auto entries = blimp::git::parse_status(raw.stdout_str);
    ASSERT_EQ(entries.size(), 2u);

    // Find each entry (order may vary)
    blimp::FileEntry* untracked = nullptr;
    blimp::FileEntry* staged = nullptr;
    for (auto& e : entries) {
        if (e.path == "untracked.txt") untracked = &e;
        if (e.path == "staged.cpp") staged = &e;
    }

    ASSERT_TRUE(untracked != nullptr);
    ASSERT_EQ(untracked->unstaged, blimp::Status::Untracked);

    ASSERT_TRUE(staged != nullptr);
    ASSERT_EQ(staged->staged, blimp::Status::Added);
    ASSERT_EQ(staged->unstaged, blimp::Status::None);
}

// ── End-to-end: parse diff from runner ──────────────────────────────────────

TEST(e2e_parse_diff_from_runner) {
    TempRepo repo;
    repo.write_file("code.cpp", "int main() {\n    return 0;\n}\n");
    repo.run_sys("git add code.cpp && git commit -m 'initial'");

    // Modify the file
    repo.write_file("code.cpp", "int main() {\n    return 42;\n}\n");

    auto raw = repo.runner.diff();
    ASSERT_EQ(raw.exit_code, 0);
    ASSERT_FALSE(raw.stdout_str.empty());

    auto diffs = blimp::git::parse_diff(raw.stdout_str);
    ASSERT_EQ(diffs.size(), 1u);
    ASSERT_EQ(diffs[0].path, "code.cpp");
    ASSERT_FALSE(diffs[0].hunks.empty());

    // The hunk should contain the change from "return 0" to "return 42"
    bool found_deletion = false;
    bool found_addition = false;
    for (const auto& hunk : diffs[0].hunks) {
        for (const auto& line : hunk.lines) {
            if (line.kind == blimp::LineKind::Deletion &&
                line.content.find("return 0") != std::string::npos) {
                found_deletion = true;
            }
            if (line.kind == blimp::LineKind::Addition &&
                line.content.find("return 42") != std::string::npos) {
                found_addition = true;
            }
        }
    }
    ASSERT_TRUE(found_deletion);
    ASSERT_TRUE(found_addition);
}

// ── End-to-end: diff cache from parsed diff ─────────────────────────────────

TEST(e2e_diff_cache_from_parsed) {
    TempRepo repo;
    repo.write_file("data.txt", "alpha\nbeta\ngamma\n");
    repo.run_sys("git add data.txt && git commit -m 'initial'");

    repo.write_file("data.txt", "alpha\nBETA\ngamma\ndelta\n");

    auto raw = repo.runner.diff();
    ASSERT_EQ(raw.exit_code, 0);

    auto diffs = blimp::git::parse_diff(raw.stdout_str);
    ASSERT_EQ(diffs.size(), 1u);

    blimp::ui::DiffCache cache;
    blimp::CombinedDiff cd;
    cd.unstaged = diffs[0];
    cd.has_unstaged = true;
    cache.rebuild(cd, "data.txt");

    ASSERT_TRUE(cache.line_count() > 0);
    ASSERT_EQ(cache.cached_path(), "data.txt");

    // Should have at least one hunk header line
    bool found_header = false;
    bool found_content = false;
    for (const auto& line : cache.lines()) {
        if (line.type == blimp::ui::CachedLine::HunkHeader) found_header = true;
        if (line.type == blimp::ui::CachedLine::DiffContent) found_content = true;
    }
    ASSERT_TRUE(found_header);
    ASSERT_TRUE(found_content);

    // Verify additions and deletions are present
    bool has_addition = false;
    bool has_deletion = false;
    for (const auto& line : cache.lines()) {
        if (line.kind == blimp::LineKind::Addition) has_addition = true;
        if (line.kind == blimp::LineKind::Deletion) has_deletion = true;
    }
    ASSERT_TRUE(has_addition);
    ASSERT_TRUE(has_deletion);
}

// ── End-to-end: file state classification ───────────────────────────────────

TEST(e2e_file_state_classify) {
    TempRepo repo;

    // Create an untracked file
    repo.write_file("untracked.txt", "u\n");
    // Create a staged new file
    repo.write_file("staged_new.txt", "s\n");
    repo.run_sys("git add staged_new.txt");
    // Create a committed-then-modified file
    repo.write_file("modified.txt", "original\n");
    repo.run_sys("git add modified.txt && git commit -m 'add modified'");
    repo.write_file("modified.txt", "changed\n");

    auto raw = repo.runner.status();
    auto entries = blimp::git::parse_status(raw.stdout_str);

    for (const auto& entry : entries) {
        auto state = blimp::state::classify(entry);
        if (entry.path == "untracked.txt") {
            ASSERT_EQ(state, blimp::state::FileState::Untracked);
        } else if (entry.path == "staged_new.txt") {
            ASSERT_EQ(state, blimp::state::FileState::StagedNew);
        } else if (entry.path == "modified.txt") {
            ASSERT_EQ(state, blimp::state::FileState::UnstagedModified);
        }
    }
}

// ── End-to-end: stage_command returns correct args ──────────────────────────

TEST(e2e_stage_command) {
    TempRepo repo;

    // Untracked file -- should produce "add <path>"
    repo.write_file("new.txt", "x\n");
    // Modified tracked file -- should produce "add <path>"
    repo.write_file("tracked.txt", "orig\n");
    repo.run_sys("git add tracked.txt && git commit -m 'add'");
    repo.write_file("tracked.txt", "mod\n");
    // Staged file -- should produce nullopt (already staged)
    repo.write_file("already_staged.txt", "y\n");
    repo.run_sys("git add already_staged.txt");

    auto raw = repo.runner.status();
    auto entries = blimp::git::parse_status(raw.stdout_str);

    for (const auto& entry : entries) {
        auto cmd = blimp::state::stage_command(entry);
        if (entry.path == "new.txt") {
            ASSERT_TRUE(cmd.has_value());
            ASSERT_EQ(cmd->args.size(), 2u);
            ASSERT_EQ(cmd->args[0], "add");
            ASSERT_EQ(cmd->args[1], "new.txt");
        } else if (entry.path == "tracked.txt") {
            ASSERT_TRUE(cmd.has_value());
            ASSERT_EQ(cmd->args[0], "add");
        } else if (entry.path == "already_staged.txt") {
            // Already staged new file -- no stage command
            ASSERT_FALSE(cmd.has_value());
        }
    }
}

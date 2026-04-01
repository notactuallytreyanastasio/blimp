#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace blimp {

// ── File status from git porcelain ──────────────────────────────────────────

enum class Status : uint8_t {
    None,
    Added,
    Modified,
    Deleted,
    Renamed,
    Untracked,
};

struct FileEntry {
    std::string path;
    std::string orig_path; // for renames
    Status staged = Status::None;
    Status unstaged = Status::None;
};

// ── Diff structures ─────────────────────────────────────────────────────────

enum class LineKind : uint8_t {
    Context,
    Addition,
    Deletion,
};

struct DiffLine {
    LineKind kind = LineKind::Context;
    std::string content;
    std::optional<int> old_line;
    std::optional<int> new_line;
};

struct Hunk {
    std::string header;
    int old_start = 0;
    int old_count = 0;
    int new_start = 0;
    int new_count = 0;
    std::vector<DiffLine> lines;
    bool collapsed = false;
};

struct FileDiff {
    std::string path;
    std::vector<Hunk> hunks;
    bool binary = false;
    int additions = 0;
    int deletions = 0;
};

// ── Log ─────────────────────────────────────────────────────────────────────

struct LogEntry {
    std::string hash;
    std::string message;
};

// ── Repo state ──────────────────────────────────────────────────────────────

struct RepoState {
    std::vector<FileEntry> files;
    std::unordered_map<std::string, FileDiff> diffs;
    std::string branch;
};

// ── RGB color ───────────────────────────────────────────────────────────────

struct RGB {
    uint8_t r, g, b;
    [[nodiscard]] uint32_t to_channel() const {
        return (static_cast<uint32_t>(r) << 16) |
               (static_cast<uint32_t>(g) << 8) |
               static_cast<uint32_t>(b);
    }
};

} // namespace blimp

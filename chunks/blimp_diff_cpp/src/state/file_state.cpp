#include "state/file_state.h"

namespace blimp::state {

FileState classify(const FileEntry& entry) {
    bool has_staged = entry.staged != Status::None;
    bool has_unstaged = entry.unstaged != Status::None;

    if (entry.unstaged == Status::Untracked) return FileState::Untracked;
    if (entry.staged == Status::Renamed) return FileState::StagedRenamed;
    if (entry.staged == Status::Added && !has_unstaged) return FileState::StagedNew;
    if (entry.staged == Status::Deleted) return FileState::StagedDeleted;
    if (entry.unstaged == Status::Deleted) return FileState::UnstagedDeleted;

    if (has_staged && has_unstaged) return FileState::PartialModified;
    if (has_staged) return FileState::StagedModified;
    if (has_unstaged) return FileState::UnstagedModified;

    return FileState::UnstagedModified; // fallback
}

std::optional<GitCommand> stage_command(const FileEntry& entry) {
    auto state = classify(entry);
    switch (state) {
        case FileState::Untracked:
        case FileState::UnstagedModified:
        case FileState::PartialModified:
        case FileState::UnstagedDeleted:
            return GitCommand{{"add", entry.path}};
        default:
            return std::nullopt; // already staged or not stageable
    }
}

std::optional<GitCommand> unstage_command(const FileEntry& entry) {
    auto state = classify(entry);
    switch (state) {
        case FileState::StagedNew:
            return GitCommand{{"rm", "--cached", entry.path}};
        case FileState::StagedModified:
        case FileState::PartialModified:
        case FileState::StagedDeleted:
        case FileState::StagedRenamed:
            return GitCommand{{"restore", "--staged", entry.path}};
        default:
            return std::nullopt;
    }
}

} // namespace blimp::state

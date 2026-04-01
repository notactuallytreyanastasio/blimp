#pragma once
#include "types.h"
#include <optional>
#include <string>
#include <vector>

namespace blimp::state {

enum class FileState : uint8_t {
    Untracked,
    StagedNew,
    UnstagedModified,
    StagedModified,
    PartialModified,
    UnstagedDeleted,
    StagedDeleted,
    StagedRenamed,
};

struct GitCommand {
    std::vector<std::string> args;
};

[[nodiscard]] FileState classify(const FileEntry& entry);
[[nodiscard]] std::optional<GitCommand> stage_command(const FileEntry& entry);
[[nodiscard]] std::optional<GitCommand> unstage_command(const FileEntry& entry);

} // namespace blimp::state

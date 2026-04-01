#pragma once
#include "types.h"
#include <string>
#include <vector>

namespace blimp::git {

std::vector<FileEntry> parse_status(const std::string& output);

} // namespace blimp::git

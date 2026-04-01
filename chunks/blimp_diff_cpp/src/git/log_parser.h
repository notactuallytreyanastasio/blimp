#pragma once
#include "types.h"
#include <string>
#include <vector>

namespace blimp::git {

std::vector<LogEntry> parse_log(const std::string& output);

} // namespace blimp::git

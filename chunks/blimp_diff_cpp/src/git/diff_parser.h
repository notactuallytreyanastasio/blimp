#pragma once
#include "types.h"
#include <string>
#include <vector>

namespace blimp::git {

std::vector<FileDiff> parse_diff(const std::string& output);

} // namespace blimp::git

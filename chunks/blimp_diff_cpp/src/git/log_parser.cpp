#include "git/log_parser.h"
#include <sstream>

namespace blimp::git {

std::vector<LogEntry> parse_log(const std::string& output) {
    std::vector<LogEntry> entries;
    std::istringstream stream(output);
    std::string line;

    while (std::getline(stream, line)) {
        if (line.empty()) continue;
        auto space = line.find(' ');
        if (space == std::string::npos) {
            entries.push_back({line, ""});
        } else {
            entries.push_back({line.substr(0, space), line.substr(space + 1)});
        }
    }

    return entries;
}

} // namespace blimp::git

#include "git/status_parser.h"
#include <sstream>

namespace blimp::git {

namespace {

Status char_to_status(char c) {
    switch (c) {
        case 'A': return Status::Added;
        case 'M': return Status::Modified;
        case 'D': return Status::Deleted;
        case 'R': return Status::Renamed;
        case '?': return Status::Untracked;
        default:  return Status::None;
    }
}

} // namespace

std::vector<FileEntry> parse_status(const std::string& output) {
    std::vector<FileEntry> entries;
    std::istringstream stream(output);
    std::string line;

    while (std::getline(stream, line)) {
        if (line.size() < 4) continue;

        char x = line[0];
        char y = line[1];
        std::string path = line.substr(3);

        FileEntry entry;

        // Handle untracked
        if (x == '?' && y == '?') {
            entry.path = path;
            entry.unstaged = Status::Untracked;
            entries.push_back(std::move(entry));
            continue;
        }

        // Handle renames: "R  old -> new"
        if (x == 'R' || y == 'R') {
            auto arrow = path.find(" -> ");
            if (arrow != std::string::npos) {
                entry.orig_path = path.substr(0, arrow);
                entry.path = path.substr(arrow + 4);
            } else {
                entry.path = path;
            }
        } else {
            entry.path = path;
        }

        entry.staged = char_to_status(x);
        entry.unstaged = char_to_status(y);

        entries.push_back(std::move(entry));
    }

    return entries;
}

} // namespace blimp::git

#include "git/diff_parser.h"
#include <cstdlib>
#include <sstream>

namespace blimp::git {

namespace {

std::string extract_path(const std::string& line) {
    auto pos = line.find(" b/");
    if (pos != std::string::npos) {
        return line.substr(pos + 3);
    }
    return {};
}

// Parse "@@ -old_start,old_count +new_start,new_count @@"
// Returns true if this is a valid hunk header.
bool parse_hunk_header(const std::string& line, Hunk& hunk) {
    // Must start with "@@ -"
    if (line.size() < 4 || line[0] != '@' || line[1] != '@' ||
        line[2] != ' ' || line[3] != '-') {
        return false;
    }

    const char* p = line.c_str() + 4; // skip "@@ -"
    char* end = nullptr;

    // old_start
    long val = strtol(p, &end, 10);
    if (end == p) return false;
    hunk.old_start = static_cast<int>(val);
    p = end;

    // optional ,old_count
    if (*p == ',') {
        p++;
        val = strtol(p, &end, 10);
        if (end == p) return false;
        hunk.old_count = static_cast<int>(val);
        p = end;
    } else {
        hunk.old_count = 1;
    }

    // " +"
    if (*p != ' ' || *(p + 1) != '+') return false;
    p += 2;

    // new_start
    val = strtol(p, &end, 10);
    if (end == p) return false;
    hunk.new_start = static_cast<int>(val);
    p = end;

    // optional ,new_count
    if (*p == ',') {
        p++;
        val = strtol(p, &end, 10);
        if (end == p) return false;
        hunk.new_count = static_cast<int>(val);
        p = end;
    } else {
        hunk.new_count = 1;
    }

    // " @@"
    if (*p != ' ' || *(p + 1) != '@' || *(p + 2) != '@') return false;

    hunk.header = line;
    return true;
}

} // namespace

std::vector<FileDiff> parse_diff(const std::string& output) {
    std::vector<FileDiff> diffs;
    std::istringstream stream(output);
    std::string line;

    FileDiff* current = nullptr;
    Hunk* current_hunk = nullptr;
    int old_line = 0;
    int new_line = 0;

    while (std::getline(stream, line)) {
        // New file diff
        if (line.starts_with("diff --git ")) {
            diffs.emplace_back();
            current = &diffs.back();
            current->path = extract_path(line);
            current_hunk = nullptr;
            continue;
        }

        if (!current) continue;

        // Binary file
        if (line.starts_with("Binary files ")) {
            current->binary = true;
            continue;
        }

        // Better path from +++ line
        if (line.starts_with("+++ b/")) {
            current->path = line.substr(6);
            continue;
        }

        // Skip header lines
        if (line.starts_with("---") || line.starts_with("index ") ||
            line.starts_with("old mode") || line.starts_with("new mode") ||
            line.starts_with("new file") || line.starts_with("deleted file") ||
            line.starts_with("similarity") || line.starts_with("rename") ||
            line.starts_with("copy ")) {
            continue;
        }

        // Hunk header -- fast check: starts with "@@"
        if (line.size() >= 4 && line[0] == '@' && line[1] == '@') {
            Hunk hunk;
            if (parse_hunk_header(line, hunk)) {
                current->hunks.push_back(std::move(hunk));
                current_hunk = &current->hunks.back();
                old_line = current_hunk->old_start;
                new_line = current_hunk->new_start;
                continue;
            }
        }

        if (!current_hunk) continue;

        // Skip "no newline" marker
        if (line.starts_with("\\ No newline")) continue;

        // Diff lines
        if (line.empty()) {
            DiffLine dl;
            dl.kind = LineKind::Context;
            dl.old_line = old_line++;
            dl.new_line = new_line++;
            current_hunk->lines.push_back(std::move(dl));
        } else if (line[0] == '+') {
            DiffLine dl;
            dl.kind = LineKind::Addition;
            dl.content = line.substr(1);
            dl.new_line = new_line++;
            current_hunk->lines.push_back(std::move(dl));
            current->additions++;
        } else if (line[0] == '-') {
            DiffLine dl;
            dl.kind = LineKind::Deletion;
            dl.content = line.substr(1);
            dl.old_line = old_line++;
            current_hunk->lines.push_back(std::move(dl));
            current->deletions++;
        } else if (line[0] == ' ') {
            DiffLine dl;
            dl.kind = LineKind::Context;
            dl.content = line.substr(1);
            dl.old_line = old_line++;
            dl.new_line = new_line++;
            current_hunk->lines.push_back(std::move(dl));
        }
    }

    return diffs;
}

} // namespace blimp::git

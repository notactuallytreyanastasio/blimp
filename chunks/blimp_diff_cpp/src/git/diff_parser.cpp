#include "git/diff_parser.h"
#include <regex>
#include <sstream>

namespace blimp::git {

namespace {

// Extract path from "diff --git a/foo b/foo" or "+++ b/foo"
std::string extract_path(const std::string& line) {
    // Try "diff --git a/... b/..."
    auto pos = line.find(" b/");
    if (pos != std::string::npos) {
        return line.substr(pos + 3);
    }
    return {};
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

    // Regex for hunk headers: @@ -old_start,old_count +new_start,new_count @@
    static const std::regex hunk_re(
        R"(^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@)");

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

        // Skip --- and other header lines
        if (line.starts_with("---") || line.starts_with("index ") ||
            line.starts_with("old mode") || line.starts_with("new mode") ||
            line.starts_with("new file") || line.starts_with("deleted file") ||
            line.starts_with("similarity") || line.starts_with("rename") ||
            line.starts_with("copy ")) {
            continue;
        }

        // Hunk header
        std::smatch match;
        if (std::regex_search(line, match, hunk_re)) {
            current->hunks.emplace_back();
            current_hunk = &current->hunks.back();
            current_hunk->header = line;
            current_hunk->old_start = std::stoi(match[1].str());
            current_hunk->old_count = match[2].matched ? std::stoi(match[2].str()) : 1;
            current_hunk->new_start = std::stoi(match[3].str());
            current_hunk->new_count = match[4].matched ? std::stoi(match[4].str()) : 1;
            old_line = current_hunk->old_start;
            new_line = current_hunk->new_start;
            continue;
        }

        if (!current_hunk) continue;

        // Skip "no newline" marker
        if (line.starts_with("\\ No newline")) continue;

        // Diff lines
        if (line.empty()) {
            // Empty context line
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

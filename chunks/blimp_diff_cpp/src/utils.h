#pragma once
#include <string>
#include <string_view>
#include <vector>
#include <algorithm>
#include <sstream>
#include <cctype>

namespace blimp::utils {

// Word-wrap a string to fit within max_width columns.
// Respects existing newlines and breaks at word boundaries.
inline std::vector<std::string> word_wrap(std::string_view text, int max_width) {
    std::vector<std::string> lines;
    std::istringstream stream(std::string(text));
    std::string paragraph;

    while (std::getline(stream, paragraph)) {
        if (paragraph.empty()) {
            lines.emplace_back();
            continue;
        }

        std::string current_line;
        std::istringstream words(paragraph);
        std::string word;

        while (words >> word) {
            if (current_line.empty()) {
                current_line = word;
            } else if (static_cast<int>(current_line.size() + 1 + word.size()) <= max_width) {
                current_line += " " + word;
            } else {
                lines.push_back(current_line);
                current_line = word;
            }
        }
        if (!current_line.empty()) {
            lines.push_back(current_line);
        }
    }

    if (lines.empty()) lines.emplace_back();
    return lines;
}

// Truncate a string with ellipsis if it exceeds max_width
inline std::string truncate(std::string_view s, int max_width) {
    if (static_cast<int>(s.size()) <= max_width) return std::string(s);
    if (max_width <= 3) return std::string(s.substr(0, max_width));
    return std::string(s.substr(0, max_width - 3)) + "...";
}

// Split a string by delimiter
inline std::vector<std::string> split(std::string_view s, char delimiter) {
    std::vector<std::string> parts;
    size_t start = 0;
    size_t end = s.find(delimiter);

    while (end != std::string_view::npos) {
        parts.emplace_back(s.substr(start, end - start));
        start = end + 1;
        end = s.find(delimiter, start);
    }
    parts.emplace_back(s.substr(start));
    return parts;
}

// Strip leading and trailing whitespace
inline std::string strip(std::string_view s) {
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) start++;
    size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) end--;
    return std::string(s.substr(start, end - start));
}

// Check if a string starts with a prefix (for pre-C++20)
inline bool starts_with(std::string_view s, std::string_view prefix) {
    return s.size() >= prefix.size() && s.substr(0, prefix.size()) == prefix;
}

// Join strings with a separator
inline std::string join(const std::vector<std::string>& parts, std::string_view sep) {
    if (parts.empty()) return {};
    std::string result = parts[0];
    for (size_t i = 1; i < parts.size(); i++) {
        result += sep;
        result += parts[i];
    }
    return result;
}

// Convert bytes to human-readable size
inline std::string human_size(size_t bytes) {
    const char* units[] = {"B", "KB", "MB", "GB"};
    int unit = 0;
    double size = static_cast<double>(bytes);
    while (size >= 1024.0 && unit < 3) {
        size /= 1024.0;
        unit++;
    }
    char buf[32];
    if (unit == 0) {
        snprintf(buf, sizeof(buf), "%zu B", bytes);
    } else {
        snprintf(buf, sizeof(buf), "%.1f %s", size, units[unit]);
    }
    return buf;
}

// Simple duration formatter
inline std::string format_duration_ms(int64_t ms) {
    if (ms < 1000) {
        return std::to_string(ms) + "ms";
    } else if (ms < 60000) {
        char buf[16];
        snprintf(buf, sizeof(buf), "%.1fs", ms / 1000.0);
        return buf;
    } else {
        int minutes = static_cast<int>(ms / 60000);
        int seconds = static_cast<int>((ms % 60000) / 1000);
        return std::to_string(minutes) + "m " + std::to_string(seconds) + "s";
    }
}

} // namespace blimp::utils

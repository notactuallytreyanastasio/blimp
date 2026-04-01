#include "app.h"
#include <clocale>
#include <filesystem>
#include <iostream>

int main(int argc, char* argv[]) {
    // MANDATORY: notcurses requires locale to be set before init.
    // Only US-ASCII and UTF-8 are supported.
    setlocale(LC_ALL, "");
    std::filesystem::path repo_root;

    if (argc > 1) {
        repo_root = argv[1];
    } else {
        repo_root = std::filesystem::current_path();
    }

    // Validate git repo
    if (!std::filesystem::exists(repo_root / ".git")) {
        std::cerr << "Not a git repository: " << repo_root << "\n";
        return 1;
    }

    blimp::App app(repo_root);
    return app.run();
}

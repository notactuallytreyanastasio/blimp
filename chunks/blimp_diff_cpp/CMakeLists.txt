cmake_minimum_required(VERSION 3.20)
project(blimp_diff VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Find notcurses
find_package(PkgConfig REQUIRED)
pkg_check_modules(NOTCURSES REQUIRED IMPORTED_TARGET notcurses++)
pkg_check_modules(NOTCURSES_CORE REQUIRED IMPORTED_TARGET notcurses-core)

# Main executable
add_executable(blimp_diff
    src/main.cpp
    src/app.cpp
    src/types.cpp
    src/git/runner.cpp
    src/git/status_parser.cpp
    src/git/diff_parser.cpp
    src/git/log_parser.cpp
    src/git/watcher.cpp
    src/state/navigation.cpp
    src/state/interaction.cpp
    src/state/commit.cpp
    src/state/selection.cpp
    src/state/file_state.cpp
    src/state/agent.cpp
    src/ui/renderer.cpp
    src/ui/file_list.cpp
    src/ui/diff_pane.cpp
    src/ui/log_view.cpp
    src/ui/status_bar.cpp
    src/ui/overlays.cpp
    src/ui/theme.cpp
    src/ui/highlight.cpp
    src/ui/diff_cache.cpp
    src/ui/agent_view.cpp
)

target_include_directories(blimp_diff PRIVATE src)
target_link_libraries(blimp_diff PRIVATE
    PkgConfig::NOTCURSES
    PkgConfig::NOTCURSES_CORE
)

# Tests
enable_testing()
add_executable(blimp_diff_test
    src/types.cpp
    src/git/status_parser.cpp
    src/git/diff_parser.cpp
    src/git/log_parser.cpp
    src/state/navigation.cpp
    src/state/interaction.cpp
    src/state/commit.cpp
    src/state/selection.cpp
    src/state/file_state.cpp
    tests/test_main.cpp
    tests/test_status_parser.cpp
    tests/test_diff_parser.cpp
    tests/test_log_parser.cpp
    tests/test_navigation.cpp
    tests/test_interaction.cpp
    tests/test_commit.cpp
    tests/test_selection.cpp
    tests/test_file_state.cpp
    tests/test_highlight.cpp
    tests/test_git_integration.cpp
    src/git/runner.cpp
    src/ui/highlight.cpp
    src/ui/theme.cpp
    src/ui/diff_cache.cpp
)

target_include_directories(blimp_diff_test PRIVATE src)
target_link_libraries(blimp_diff_test PRIVATE
    PkgConfig::NOTCURSES
    PkgConfig::NOTCURSES_CORE
)

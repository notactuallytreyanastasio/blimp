#pragma once
#include <chrono>
#include <cstdint>
#include <optional>

namespace blimp::state {

// ── Modes ───────────────────────────────────────────────────────────────────

enum class CommitMode : uint8_t { Commit, Amend };

enum class Mode : uint8_t {
    FileList,
    DiffView,
    LogList,
    LogDetail,
    Selecting,
    Committing,
    AgentPrompt,
    Dragging,
};

// ── Semantic actions ────────────────────────────────────────────────────────

enum class Action : uint8_t {
    Down,
    Up,
    Select,       // Enter
    Back,         // Esc / q
    TogglePane,   // Tab
    PageDown,
    PageUp,
    ScrollLeft,
    ScrollRight,
    ToggleFollow,
    OpenLog,
    OpenEditor,
    StageFile,
    UnstageFile,
    EnterCommit,
    EnterAmend,
    EnterVisual,
    CycleTheme,
    Quit,
    // Text input
    InsertChar,
    Backspace,
    NewLine,
    Submit,       // Ctrl+Enter
    Cancel,       // Esc in overlay
    // Mouse
    ClickFile,
    ClickDiff,
    DragStart,
    DragMove,
    DragEnd,
    ScrollUp,
    ScrollDown,
    None,
};

// ── Interaction state machine ───────────────────────────────────────────────

class Interaction {
public:
    [[nodiscard]] Mode mode() const { return mode_; }
    [[nodiscard]] CommitMode commit_mode() const { return commit_mode_; }

    void set_mode(Mode m) { mode_ = m; }

    // Chord detection: press 'c' twice within 400ms -> commit
    [[nodiscard]] bool press_c();

    // Map raw input to semantic action given current mode
    [[nodiscard]] static Action action_for_key(Mode mode, int key, bool ctrl, bool shift);

private:
    Mode mode_ = Mode::FileList;
    CommitMode commit_mode_ = CommitMode::Commit;
    std::optional<std::chrono::steady_clock::time_point> last_c_;
};

} // namespace blimp::state

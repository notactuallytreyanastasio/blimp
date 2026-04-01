#include "state/interaction.h"
#include <notcurses/nckeys.h>

namespace blimp::state {

bool Interaction::press_c() {
    auto now = std::chrono::steady_clock::now();
    if (last_c_ &&
        std::chrono::duration_cast<std::chrono::milliseconds>(now - *last_c_).count() < 400) {
        last_c_.reset();
        commit_mode_ = CommitMode::Commit;
        mode_ = Mode::Committing;
        return true;
    }
    last_c_ = now;
    return false;
}

Action Interaction::action_for_key(Mode mode, int key, bool ctrl, bool shift) {
    // Global: Ctrl+C always quits
    if (ctrl && key == 'c') return Action::Quit;

    // Overlay modes (Committing, AgentPrompt)
    if (mode == Mode::Committing || mode == Mode::AgentPrompt) {
        if (key == 27) return Action::Cancel; // Esc
        bool is_enter = (key == '\n' || key == '\r' || key == NCKEY_ENTER);
        if (ctrl && is_enter) return Action::Submit;
        if (is_enter) return Action::NewLine;
        if (key == 127 || key == NCKEY_BACKSPACE) return Action::Backspace;
        return Action::InsertChar;
    }

    // Normal modes
    switch (key) {
        case 'j': case NCKEY_DOWN:  return Action::Down;
        case 'k': case NCKEY_UP:    return Action::Up;
        case '\n': case NCKEY_ENTER: return Action::Select;
        case 'q':                    return Action::Back;
        case 27:                     return Action::Back; // Esc
        case '\t':                   return Action::TogglePane;
        case ' ':                    return Action::PageDown;
        case 'b':                    return Action::PageUp;
        case 'f':                    return Action::ToggleFollow;
        case 'l':
            if (mode == Mode::FileList) return Action::OpenLog;
            return Action::ScrollRight;
        case 'h':
            if (mode == Mode::DiffView) return Action::ScrollLeft;
            return Action::None;
        case 'H':                    return Action::ScrollLeft;
        case 'o':                    return Action::OpenEditor;
        case 's':                    return Action::StageFile;
        case 'u':                    return Action::UnstageFile;
        case 'a':                    return Action::EnterAmend;
        case 'v':                    return Action::EnterVisual;
        case 't':                    return Action::CycleTheme;
        case 'g':                    return Action::OpenAgent;
        default:                     return Action::None;
    }
}

} // namespace blimp::state

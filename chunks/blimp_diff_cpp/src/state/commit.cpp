#include "state/commit.h"

namespace blimp::state {

void CommitState::begin_editing() {
    phase_ = CommitPhase::Editing;
    message_.clear();
    error_.clear();
}

void CommitState::insert_char(char c) {
    if (phase_ == CommitPhase::Editing) {
        message_ += c;
    }
}

void CommitState::backspace() {
    if (phase_ == CommitPhase::Editing && !message_.empty()) {
        message_.pop_back();
    }
}

void CommitState::newline() {
    if (phase_ == CommitPhase::Editing) {
        message_ += '\n';
    }
}

bool CommitState::try_submit() {
    if (message_.empty() ||
        message_.find_first_not_of(" \t\n\r") == std::string::npos) {
        error_ = "Commit message cannot be empty";
        phase_ = CommitPhase::Error;
        return false;
    }
    phase_ = CommitPhase::Submitting;
    return true;
}

void CommitState::set_error(const std::string& err) {
    error_ = err;
    phase_ = CommitPhase::Error;
}

void CommitState::succeed() {
    reset();
}

void CommitState::cancel() {
    reset();
}

void CommitState::reset() {
    phase_ = CommitPhase::Idle;
    message_.clear();
    error_.clear();
}

} // namespace blimp::state

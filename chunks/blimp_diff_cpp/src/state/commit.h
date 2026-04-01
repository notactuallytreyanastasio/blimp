#pragma once
#include <string>

namespace blimp::state {

enum class CommitPhase : uint8_t {
    Idle,
    Editing,
    Submitting,
    Error,
};

class CommitState {
public:
    [[nodiscard]] CommitPhase phase() const { return phase_; }
    [[nodiscard]] const std::string& message() const { return message_; }
    [[nodiscard]] const std::string& error() const { return error_; }

    void begin_editing();
    void insert_char(char c);
    void backspace();
    void newline();

    // Returns true if message is valid and submission can proceed
    [[nodiscard]] bool try_submit();
    void set_error(const std::string& err);
    void succeed();
    void cancel();
    void reset();

private:
    CommitPhase phase_ = CommitPhase::Idle;
    std::string message_;
    std::string error_;
};

} // namespace blimp::state

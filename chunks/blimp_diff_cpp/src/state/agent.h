#pragma once
#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace blimp::state {

enum class AgentPhase : uint8_t {
    Idle,
    Prompting,   // User is typing the prompt
    Running,     // claude -p running in background thread
    Ready,       // Response received
    Error,
};

class AgentState {
public:
    ~AgentState();

    [[nodiscard]] AgentPhase phase() const { return phase_; }
    [[nodiscard]] const std::string& prompt() const { return prompt_; }
    [[nodiscard]] const std::vector<std::string>& selected_lines() const { return selected_lines_; }
    [[nodiscard]] const std::string& error() const { return error_; }
    [[nodiscard]] std::string response() const;

    [[nodiscard]] int response_scroll() const { return response_scroll_; }
    void scroll_response_down(int amount = 1);
    void scroll_response_up(int amount = 1);
    void set_response_line_count(int n) { response_line_count_ = n; }

    void begin_prompting(std::vector<std::string> lines);
    void insert_char(char c);
    void backspace();
    void newline();

    // Spawn claude -p in background thread
    void submit(const std::string& file_path);
    void poll(); // join thread if done
    void send_followup(const std::string& message);

    void cancel();
    void dismiss();
    void kill();

private:
    AgentPhase phase_ = AgentPhase::Idle;
    std::string prompt_;
    std::vector<std::string> selected_lines_;
    std::string error_;

    mutable std::mutex response_mu_;
    std::string response_;
    std::atomic<bool> response_complete_{false};
    std::thread worker_;

    int response_scroll_ = 0;
    int response_line_count_ = 0;
};

} // namespace blimp::state

#pragma once
#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace blimp::state {

enum class AgentPhase : uint8_t {
    Idle,
    Prompting,   // User is typing the initial prompt
    Running,     // Claude subprocess is running, streaming response
    Ready,       // Response received, can send follow-up
    Error,
};

// Manages an interactive claude subprocess.
// The subprocess stays alive for ongoing conversation.
class AgentState {
public:
    ~AgentState();

    [[nodiscard]] AgentPhase phase() const { return phase_; }
    [[nodiscard]] const std::string& prompt() const { return prompt_; }
    [[nodiscard]] const std::vector<std::string>& selected_lines() const { return selected_lines_; }
    [[nodiscard]] const std::string& error() const { return error_; }

    // Get response (thread-safe, may be partial while Running)
    [[nodiscard]] std::string response() const;

    // Response scroll position
    [[nodiscard]] int response_scroll() const { return response_scroll_; }
    void scroll_response_down(int amount = 1);
    void scroll_response_up(int amount = 1);
    void set_response_line_count(int n) { response_line_count_ = n; }

    // Phase: Idle → Prompting
    void begin_prompting(std::vector<std::string> lines);

    // Text input (Prompting phase)
    void insert_char(char c);
    void backspace();
    void newline();

    // Phase: Prompting → Running (spawns claude subprocess)
    void submit(const std::string& file_path);

    // Phase: Running → Ready (check if subprocess produced output)
    void poll();

    // Send a follow-up message to the running subprocess
    void send_followup(const std::string& message);

    // Phase: Prompting → Idle (cancel prompt)
    // Phase: Ready/Error → Idle (dismiss)
    void cancel();
    void dismiss();

    // Kill the subprocess
    void kill();

private:
    void reader_loop();

    AgentPhase phase_ = AgentPhase::Idle;
    std::string prompt_;
    std::vector<std::string> selected_lines_;
    std::string error_;

    // Subprocess
    FILE* write_pipe_ = nullptr;   // write to claude's stdin
    int read_fd_ = -1;             // read from claude's stdout
    pid_t child_pid_ = -1;

    // Response buffer (written by reader thread, read by main thread)
    mutable std::mutex response_mu_;
    std::string response_;
    std::atomic<bool> response_complete_{false};
    std::thread reader_thread_;

    int response_scroll_ = 0;
    int response_line_count_ = 0;
};

} // namespace blimp::state

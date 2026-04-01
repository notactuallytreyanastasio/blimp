#include "state/agent.h"

#include <array>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sstream>
#include <sys/wait.h>
#include <unistd.h>

namespace blimp::state {

AgentState::~AgentState() {
    kill();
}

std::string AgentState::response() const {
    std::lock_guard<std::mutex> lock(response_mu_);
    return response_;
}

void AgentState::scroll_response_down(int amount) {
    response_scroll_ = std::min(response_scroll_ + amount,
                                 std::max(0, response_line_count_ - 1));
}

void AgentState::scroll_response_up(int amount) {
    response_scroll_ = std::max(0, response_scroll_ - amount);
}

void AgentState::begin_prompting(std::vector<std::string> lines) {
    kill(); // clean up any previous session
    phase_ = AgentPhase::Prompting;
    prompt_.clear();
    selected_lines_ = std::move(lines);
    {
        std::lock_guard<std::mutex> lock(response_mu_);
        response_.clear();
    }
    error_.clear();
    response_scroll_ = 0;
    response_complete_ = false;
}

void AgentState::insert_char(char c) {
    if (phase_ == AgentPhase::Prompting || phase_ == AgentPhase::Ready) {
        prompt_ += c;
    }
}

void AgentState::backspace() {
    if ((phase_ == AgentPhase::Prompting || phase_ == AgentPhase::Ready) && !prompt_.empty()) {
        prompt_.pop_back();
    }
}

void AgentState::newline() {
    if (phase_ == AgentPhase::Prompting || phase_ == AgentPhase::Ready) {
        prompt_ += '\n';
    }
}

void AgentState::submit(const std::string& file_path) {
    if (phase_ != AgentPhase::Prompting) return;
    if (prompt_.empty()) return;

    // Build the initial message: selected code + user question
    std::ostringstream msg;
    if (!selected_lines_.empty()) {
        msg << "I'm looking at this code from " << file_path << ":\n\n```\n";
        for (const auto& line : selected_lines_) {
            msg << line << "\n";
        }
        msg << "```\n\n";
    }
    msg << prompt_;

    // Create pipes for stdin/stdout
    int stdin_pipe[2];  // parent writes to [1], child reads from [0]
    int stdout_pipe[2]; // child writes to [1], parent reads from [0]

    if (pipe(stdin_pipe) != 0 || pipe(stdout_pipe) != 0) {
        error_ = "Failed to create pipes";
        phase_ = AgentPhase::Error;
        return;
    }

    pid_t pid = fork();
    if (pid < 0) {
        error_ = "Failed to fork";
        phase_ = AgentPhase::Error;
        close(stdin_pipe[0]); close(stdin_pipe[1]);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        return;
    }

    if (pid == 0) {
        // Child process
        close(stdin_pipe[1]);   // close write end of stdin pipe
        close(stdout_pipe[0]);  // close read end of stdout pipe

        dup2(stdin_pipe[0], STDIN_FILENO);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stdout_pipe[1], STDERR_FILENO);

        close(stdin_pipe[0]);
        close(stdout_pipe[1]);

        // Exec claude in interactive mode
        execlp("claude", "claude", "--no-input", nullptr);

        // If exec fails
        _exit(127);
    }

    // Parent process
    close(stdin_pipe[0]);   // close read end of stdin pipe
    close(stdout_pipe[1]);  // close write end of stdout pipe

    child_pid_ = pid;
    write_pipe_ = fdopen(stdin_pipe[1], "w");
    read_fd_ = stdout_pipe[0];

    // Set read fd to non-blocking so poll() doesn't block
    int flags = fcntl(read_fd_, F_GETFL, 0);
    fcntl(read_fd_, F_SETFL, flags | O_NONBLOCK);

    // Send the initial message
    std::string initial = msg.str();
    if (write_pipe_) {
        fprintf(write_pipe_, "%s\n", initial.c_str());
        fflush(write_pipe_);
    }

    phase_ = AgentPhase::Running;
    response_complete_ = false;

    // Start reader thread
    reader_thread_ = std::thread([this] { reader_loop(); });
}

void AgentState::reader_loop() {
    std::array<char, 4096> buf{};
    while (!response_complete_) {
        ssize_t n = read(read_fd_, buf.data(), buf.size() - 1);
        if (n > 0) {
            buf[static_cast<size_t>(n)] = '\0';
            std::lock_guard<std::mutex> lock(response_mu_);
            response_ += buf.data();
        } else if (n == 0) {
            // EOF -- subprocess closed stdout
            break;
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // No data yet, sleep briefly
                usleep(50000); // 50ms
                continue;
            }
            break; // real error
        }
    }
    response_complete_ = true;
}

void AgentState::poll() {
    if (phase_ != AgentPhase::Running) return;

    // Check if child has exited
    if (child_pid_ > 0) {
        int status;
        pid_t result = waitpid(child_pid_, &status, WNOHANG);
        if (result == child_pid_) {
            // Child exited
            response_complete_ = true;
            if (reader_thread_.joinable()) reader_thread_.join();

            if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                phase_ = AgentPhase::Ready;
            } else {
                std::lock_guard<std::mutex> lock(response_mu_);
                if (response_.empty()) {
                    error_ = "claude exited with error";
                    phase_ = AgentPhase::Error;
                } else {
                    // Got some output before exit -- show it
                    phase_ = AgentPhase::Ready;
                }
            }
            child_pid_ = -1;
        }
    }

    // Even if child hasn't exited, check if we have response data
    // and it looks complete (heuristic: no new data for a bit)
}

void AgentState::send_followup(const std::string& message) {
    if (phase_ != AgentPhase::Ready || !write_pipe_) return;

    prompt_ = message;
    {
        std::lock_guard<std::mutex> lock(response_mu_);
        response_ += "\n\n---\n\n"; // separator
    }

    fprintf(write_pipe_, "%s\n", message.c_str());
    fflush(write_pipe_);

    phase_ = AgentPhase::Running;
    response_complete_ = false;

    // Restart reader if it finished
    if (reader_thread_.joinable()) reader_thread_.join();
    reader_thread_ = std::thread([this] { reader_loop(); });
}

void AgentState::cancel() {
    if (phase_ == AgentPhase::Prompting) {
        phase_ = AgentPhase::Idle;
        prompt_.clear();
        selected_lines_.clear();
    }
}

void AgentState::dismiss() {
    kill();
    phase_ = AgentPhase::Idle;
    prompt_.clear();
    selected_lines_.clear();
    {
        std::lock_guard<std::mutex> lock(response_mu_);
        response_.clear();
    }
    error_.clear();
    response_scroll_ = 0;
}

void AgentState::kill() {
    response_complete_ = true;

    if (write_pipe_) {
        fclose(write_pipe_);
        write_pipe_ = nullptr;
    }
    if (read_fd_ >= 0) {
        close(read_fd_);
        read_fd_ = -1;
    }
    if (child_pid_ > 0) {
        ::kill(child_pid_, SIGTERM);
        waitpid(child_pid_, nullptr, 0);
        child_pid_ = -1;
    }
    if (reader_thread_.joinable()) {
        reader_thread_.join();
    }
}

} // namespace blimp::state

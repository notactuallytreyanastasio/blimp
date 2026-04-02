#include "state/agent.h"

#include <array>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <fstream>
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
    kill();
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

    // Build the full prompt
    std::ostringstream msg;
    if (!selected_lines_.empty()) {
        msg << "I'm looking at this code from " << file_path << ":\n\n```\n";
        for (const auto& line : selected_lines_) {
            msg << line << "\n";
        }
        msg << "```\n\n";
    }
    msg << prompt_;

    std::string full_prompt = msg.str();

    phase_ = AgentPhase::Running;
    response_complete_ = false;

    // Run claude -p in a background thread using popen.
    // Write the prompt to a temp file to avoid shell escaping issues.
    worker_ = std::thread([this, full_prompt] {
        // Write prompt to temp file
        char tmppath[] = "/tmp/blimp_prompt_XXXXXX";
        int tmpfd = mkstemp(tmppath);
        if (tmpfd < 0) {
            error_ = "Failed to create temp file";
            phase_ = AgentPhase::Error;
            response_complete_ = true;
            return;
        }
        write(tmpfd, full_prompt.c_str(), full_prompt.size());
        close(tmpfd);

        // Run: claude -p "$(cat /tmp/blimp_prompt_XXX)" 2>&1
        std::string cmd = "cat '" + std::string(tmppath) + "' | claude -p 2>&1";

        FILE* pipe = popen(cmd.c_str(), "r");
        if (!pipe) {
            unlink(tmppath);
            error_ = "Failed to spawn claude";
            phase_ = AgentPhase::Error;
            response_complete_ = true;
            return;
        }

        std::array<char, 4096> buf{};
        while (fgets(buf.data(), buf.size(), pipe) != nullptr) {
            std::lock_guard<std::mutex> lock(response_mu_);
            response_ += buf.data();
        }

        int status = pclose(pipe);
        unlink(tmppath); // clean up temp file

        response_complete_ = true;

        std::lock_guard<std::mutex> lock(response_mu_);
        if (WEXITSTATUS(status) != 0 && response_.empty()) {
            error_ = "claude exited with error";
            phase_ = AgentPhase::Error;
        } else {
            phase_ = AgentPhase::Ready;
        }
    });
}

void AgentState::poll() {
    if (response_complete_ && worker_.joinable()) {
        worker_.join();
    }
}

void AgentState::send_followup(const std::string& message) {
    // For now, start a new claude -p call with the follow-up
    // TODO: use stream-json input/output for true conversation
    if (phase_ != AgentPhase::Ready) return;
    prompt_ = message;
    phase_ = AgentPhase::Prompting;
    submit(""); // re-submit with just the message, no code context
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
    if (worker_.joinable()) {
        worker_.join();
    }
}

} // namespace blimp::state

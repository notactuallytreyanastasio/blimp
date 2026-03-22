#!/usr/bin/env node
/**
 * Claude Agent SDK wrapper for TermDiff.
 *
 * Bridges the Claude Agent SDK's interactive permission model with
 * TermDiff's Erlang Port-based NDJSON protocol.
 *
 * Communication protocol:
 *   stdout -> Elixir: NDJSON events (same format as `claude -p --output-format stream-json`)
 *   stdin  <- Elixir: NDJSON commands (permission responses, user answers)
 *
 * Usage:
 *   node claude-agent-wrapper.mjs --prompt "..." --workspace /path [options]
 */

import { query } from "@anthropic-ai/claude-agent-sdk";
import { createInterface } from "readline";
import { randomUUID } from "crypto";
import { parseArgs } from "util";

// --- Argument parsing ---

const { values: args } = parseArgs({
  options: {
    prompt: { type: "string" },
    workspace: { type: "string" },
    model: { type: "string" },
    "max-turns": { type: "string" },
    "max-budget-usd": { type: "string" },
    "permission-mode": { type: "string" },
    "allowed-tools": { type: "string" },
    "disallowed-tools": { type: "string" },
    resume: { type: "string" },
    "append-system-prompt": { type: "string" },
    "system-prompt": { type: "string" },
  },
  strict: false,
});

if (!args.prompt) {
  process.stderr.write("Error: --prompt is required\n");
  process.exit(1);
}

// --- Stdin reader for permission responses ---

const rl = createInterface({ input: process.stdin, terminal: false });
const pendingResponses = new Map();

rl.on("line", (line) => {
  try {
    const msg = JSON.parse(line);
    if (msg.type === "permission_response" || msg.type === "user_answer") {
      const id = msg.tool_use_id || msg.request_id;
      const resolve = pendingResponses.get(id);
      if (resolve) {
        pendingResponses.delete(id);
        resolve(msg);
      }
    }
  } catch {
    // Ignore parse errors on stdin
  }
});

// --- Helpers ---

function emit(event) {
  process.stdout.write(JSON.stringify(event) + "\n");
}

function waitForResponse(requestId, timeoutMs = 300_000) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingResponses.delete(requestId);
      resolve({ behavior: "deny", message: "Permission request timed out (5 min)" });
    }, timeoutMs);

    pendingResponses.set(requestId, (response) => {
      clearTimeout(timer);
      resolve(response);
    });
  });
}

// --- Permission handler ---

async function canUseTool(toolName, input, context) {
  const requestId = context?.toolUseId || randomUUID();

  if (toolName === "AskUserQuestion") {
    // Forward clarifying question to Elixir
    emit({
      type: "ask_user_question",
      request_id: requestId,
      questions: input.questions,
    });

    const response = await waitForResponse(requestId);

    return {
      behavior: "allow",
      updatedInput: {
        questions: input.questions,
        answers: response.answers || {},
      },
    };
  }

  // Standard tool permission request
  emit({
    type: "permission_request",
    tool_use_id: requestId,
    tool_name: toolName,
    input: input,
  });

  const response = await waitForResponse(requestId);

  if (response.behavior === "allow") {
    return {
      behavior: "allow",
      updatedInput: response.updated_input || input,
    };
  }

  return {
    behavior: "deny",
    message: response.message || "Denied by user",
  };
}

// --- Build query options ---

const options = {};

if (args.workspace) options.workingDirectory = args.workspace;
if (args.model) options.model = args.model;
if (args["max-turns"]) options.maxTurns = parseInt(args["max-turns"], 10);
if (args["max-budget-usd"])
  options.maxBudgetUsd = parseFloat(args["max-budget-usd"]);
if (args["allowed-tools"])
  options.allowedTools = args["allowed-tools"].split(",").map((s) => s.trim());
if (args["disallowed-tools"])
  options.disallowedTools = args["disallowed-tools"]
    .split(",")
    .map((s) => s.trim());
if (args.resume) options.resume = args.resume;
if (args["system-prompt"]) options.systemPrompt = args["system-prompt"];
if (args["append-system-prompt"])
  options.appendSystemPrompt = args["append-system-prompt"];

// Filter permission mode - "interactive" is our custom mode handled by canUseTool
const permMode = args["permission-mode"];
if (permMode && permMode !== "interactive") {
  options.permissionMode = permMode;
}

// --- Run the agent ---

async function main() {
  try {
    for await (const event of query({
      prompt: args.prompt,
      options: {
        ...options,
        canUseTool,
      },
    })) {
      // Forward all events as NDJSON to Elixir
      emit(event);
    }

    process.exit(0);
  } catch (error) {
    emit({
      type: "error",
      error: { message: error.message, stack: error.stack },
    });
    process.exit(1);
  }
}

main();

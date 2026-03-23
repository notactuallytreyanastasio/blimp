defmodule TermDiff.Agent.Runner.ClaudeCode do
  @moduledoc """
  Agent session manager for Claude Code CLI.

  Spawns `claude` CLI as a subprocess via `Port.open/2`, wrapped in
  `script -q /dev/null` to allocate a PTY. Node.js fully buffers stdout
  when connected to a pipe; the PTY wrapper forces line-buffered output
  so NDJSON events stream in real time.

  Parses NDJSON events from stdout, publishes them via PubSub, and
  updates the run record.
  """
  use GenServer

  require Logger

  @behaviour TermDiff.Agent.Runner

  alias TermDiff.Agent.Events
  alias TermDiff.Agent.Run
  alias TermDiff.Agent.Runs

  defstruct [:run_id, :port, :buffer, :workspace_path, :last_result, interactive: false]

  @type t :: %__MODULE__{
          run_id: integer(),
          port: port() | nil,
          buffer: String.t(),
          workspace_path: String.t(),
          interactive: boolean(),
          last_result: map() | nil
        }

  # --- Behaviour Implementation ---

  @impl TermDiff.Agent.Runner
  @spec start_run(TermDiff.Agent.Runner.config(), String.t(), String.t()) ::
          {:ok, pid()} | {:error, term()}
  def start_run(config, prompt, workspace_path) do
    GenServer.start_link(__MODULE__, %{
      config: config,
      prompt: prompt,
      workspace_path: workspace_path
    })
  end

  @impl TermDiff.Agent.Runner
  @spec cancel_run(pid()) :: :ok | {:error, term()}
  def cancel_run(pid) do
    GenServer.stop(pid, :normal)
  end

  @doc """
  Send a permission response to the interactive wrapper process.
  Only works when the run is in interactive mode.
  """
  @impl TermDiff.Agent.Runner
  @spec respond_to_permission(pid(), String.t(), String.t(), String.t() | nil, map() | nil) ::
          :ok | {:error, term()}
  def respond_to_permission(pid, tool_use_id, behavior, message \\ nil, updated_input \\ nil) do
    GenServer.call(pid, {:permission_response, tool_use_id, behavior, message, updated_input})
  end

  @impl TermDiff.Agent.Runner
  @spec resume_run(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def resume_run(session_id, prompt) do
    # resume_run is not used directly -- session continuation is handled via
    # start_run with a :resume_session_id key in config. See build_args/2.
    _ = {session_id, prompt}
    {:error, :not_implemented}
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(%{config: config, prompt: prompt, workspace_path: workspace_path}) do
    run_id = Map.fetch!(config, :run_id)
    interactive = Map.get(config, :permission_mode) != "plan"
    run = Runs.get_run!(run_id)
    {:ok, _} = Runs.update_run(run, %{status: "running", started_at: DateTime.utc_now()})

    {executable, args} =
      if interactive do
        resolve_interactive_command(config, prompt, workspace_path)
      else
        resolve_command(config, prompt)
      end

    case executable do
      nil ->
        fail_run(run, "Executable not found in PATH")
        {:stop, :executable_not_found}

      path ->
        Logger.info(
          "Run #{run_id}: spawning #{path} with #{length(args)} args in #{workspace_path} (interactive=#{interactive})"
        )

        # Always use direct port (no PTY wrapper) so stdin works for permission responses
        port = open_interactive_port(path, args, workspace_path)

        emit_started(run_id, workspace_path)

        {:ok,
         %__MODULE__{
           run_id: run_id,
           port: port,
           buffer: "",
           workspace_path: workspace_path,
           interactive: interactive
         }}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.info("Run #{state.run_id}: received #{byte_size(data)} bytes from port")
    combined = state.buffer <> data
    {lines, remaining} = split_lines(combined)

    state =
      Enum.reduce(lines, state, fn line, acc ->
        if line != "" do
          Logger.info("Run #{state.run_id}: processing NDJSON line (#{byte_size(line)} bytes)")
          handle_ndjson_line(state.run_id, line)
          maybe_track_result(acc, line)
        else
          acc
        end
      end)

    {:noreply, %{state | buffer: remaining}}
  end

  @impl GenServer
  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    state =
      if state.buffer != "" do
        handle_ndjson_line(state.run_id, state.buffer)
        maybe_track_result(state, state.buffer)
      else
        state
      end

    status = determine_status(exit_code, state.last_result)

    case Runs.get_run(state.run_id) do
      %Run{} = run ->
        Runs.update_run(run, %{
          status: status,
          exit_code: exit_code,
          finished_at: DateTime.utc_now()
        })

      nil ->
        :ok
    end

    emit_finished(state.run_id, exit_code, status)

    Logger.info("Run #{state.run_id} finished with status #{status} (exit code #{exit_code})")

    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.warning(
      "ClaudeCode runner #{state.run_id} received unexpected message: #{inspect(msg)}"
    )

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(
        {:permission_response, tool_use_id, behavior, message, updated_input},
        _from,
        state
      ) do
    if state.interactive and is_port(state.port) and Port.info(state.port) != nil do
      response = build_permission_response(tool_use_id, behavior, message, updated_input)
      Port.command(state.port, Jason.encode!(response) <> "\n")
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_interactive}, state}
    end
  end

  @impl GenServer
  def terminate(reason, %{port: port, run_id: run_id}) do
    close_port_if_open(port)
    mark_cancelled_if_running(reason, run_id)
    :ok
  end

  # --- Private Functions ---

  defp build_permission_response(tool_use_id, behavior, message, updated_input) do
    %{type: "permission_response", tool_use_id: tool_use_id, behavior: behavior}
    |> maybe_put(:message, message)
    |> maybe_put(:updated_input, updated_input)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp resolve_command(config, prompt) do
    case Map.get(config, :_test_cmd) do
      {cmd, args} ->
        {System.find_executable(cmd), args}

      nil ->
        {System.find_executable("claude"), build_args(config, prompt)}
    end
  end

  defp resolve_interactive_command(config, prompt, workspace_path) do
    node_path = System.find_executable("node")
    wrapper_path = wrapper_script_path()

    args =
      ["--prompt", prompt, "--workspace", workspace_path]
      |> maybe_append_wrapper_arg("--model", Map.get(config, :model))
      |> maybe_append_wrapper_arg("--max-turns", Map.get(config, :max_turns))
      |> maybe_append_wrapper_arg("--max-budget-usd", Map.get(config, :max_budget_usd))
      |> maybe_append_wrapper_arg("--permission-mode", Map.get(config, :permission_mode))
      |> maybe_append_wrapper_arg("--allowed-tools", join_list(Map.get(config, :allowed_tools)))
      |> maybe_append_wrapper_arg(
        "--disallowed-tools",
        join_list(Map.get(config, :disallowed_tools))
      )
      |> maybe_append_wrapper_arg("--resume", Map.get(config, :resume_session_id))
      |> maybe_append_wrapper_arg("--system-prompt", Map.get(config, :system_prompt))
      |> maybe_append_wrapper_arg(
        "--append-system-prompt",
        Map.get(config, :append_system_prompt)
      )

    {node_path, [wrapper_path | args]}
  end

  defp wrapper_script_path do
    priv = :code.priv_dir(:term_diff) |> to_string()

    app_root =
      case File.read_link(priv) do
        {:ok, target} -> priv |> Path.dirname() |> Path.join(target) |> Path.expand() |> Path.dirname()
        {:error, _} -> Path.dirname(priv)
      end

    Path.join(app_root, "scripts/claude-agent-wrapper.mjs")
  end

  defp maybe_append_wrapper_arg(args, _flag, nil), do: args
  defp maybe_append_wrapper_arg(args, _flag, ""), do: args
  defp maybe_append_wrapper_arg(args, flag, value), do: args ++ [flag, to_string(value)]

  defp join_list(nil), do: nil
  defp join_list(list) when is_list(list), do: Enum.join(list, ",")
  defp join_list(other), do: other

  defp build_args(config, prompt) do
    ["-p", prompt, "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
    |> maybe_append(:max_turns, Map.get(config, :max_turns))
    |> maybe_append(:allowed_tools, Map.get(config, :allowed_tools))
    |> maybe_append(:disallowed_tools, Map.get(config, :disallowed_tools))
    |> maybe_append(:model, Map.get(config, :model))
    |> maybe_append(:max_budget_usd, Map.get(config, :max_budget_usd))
    |> maybe_append(:permission_mode, Map.get(config, :permission_mode, "default"))
    |> maybe_append(:system_prompt, Map.get(config, :system_prompt))
    |> maybe_append(:append_system_prompt, Map.get(config, :append_system_prompt))
    |> maybe_append(:resume_session_id, Map.get(config, :resume_session_id))
  end

  defp maybe_append(args, _key, nil), do: args

  defp maybe_append(args, :max_turns, value),
    do: args ++ ["--max-turns", to_string(value)]

  defp maybe_append(args, :allowed_tools, value),
    do: args ++ ["--allowedTools", Enum.join(value, ",")]

  defp maybe_append(args, :disallowed_tools, value),
    do: args ++ ["--disallowedTools", Enum.join(value, ",")]

  defp maybe_append(args, :model, value),
    do: args ++ ["--model", value]

  defp maybe_append(args, :max_budget_usd, value),
    do: args ++ ["--max-budget-usd", to_string(value)]

  defp maybe_append(args, :permission_mode, "interactive"), do: args

  defp maybe_append(args, :permission_mode, value),
    do: args ++ ["--permission-mode", value]

  defp maybe_append(args, :system_prompt, value),
    do: args ++ ["--system-prompt", value]

  defp maybe_append(args, :append_system_prompt, value),
    do: args ++ ["--append-system-prompt", value]

  defp maybe_append(args, :resume_session_id, value),
    do: args ++ ["--resume", value]

  defp open_interactive_port(executable, args, workspace_path) do
    Logger.info("Interactive port: #{executable} #{Enum.join(args, " ")} in #{workspace_path}")

    Port.open({:spawn_executable, executable}, [
      {:args, args},
      {:cd, workspace_path},
      :binary,
      :exit_status,
      :stderr_to_stdout
    ])
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {complete, [remaining]} = Enum.split(parts, -1)
    # Strip \r added by the PTY wrapper (terminals use \r\n line endings)
    {Enum.map(complete, &String.trim_trailing(&1, "\r")), remaining}
  end

  defp handle_ndjson_line(run_id, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "permission_request"} = event_data} ->
        Logger.info("Run #{run_id}: permission request for tool=#{event_data["tool_name"]}")

        Events.emit(%{
          type: "run.permission_request",
          source: "agent_runner.claude_code",
          data: Map.put(event_data, "run_id", run_id)
        })

        Phoenix.PubSub.broadcast(
          TermDiff.PubSub,
          "run:#{run_id}",
          {:permission_request, run_id, event_data}
        )

      {:ok, %{"type" => "ask_user_question"} = event_data} ->
        Logger.info("Run #{run_id}: ask user question")

        Events.emit(%{
          type: "run.ask_user_question",
          source: "agent_runner.claude_code",
          data: Map.put(event_data, "run_id", run_id)
        })

        Phoenix.PubSub.broadcast(
          TermDiff.PubSub,
          "run:#{run_id}",
          {:permission_request, run_id, event_data}
        )

      {:ok, %{"type" => "system", "subtype" => "init", "session_id" => session_id} = event_data} ->
        Logger.info("Run #{run_id}: system init, session_id=#{session_id}")
        save_session_id(run_id, session_id)

        Events.emit(%{
          type: "run.output",
          source: "agent_runner.claude_code",
          data: Map.put(event_data, "run_id", run_id)
        })

        Phoenix.PubSub.broadcast(
          TermDiff.PubSub,
          "run:#{run_id}",
          {:agent_event, run_id, event_data}
        )

      {:ok, event_data} ->
        event_type = Map.get(event_data, "type", "unknown")
        Logger.info("Run #{run_id}: event type=#{event_type}")

        maybe_update_token_usage(run_id, event_data)

        Events.emit(%{
          type: "run.output",
          source: "agent_runner.claude_code",
          data: Map.put(event_data, "run_id", run_id)
        })

        Phoenix.PubSub.broadcast(
          TermDiff.PubSub,
          "run:#{run_id}",
          {:agent_event, run_id, event_data}
        )

      {:error, reason} ->
        Logger.info(
          "Run #{run_id}: non-JSON line (#{inspect(reason)}): #{String.slice(line, 0, 100)}"
        )

        broadcast_raw_output(run_id, line)
    end
  end

  defp broadcast_raw_output(run_id, line) do
    trimmed = String.trim(line)

    if trimmed != "" do
      Phoenix.PubSub.broadcast(
        TermDiff.PubSub,
        "run:#{run_id}",
        {:agent_output, run_id, line}
      )
    end
  end

  defp emit_started(run_id, workspace_path) do
    Events.emit(%{
      type: "run.started",
      source: "agent_runner.claude_code",
      data: %{"run_id" => run_id, "workspace" => workspace_path}
    })
  end

  defp emit_finished(run_id, exit_code, status) do
    Events.emit(%{
      type: "run.finished",
      source: "agent_runner.claude_code",
      data: %{
        "run_id" => run_id,
        "exit_code" => exit_code,
        "status" => status
      }
    })
  end

  defp maybe_update_token_usage(run_id, %{"type" => "result", "result" => %{"usage" => usage}}) do
    case Runs.get_run(run_id) do
      %Run{} = run ->
        Runs.update_run(run, %{
          input_tokens: Map.get(usage, "input_tokens", 0),
          output_tokens: Map.get(usage, "output_tokens", 0),
          total_tokens: Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
        })

      nil ->
        :ok
    end
  end

  defp maybe_update_token_usage(_run_id, _event), do: :ok

  defp save_session_id(run_id, session_id) do
    case Runs.get_run(run_id) do
      %Run{} = run -> Runs.update_run(run, %{session_id: session_id})
      nil -> :ok
    end
  end

  defp close_port_if_open(port) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end
  end

  defp fail_run(run, error_message) do
    Logger.error(error_message)

    Runs.update_run(run, %{
      status: "failed",
      error: error_message,
      finished_at: DateTime.utc_now()
    })
  end

  defp mark_cancelled_if_running(:normal, _run_id), do: :ok

  defp mark_cancelled_if_running(reason, run_id) do
    case Runs.get_run(run_id) do
      %Run{status: "running"} = run ->
        Runs.update_run(run, %{
          status: "cancelled",
          finished_at: DateTime.utc_now(),
          error: "Process terminated: #{inspect(reason)}"
        })

      _gone_or_terminal ->
        :ok
    end
  end

  # Track the last "result" event from Claude Code's NDJSON output.
  # The result event contains the final status/subtype which tells us
  # whether the agent actually completed its work or was blocked.
  defp maybe_track_result(state, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = event} ->
        %{state | last_result: event}

      _ ->
        state
    end
  end

  # Determine the real run status from exit code + result event.
  # Claude Code exits 0 even when blocked by permissions, so we check
  # the result event's subtype to detect incomplete runs.
  defp determine_status(exit_code, _last_result) when exit_code != 0, do: "failed"

  defp determine_status(0, %{"subtype" => subtype})
       when subtype in ["error_max_turns", "error_tool_blocked"],
       do: "failed"

  defp determine_status(0, %{"result" => %{"is_error" => true}}), do: "failed"
  defp determine_status(0, _last_result), do: "succeeded"
end

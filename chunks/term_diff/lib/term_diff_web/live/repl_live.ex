defmodule TermDiffWeb.ReplLive do
  @moduledoc """
  Blimp REPL LiveView.

  Split pane: left is terminal input/output history, right is live state
  sidebar showing all variables and their values. Communicates with the
  blimp binary via an Erlang Port.
  """
  use TermDiffWeb, :live_view

  alias TermDiffWeb.AgentComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "REPL")
      |> assign(:history, [])
      |> assign(:state_vars, [])
      |> assign(:port, nil)
      |> assign(:buffer, "")

    socket = if connected?(socket), do: start_repl(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col font-mono text-[13px] leading-snug bg-white text-neutral-900">
      <AgentComponents.nav_bar active_page={:repl} />

      <div class="flex flex-1 overflow-hidden">
        <%!-- Left: REPL terminal (75%) --%>
        <div class="w-3/4 flex flex-col min-w-0">
          <div class="flex-1 overflow-y-auto p-4 bg-neutral-900" id="repl-output">
            <div :for={entry <- @history} class="mb-1">
              <div :if={entry.type == :input} class="flex">
                <span class="text-green-400 select-none mr-2">blimp&gt;</span>
                <span class="text-neutral-100">{entry.text}</span>
              </div>
              <div :if={entry.type == :output} class="text-neutral-300 whitespace-pre-wrap">
                {entry.text}
              </div>
              <div :if={entry.type == :error} class="text-red-400 whitespace-pre-wrap">
                {entry.text}
              </div>
            </div>
          </div>

          <div class="border-t border-neutral-700 bg-neutral-800 p-3">
            <form phx-submit="eval" class="flex gap-2">
              <span class="text-green-400 py-2 select-none">blimp&gt;</span>
              <input
                type="text"
                name="input"
                placeholder="type an expression..."
                aria-label="REPL input"
                class="flex-1 px-3 py-2 bg-neutral-900 border border-neutral-600 rounded text-sm font-mono text-neutral-100 placeholder-neutral-500 focus:outline-none focus:ring-1 focus:ring-blue-500/60"
                autocomplete="off"
                autofocus
                id="repl-input"
              />
              <button
                type="submit"
                aria-label="Evaluate expression"
                class="px-4 py-2 bg-blue-600 text-white rounded text-sm font-medium hover:bg-blue-700"
              >
                Eval
              </button>
            </form>
          </div>
        </div>

        <%!-- Right: state column (25%) --%>
        <div class="w-1/4 border-l border-neutral-700 overflow-y-auto bg-neutral-900 p-4 shrink-0 flex flex-col">
          <div class="text-xs font-semibold text-neutral-500 uppercase tracking-wide mb-3">State</div>
          <div :if={@state_vars == []} class="text-xs text-neutral-600 italic">
            No variables yet
          </div>
          <div :for={var <- @state_vars} class="mb-2">
            <div class="flex items-baseline gap-2">
              <span class="font-semibold text-blue-400 shrink-0 text-sm">{var.name}</span>
              <span class="text-neutral-600 text-xs">=</span>
            </div>
            <div class="text-neutral-300 break-all font-mono text-xs pl-2 mt-0.5">{var.value}</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:port] do
      Port.close(socket.assigns.port)
    end

    :ok
  end

  # ── handle_event ─────────────────────────────────────────

  @impl true
  def handle_event("eval", %{"input" => input}, socket) do
    input = String.trim(input)

    if input == "" do
      {:noreply, socket}
    else
      history = socket.assigns.history ++ [%{type: :input, text: input}]
      socket = assign(socket, :history, history)

      if socket.assigns.port do
        Port.command(socket.assigns.port, input <> "\n")
      end

      {:noreply, socket}
    end
  end

  # ── handle_info: Port data ──────────────────────────────

  @impl true
  def handle_info({port, {:data, data}}, %{assigns: %{port: port}} = socket) do
    combined = socket.assigns.buffer <> data
    {lines, remaining} = split_lines(combined)

    {history, state_vars} =
      Enum.reduce(lines, {socket.assigns.history, socket.assigns.state_vars}, fn line,
                                                                                 {hist, vars} ->
        parse_repl_line(line, hist, vars)
      end)

    socket =
      socket
      |> assign(:history, history)
      |> assign(:state_vars, state_vars)
      |> assign(:buffer, remaining)

    {:noreply, socket}
  end

  def handle_info({port, {:exit_status, code}}, %{assigns: %{port: port}} = socket) do
    history = socket.assigns.history ++ [%{type: :error, text: "REPL exited with code #{code}"}]

    socket =
      socket
      |> assign(:port, nil)
      |> assign(:history, history)

    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ── Private ─────────────────────────────────────────────

  defp start_repl(socket) do
    blimp_path = find_blimp_binary()

    if blimp_path do
      port =
        Port.open({:spawn_executable, blimp_path}, [
          {:args, ["--repl"]},
          :binary,
          :exit_status,
          :stderr_to_stdout
        ])

      assign(socket, :port, port)
    else
      history = [
        %{type: :error, text: "blimp binary not found. Build with: cd chunks/lang && zig build"}
      ]

      assign(socket, :history, history)
    end
  end

  defp find_blimp_binary do
    repo_path = Application.get_env(:term_diff, :repo_path, File.cwd!())

    candidates = [
      Path.join([repo_path, "chunks/lang/zig-out/bin/blimp"]),
      # Walk up from worktree to find the main repo's build
      Path.join([repo_path, "..", "blimp", "chunks/lang/zig-out/bin/blimp"]) |> Path.expand(),
      # Common locations
      Path.expand("~/blimp/chunks/lang/zig-out/bin/blimp"),
      System.find_executable("blimp")
    ]

    Enum.find(candidates, &(&1 && File.exists?(&1)))
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {complete, [remaining]} = Enum.split(parts, -1)
    {complete, remaining}
  end

  defp parse_repl_line(line, history, state_vars) do
    cond do
      # Skip prompt lines
      String.starts_with?(line, "blimp> ") ->
        {history, state_vars}

      String.starts_with?(line, "blimp>") ->
        {history, state_vars}

      # Skip banner
      String.starts_with?(line, "Blimp REPL") ->
        {history, state_vars}

      # State sidebar: header/footer
      String.contains?(line, "┌─ state") ->
        {history, state_vars}

      String.contains?(line, "└─") ->
        {history, state_vars}

      # State sidebar: variable line "  │ name = value"
      String.contains?(line, "│") ->
        case parse_state_line(line) do
          {:ok, name, value} ->
            vars = update_state_var(state_vars, name, value)
            {history, vars}

          :skip ->
            {history, state_vars}
        end

      # Result line "=> value"
      String.starts_with?(line, "=> ") ->
        result = String.trim_leading(line, "=> ")
        {history ++ [%{type: :output, text: result}], state_vars}

      # Error lines
      String.starts_with?(line, "Error:") or String.starts_with?(line, "Parse error:") ->
        {history ++ [%{type: :error, text: line}], state_vars}

      # Other non-empty output
      String.trim(line) != "" ->
        {history ++ [%{type: :output, text: line}], state_vars}

      true ->
        {history, state_vars}
    end
  end

  defp parse_state_line(line) do
    case Regex.run(~r/│\s+(\w+)\s+=\s+(.+)$/, line) do
      [_, name, value] -> {:ok, name, String.trim(value)}
      _ -> :skip
    end
  end

  defp update_state_var(vars, name, value) do
    existing_idx = Enum.find_index(vars, &(&1.name == name))

    if existing_idx do
      List.replace_at(vars, existing_idx, %{name: name, value: value})
    else
      vars ++ [%{name: name, value: value}]
    end
  end
end

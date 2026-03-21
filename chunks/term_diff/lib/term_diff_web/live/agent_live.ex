defmodule TermDiffWeb.AgentLive do
  @moduledoc """
  Agent multiplexer dashboard LiveView.

  Sidebar shows run history -- click to open a run in a pane.
  Up to 4 panes shown in dynamic split layout. Bottom prompt bar
  creates new agent runs.
  """
  use TermDiffWeb, :live_view

  alias TermDiff.Agent.Events
  alias TermDiff.Agent.Orchestrator
  alias TermDiff.Agent.Runs
  alias TermDiffWeb.AgentComponents

  @max_panes 4

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "events")
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "runs")
    end

    orchestrator_state = Orchestrator.get_state()
    active_run_ids = Map.keys(orchestrator_state.active)
    run_history = Runs.list_runs()

    # Auto-open any currently running agents into panes
    pane_order = Enum.take(active_run_ids, @max_panes)

    # Load run data for panes
    pane_runs = load_runs_map(pane_order)

    # Subscribe to pane runs
    if connected?(socket) do
      for run_id <- pane_order do
        Phoenix.PubSub.subscribe(TermDiff.PubSub, "run:#{run_id}")
      end
    end

    socket =
      socket
      |> assign(:page_title, "Agents")
      |> assign(:pane_runs, pane_runs)
      |> assign(:pane_events, %{})
      |> assign(:run_history, run_history)
      |> assign(:pane_order, pane_order)
      |> assign(:max_panes, @max_panes)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    panes = build_panes(assigns)
    assigns = assign(assigns, :panes, panes)

    ~H"""
    <div class="h-screen flex flex-col font-mono text-[13px] leading-snug bg-white text-neutral-900">
      <AgentComponents.nav_bar active_page={:agents} />

      <div class="flex flex-1 overflow-hidden">
        <%!-- Sidebar --%>
        <div class="w-56 border-r border-neutral-200 overflow-y-auto bg-neutral-50 shrink-0 flex flex-col">
          <div class="px-3 py-2 flex items-center justify-between">
            <span class="text-xs font-semibold text-neutral-500 uppercase tracking-wide">Runs</span>
            <span :if={length(@pane_order) >= @max_panes} class="text-[10px] text-neutral-400">
              {length(@pane_order)}/{@max_panes}
            </span>
          </div>
          <div :if={@run_history == []} class="px-3 py-2 text-xs text-neutral-400 italic">
            No runs yet
          </div>
          <div
            :for={run <- @run_history}
            phx-click="toggle_pane"
            phx-value-id={run.id}
            class={"flex items-center gap-2 px-3 py-2 cursor-pointer text-sm border-l-2 #{if run.id in @pane_order, do: "bg-blue-50 border-blue-500", else: "border-transparent hover:bg-neutral-100"}"}
          >
            <AgentComponents.status_dot status={run.status} />
            <div class="flex-1 min-w-0">
              <div class="truncate text-neutral-700 text-xs">{String.slice(run.prompt || "", 0, 60)}</div>
              <div class="flex items-center gap-1 text-[10px] text-neutral-400">
                <span>{run.status}</span>
                <span :if={run.inserted_at}>{AgentComponents.relative_time(run.inserted_at)}</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Main area: panes + new agent prompt --%>
        <div class="flex-1 flex flex-col min-w-0">
          <div class="flex-1 overflow-hidden flex flex-col gap-px bg-neutral-200">
            <.agent_layout panes={@panes} />
          </div>

          <%!-- New agent prompt bar --%>
          <div class="border-t border-neutral-200 bg-neutral-50 p-3">
            <form id="prompt-form" phx-submit="new_agent" class="flex gap-2">
              <textarea
                name="prompt"
                placeholder="Start a new agent..."
                class="flex-1 px-3 py-2 border border-neutral-300 rounded text-sm font-mono text-neutral-900 placeholder-neutral-400 resize-none focus:outline-none focus:ring-2 focus:ring-blue-400/60"
                rows="1"
                phx-hook="PromptSubmit"
                id="prompt-textarea"
              ></textarea>
              <button
                type="submit"
                class="px-4 py-2 bg-blue-600 text-white rounded text-sm font-medium hover:bg-blue-700"
              >
                New Agent
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Layout helpers ─────────────────────────────────────────

  defp agent_layout(%{panes: []} = assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center bg-white text-neutral-400">
      <p class="text-sm">Click a run in the sidebar or start a new agent below.</p>
    </div>
    """
  end

  defp agent_layout(%{panes: [p1]} = assigns) do
    assigns = assign(assigns, :p1, p1)

    ~H"""
    <div class="flex-1 overflow-hidden">
      <AgentComponents.terminal_pane pane={@p1} />
    </div>
    """
  end

  defp agent_layout(%{panes: [p1, p2]} = assigns) do
    assigns = assigns |> assign(:p1, p1) |> assign(:p2, p2)

    ~H"""
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p1} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p2} />
      </div>
    </div>
    """
  end

  defp agent_layout(%{panes: [p1, p2, p3]} = assigns) do
    assigns = assigns |> assign(:p1, p1) |> assign(:p2, p2) |> assign(:p3, p3)

    ~H"""
    <div class="flex-1 overflow-hidden">
      <AgentComponents.terminal_pane pane={@p1} />
    </div>
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p2} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p3} />
      </div>
    </div>
    """
  end

  defp agent_layout(%{panes: [p1, p2, p3, p4 | _]} = assigns) do
    assigns = assigns |> assign(:p1, p1) |> assign(:p2, p2) |> assign(:p3, p3) |> assign(:p4, p4)

    ~H"""
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p1} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p2} />
      </div>
    </div>
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p3} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p4} />
      </div>
    </div>
    """
  end

  # ── handle_event ─────────────────────────────────────────

  @impl true
  def handle_event("toggle_pane", %{"id" => id_str}, socket) do
    run_id = String.to_integer(id_str)
    pane_order = socket.assigns.pane_order

    if run_id in pane_order do
      # Close this pane
      {:noreply, assign(socket, :pane_order, List.delete(pane_order, run_id))}
    else
      if length(pane_order) >= @max_panes do
        # At capacity -- replace the oldest pane
        [_oldest | rest] = pane_order
        socket = open_pane(socket, run_id)
        {:noreply, assign(socket, :pane_order, rest ++ [run_id])}
      else
        # Open into a new slot
        socket = open_pane(socket, run_id)
        {:noreply, assign(socket, :pane_order, pane_order ++ [run_id])}
      end
    end
  end

  def handle_event("close_pane", %{"id" => id_str}, socket) do
    run_id = String.to_integer(id_str)
    {:noreply, assign(socket, :pane_order, List.delete(socket.assigns.pane_order, run_id))}
  end

  def handle_event("continue_pane", %{"run_id" => run_id_str, "prompt" => prompt}, socket) do
    prompt = String.trim(prompt)
    run_id = String.to_integer(run_id_str)

    if prompt == "" do
      {:noreply, socket}
    else
      case Orchestrator.continue_run(run_id, prompt) do
        {:ok, new_run} ->
          # Replace old run with new continuation in the same pane slot
          pane_order = socket.assigns.pane_order
          idx = Enum.find_index(pane_order, &(&1 == run_id))

          pane_order =
            if idx, do: List.replace_at(pane_order, idx, new_run.id), else: pane_order

          if connected?(socket) do
            Phoenix.PubSub.subscribe(TermDiff.PubSub, "run:#{new_run.id}")
          end

          socket =
            socket
            |> assign(:pane_runs, Map.put(socket.assigns.pane_runs, new_run.id, new_run))
            |> assign(:pane_order, pane_order)

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to continue session")}
      end
    end
  end

  def handle_event("new_agent", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    if prompt == "" do
      {:noreply, socket}
    else
      case create_and_dispatch(prompt) do
        {:ok, _run} ->
          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to start agent run")}
      end
    end
  end

  # ── handle_info ──────────────────────────────────────────

  @impl true
  def handle_info({:agent_event, run_id, event_data}, socket) do
    pane_events = socket.assigns.pane_events
    events = Map.get(pane_events, run_id, []) ++ [event_data]
    {:noreply, assign(socket, :pane_events, Map.put(pane_events, run_id, events))}
  end

  def handle_info({:run_created, run}, socket) do
    pane_order = socket.assigns.pane_order

    # Auto-open newly created runs into a pane
    pane_order =
      if run.id not in pane_order and length(pane_order) < @max_panes do
        pane_order ++ [run.id]
      else
        pane_order
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "run:#{run.id}")
    end

    socket =
      socket
      |> assign(:run_history, Runs.list_runs())
      |> assign(:pane_runs, Map.put(socket.assigns.pane_runs, run.id, run))
      |> assign(:pane_order, pane_order)

    {:noreply, socket}
  end

  def handle_info({:run_updated, run}, socket) do
    pane_runs = socket.assigns.pane_runs

    socket =
      if Map.has_key?(pane_runs, run.id) do
        socket
        |> assign(:pane_runs, Map.put(pane_runs, run.id, run))
        |> assign(:run_history, Runs.list_runs())
      else
        assign(socket, :run_history, Runs.list_runs())
      end

    {:noreply, socket}
  end

  def handle_info({:run_archived, _run}, socket) do
    {:noreply, assign(socket, :run_history, Runs.list_runs())}
  end

  def handle_info({:event, %{type: "run.finished", data: %{"run_id" => run_id}}}, socket) do
    pane_runs = socket.assigns.pane_runs

    socket =
      case Runs.get_run(run_id) do
        %{} = run ->
          socket
          |> assign(:pane_runs, Map.put(pane_runs, run.id, run))
          |> assign(:run_history, Runs.list_runs())

        nil ->
          assign(socket, :run_history, Runs.list_runs())
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ── Private ──────────────────────────────────────────────

  defp open_pane(socket, run_id) do
    # Load run data and persisted events for this run
    run = Runs.get_run(run_id)

    persisted_events =
      Events.list_events(run_id: run_id, limit: 500)
      |> Enum.map(& &1.data)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "run:#{run_id}")
    end

    socket
    |> assign(:pane_runs, Map.put(socket.assigns.pane_runs, run_id, run))
    |> assign(:pane_events, Map.put(socket.assigns.pane_events, run_id, persisted_events))
  end

  defp build_panes(assigns) do
    pane_order = assigns.pane_order
    pane_runs = assigns.pane_runs
    pane_events = assigns.pane_events

    pane_order
    |> Enum.take(@max_panes)
    |> Enum.map(fn run_id ->
      run = Map.get(pane_runs, run_id)
      events = Map.get(pane_events, run_id, [])
      %{run: run, events: events}
    end)
    |> Enum.filter(& &1.run)
  end

  defp create_and_dispatch(prompt) do
    repo_path = Application.get_env(:term_diff, :repo_path, File.cwd!())

    run_attrs = %{
      agent_type: "claude-code",
      prompt: prompt,
      status: "pending",
      repo_path: repo_path
    }

    case Runs.create_run(run_attrs) do
      {:ok, run} ->
        case Orchestrator.dispatch(run.id) do
          {:ok, _disposition} -> {:ok, run}
          {:error, reason} -> {:error, reason}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp load_runs_map(run_ids) do
    run_ids
    |> Enum.map(&Runs.get_run/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1.id, &1})
  end
end

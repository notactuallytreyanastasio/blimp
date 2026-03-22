defmodule TermDiffWeb.AgentLive do
  @moduledoc """
  Agent multiplexer dashboard LiveView.

  All recoverable state is URL-parameterized:
    /agents?panes=12,34,56&dark=1

  Sidebar shows run history. Click to toggle panes open/closed.
  Bottom prompt bar creates new agent runs.
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

    socket =
      socket
      |> assign(:page_title, "Agents")
      |> assign(:pane_runs, %{})
      |> assign(:pane_events, %{})
      |> assign(:run_history, Runs.list_runs())
      |> assign(:pane_order, [])
      |> assign(:max_panes, @max_panes)
      |> assign(:dark_mode, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    pane_ids = parse_pane_ids(params)
    dark_mode = params["dark"] == "1"

    old_pane_order = socket.assigns.pane_order

    # Load data for any newly opened panes
    socket = load_new_panes(socket, pane_ids, old_pane_order)

    # Manage PubSub subscriptions
    if connected?(socket) do
      for id <- old_pane_order -- pane_ids do
        Phoenix.PubSub.unsubscribe(TermDiff.PubSub, "run:#{id}")
      end

      for id <- pane_ids -- old_pane_order do
        Phoenix.PubSub.subscribe(TermDiff.PubSub, "run:#{id}")
      end
    end

    socket =
      socket
      |> assign(:pane_order, pane_ids)
      |> assign(:dark_mode, dark_mode)
      |> assign(:run_history, Runs.list_runs())

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    panes = build_panes(assigns)
    assigns = assign(assigns, :panes, panes)

    ~H"""
    <div class={"h-screen flex flex-col font-mono text-[13px] leading-snug #{if @dark_mode, do: "bg-neutral-900 text-neutral-100", else: "bg-white text-neutral-900"}"}>
      <AgentComponents.nav_bar active_page={:agents} dark_mode={@dark_mode} />

      <div class="flex flex-1 overflow-hidden">
        <%!-- Sidebar --%>
        <div class={"w-56 border-r overflow-y-auto shrink-0 flex flex-col #{if @dark_mode, do: "border-neutral-700 bg-neutral-800", else: "border-neutral-200 bg-neutral-50"}"}>
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
            class={"flex items-center gap-2 px-3 py-2 cursor-pointer text-sm border-l-2 #{sidebar_item_class(run.id in @pane_order, @dark_mode)}"}
          >
            <AgentComponents.status_dot status={run.status} />
            <div class="flex-1 min-w-0">
              <div class={"truncate text-xs #{if @dark_mode, do: "text-neutral-300", else: "text-neutral-700"}"}>{String.slice(run.prompt || "", 0, 60)}</div>
              <div class="flex items-center gap-1 text-[10px] text-neutral-400">
                <span>{run.status}</span>
                <span :if={run.inserted_at}>{AgentComponents.relative_time(run.inserted_at)}</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Main area: panes + new agent prompt --%>
        <div class="flex-1 flex flex-col min-w-0">
          <div class={"flex-1 overflow-hidden flex flex-col gap-px #{if @dark_mode, do: "bg-neutral-700", else: "bg-neutral-200"}"}>
            <.agent_layout panes={@panes} dark_mode={@dark_mode} />
          </div>

          <%!-- New agent prompt bar --%>
          <div class={"border-t p-3 #{if @dark_mode, do: "border-neutral-700 bg-neutral-800", else: "border-neutral-200 bg-neutral-50"}"}>
            <form id="prompt-form" phx-submit="new_agent" class="flex gap-2">
              <textarea
                name="prompt"
                placeholder="Start a new agent..."
                class={"flex-1 px-3 py-2 border rounded text-sm font-mono resize-none focus:outline-none focus:ring-2 focus:ring-blue-400/60 #{if @dark_mode, do: "bg-neutral-900 border-neutral-600 text-neutral-100 placeholder-neutral-500", else: "border-neutral-300 text-neutral-900 placeholder-neutral-400"}"}
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

  defp agent_layout(%{panes: [], dark_mode: dark} = assigns) do
    assigns = assign(assigns, :dark, dark)

    ~H"""
    <div class={"flex-1 flex items-center justify-center #{if @dark, do: "bg-neutral-900 text-neutral-500", else: "bg-white text-neutral-400"}"}>
      <p class="text-sm">Click a run in the sidebar or start a new agent below.</p>
    </div>
    """
  end

  defp agent_layout(%{panes: [p1]} = assigns) do
    assigns = assign(assigns, :p1, p1)

    ~H"""
    <div class="flex-1 overflow-hidden">
      <AgentComponents.terminal_pane pane={@p1} dark_mode={@dark_mode} />
    </div>
    """
  end

  defp agent_layout(%{panes: [p1, p2]} = assigns) do
    assigns = assigns |> assign(:p1, p1) |> assign(:p2, p2)

    ~H"""
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p1} dark_mode={@dark_mode} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p2} dark_mode={@dark_mode} />
      </div>
    </div>
    """
  end

  defp agent_layout(%{panes: [p1, p2, p3]} = assigns) do
    assigns = assigns |> assign(:p1, p1) |> assign(:p2, p2) |> assign(:p3, p3)

    ~H"""
    <div class="flex-1 overflow-hidden">
      <AgentComponents.terminal_pane pane={@p1} dark_mode={@dark_mode} />
    </div>
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p2} dark_mode={@dark_mode} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p3} dark_mode={@dark_mode} />
      </div>
    </div>
    """
  end

  defp agent_layout(%{panes: [p1, p2, p3, p4 | _]} = assigns) do
    assigns = assigns |> assign(:p1, p1) |> assign(:p2, p2) |> assign(:p3, p3) |> assign(:p4, p4)

    ~H"""
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p1} dark_mode={@dark_mode} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p2} dark_mode={@dark_mode} />
      </div>
    </div>
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p3} dark_mode={@dark_mode} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p4} dark_mode={@dark_mode} />
      </div>
    </div>
    """
  end

  # ── handle_event ─────────────────────────────────────────

  @impl true
  def handle_event("toggle_dark", _params, socket) do
    {:noreply, patch_url(socket, socket.assigns.pane_order, !socket.assigns.dark_mode)}
  end

  def handle_event("toggle_pane", %{"id" => id_str}, socket) do
    run_id = String.to_integer(id_str)
    pane_order = socket.assigns.pane_order

    new_order =
      if run_id in pane_order do
        List.delete(pane_order, run_id)
      else
        if length(pane_order) >= @max_panes do
          [_oldest | rest] = pane_order
          rest ++ [run_id]
        else
          pane_order ++ [run_id]
        end
      end

    {:noreply, patch_url(socket, new_order, socket.assigns.dark_mode)}
  end

  def handle_event("close_pane", %{"id" => id_str}, socket) do
    run_id = String.to_integer(id_str)
    new_order = List.delete(socket.assigns.pane_order, run_id)
    {:noreply, patch_url(socket, new_order, socket.assigns.dark_mode)}
  end

  def handle_event("continue_pane", %{"run_id" => run_id_str, "prompt" => prompt}, socket) do
    prompt = String.trim(prompt)
    run_id = String.to_integer(run_id_str)

    if prompt == "" do
      {:noreply, socket}
    else
      case Orchestrator.continue_run(run_id, prompt) do
        {:ok, new_run} ->
          pane_order = socket.assigns.pane_order
          idx = Enum.find_index(pane_order, &(&1 == run_id))
          new_order = if idx, do: List.replace_at(pane_order, idx, new_run.id), else: pane_order

          {:noreply, patch_url(socket, new_order, socket.assigns.dark_mode)}

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
        {:ok, run} ->
          new_order =
            if length(socket.assigns.pane_order) < @max_panes do
              socket.assigns.pane_order ++ [run.id]
            else
              socket.assigns.pane_order
            end

          {:noreply, patch_url(socket, new_order, socket.assigns.dark_mode)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to start agent run")}
      end
    end
  end

  def handle_event("approve_permission", %{"run-id" => run_id_str, "tool-use-id" => tool_use_id}, socket) do
    run_id = String.to_integer(run_id_str)
    Orchestrator.respond_to_permission(run_id, tool_use_id, "allow")
    {:noreply, mark_permission_resolved(socket, run_id, tool_use_id, :approved)}
  end

  def handle_event("deny_permission", %{"run-id" => run_id_str, "tool-use-id" => tool_use_id}, socket) do
    run_id = String.to_integer(run_id_str)
    Orchestrator.respond_to_permission(run_id, tool_use_id, "deny", "Denied by user")
    {:noreply, mark_permission_resolved(socket, run_id, tool_use_id, :denied)}
  end

  # ── handle_info ──────────────────────────────────────────

  @impl true
  def handle_info({:permission_request, run_id, event_data}, socket) do
    pane_events = socket.assigns.pane_events
    events = Map.get(pane_events, run_id, []) ++ [event_data]
    {:noreply, assign(socket, :pane_events, Map.put(pane_events, run_id, events))}
  end

  def handle_info({:agent_event, run_id, event_data}, socket) do
    pane_events = socket.assigns.pane_events
    events = Map.get(pane_events, run_id, []) ++ [event_data]
    {:noreply, assign(socket, :pane_events, Map.put(pane_events, run_id, events))}
  end

  def handle_info({:run_created, run}, socket) do
    socket =
      socket
      |> assign(:run_history, Runs.list_runs())
      |> assign(:pane_runs, Map.put(socket.assigns.pane_runs, run.id, run))

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

  # ── Private: URL params ─────────────────────────────────

  defp parse_pane_ids(%{"panes" => panes_str}) when is_binary(panes_str) and panes_str != "" do
    panes_str
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_integer/1)
    |> Enum.uniq()
    |> Enum.take(@max_panes)
  rescue
    ArgumentError -> []
  end

  defp parse_pane_ids(_params), do: []

  defp build_agent_path(pane_order, dark_mode) do
    params =
      []
      |> then(fn p -> if pane_order != [], do: [{"panes", Enum.join(pane_order, ",")} | p], else: p end)
      |> then(fn p -> if dark_mode, do: [{"dark", "1"} | p], else: p end)

    case URI.encode_query(params) do
      "" -> "/agents"
      qs -> "/agents?#{qs}"
    end
  end

  defp patch_url(socket, pane_order, dark_mode) do
    push_patch(socket, to: build_agent_path(pane_order, dark_mode))
  end

  # ── Private: pane data ──────────────────────────────────

  defp load_new_panes(socket, new_ids, old_ids) do
    added = new_ids -- old_ids

    Enum.reduce(added, socket, fn run_id, acc ->
      case Runs.get_run(run_id) do
        %{} = run ->
          persisted_events =
            Events.list_events(run_id: run_id, limit: 500)
            |> Enum.map(& &1.data)

          acc
          |> assign(:pane_runs, Map.put(acc.assigns.pane_runs, run_id, run))
          |> assign(:pane_events, Map.put(acc.assigns.pane_events, run_id, persisted_events))

        nil ->
          acc
      end
    end)
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

  defp mark_permission_resolved(socket, run_id, tool_use_id, resolution) do
    pane_events = socket.assigns.pane_events
    events = Map.get(pane_events, run_id, [])

    updated_events =
      Enum.map(events, fn
        %{"type" => "permission_request", "tool_use_id" => ^tool_use_id} = evt ->
          Map.put(evt, "resolved", resolution)

        other ->
          other
      end)

    assign(socket, :pane_events, Map.put(pane_events, run_id, updated_events))
  end

  defp sidebar_item_class(true, true), do: "bg-blue-900/30 border-blue-400"
  defp sidebar_item_class(true, false), do: "bg-blue-50 border-blue-500"
  defp sidebar_item_class(false, true), do: "border-transparent hover:bg-neutral-700"
  defp sidebar_item_class(false, false), do: "border-transparent hover:bg-neutral-100"
end

defmodule TermDiffWeb.AgentLive do
  @moduledoc """
  Agent multiplexer dashboard LiveView.

  All recoverable state is URL-parameterized:
    /agents?panes=12,34,56&dark=1&yolo=12,34

  Sidebar shows run history. Click to toggle panes open/closed.
  Bottom prompt bar creates new agent runs.
  """
  use TermDiffWeb, :live_view

  alias TermDiff.Agent.ClaudeSettings
  alias TermDiff.Agent.Events
  alias TermDiff.Agent.Orchestrator
  alias TermDiff.Agent.Run
  alias TermDiff.Agent.Runs
  alias TermDiffWeb.AgentComponents

  @max_panes 4

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "events")
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "runs")
    end

    yolo_default = ClaudeSettings.bypass_permissions?()

    socket =
      socket
      |> assign(:page_title, "Agents")
      |> assign(:pane_runs, %{})
      |> assign(:pane_events, %{})
      |> assign(:run_history, Runs.list_runs())
      |> assign(:pane_order, [])
      |> assign(:max_panes, @max_panes)
      |> assign(:dark_mode, false)
      |> assign(:decision_tree_open, nil)
      |> assign(:decision_tree_data, nil)
      |> assign(:yolo_mode, %{})
      |> assign(:yolo_default, yolo_default)
      |> assign(:editing_run_id, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    pane_ids = parse_pane_ids(params)
    dark_mode = params["dark"] == "1"
    yolo_on_ids = parse_yolo_ids(params)
    yolo_off_ids = parse_noyolo_ids(params)

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

    yolo_default = socket.assigns.yolo_default
    explicit_on = MapSet.new(yolo_on_ids)
    explicit_off = MapSet.new(yolo_off_ids)

    # ?yolo= forces ON, ?noyolo= forces OFF, otherwise use config default
    yolo_mode =
      Map.new(pane_ids, fn id ->
        cond do
          MapSet.member?(explicit_on, id) -> {id, true}
          MapSet.member?(explicit_off, id) -> {id, false}
          true -> {id, yolo_default}
        end
      end)

    socket =
      socket
      |> assign(:pane_order, pane_ids)
      |> assign(:dark_mode, dark_mode)
      |> assign(:yolo_mode, yolo_mode)
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

      <%!-- Decision Tree Modal --%>
      <AgentComponents.decision_tree_modal
        :if={@decision_tree_open}
        tree_data={@decision_tree_data}
        run_id={@decision_tree_open}
        dark_mode={@dark_mode}
      />

      <div class="flex flex-1 overflow-hidden">
        <%!-- Sidebar --%>
        <div class={"w-56 border-r overflow-y-auto shrink-0 flex flex-col #{if @dark_mode, do: "border-neutral-700 bg-neutral-800", else: "border-neutral-200 bg-neutral-50"}"}>
          <div class="px-3 py-2 flex items-center justify-between">
            <span class="text-xs font-semibold text-neutral-500 uppercase tracking-wide">Runs</span>
            <div class="flex items-center gap-1">
              <span :if={length(@pane_order) >= @max_panes} class="text-[10px] text-neutral-400">
                {length(@pane_order)}/{@max_panes}
              </span>
              <button
                :if={@run_history != []}
                phx-click="clean_house"
                class={"text-[9px] px-1.5 py-0.5 rounded #{if @dark_mode, do: "bg-neutral-700 text-neutral-400 hover:bg-red-900 hover:text-red-300", else: "bg-neutral-200 text-neutral-500 hover:bg-red-100 hover:text-red-600"}"}
                title="Archive runs with no activity in the last 24h"
              >
                clean house
              </button>
            </div>
          </div>
          <div :if={@run_history == []} class="px-3 py-2 text-xs text-neutral-400 italic">
            No runs yet
          </div>
          <div
            :for={run <- @run_history}
            phx-click="toggle_pane"
            phx-value-id={run.id}
            class={"flex items-center gap-1 px-3 py-2 cursor-pointer text-sm border-l-2 group #{sidebar_item_class(run.id in @pane_order, @dark_mode)}"}
          >
            <AgentComponents.status_dot status={run.status} />
            <div class="flex-1 min-w-0">
              <div
                :if={@editing_run_id != run.id}
                phx-click="start_rename"
                phx-value-id={run.id}
                class={"truncate text-xs #{if @dark_mode, do: "text-neutral-300", else: "text-neutral-700"}"}
              >
                {run.title || String.slice(run.prompt || "", 0, 60)}
              </div>
              <form
                :if={@editing_run_id == run.id}
                phx-submit="save_rename"
                phx-click-away="cancel_rename"
                class="flex"
              >
                <input type="hidden" name="run_id" value={run.id} />
                <input
                  type="text"
                  name="title"
                  value={run.title || String.slice(run.prompt || "", 0, 60)}
                  class={"w-full text-xs px-1 py-0 border rounded font-mono #{if @dark_mode, do: "bg-neutral-900 border-neutral-600 text-neutral-100", else: "bg-white border-neutral-300 text-neutral-900"}"}
                  phx-hook="AutoFocus"
                  id={"rename-input-#{run.id}"}
                />
              </form>
              <div class="flex items-center gap-1 text-[10px] text-neutral-400">
                <span>{run.status}</span>
                <span :if={run.inserted_at}>{AgentComponents.relative_time(run.inserted_at)}</span>
              </div>
            </div>
            <button
              phx-click="archive_run"
              phx-value-id={run.id}
              class={"text-[10px] opacity-0 group-hover:opacity-100 shrink-0 #{if @dark_mode, do: "text-neutral-500 hover:text-red-400", else: "text-neutral-400 hover:text-red-500"}"}
              title="Archive this run"
            >
              x
            </button>
          </div>
        </div>

        <%!-- Main area: panes + new agent prompt --%>
        <div class="flex-1 flex flex-col min-w-0">
          <div class={"flex-1 overflow-hidden flex flex-col gap-px #{if @dark_mode, do: "bg-neutral-700", else: "bg-neutral-200"}"}>
            <.agent_layout panes={@panes} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
          </div>

          <%!-- New agent prompt bar --%>
          <div class={"border-t p-3 #{if @dark_mode, do: "border-neutral-700 bg-neutral-800", else: "border-neutral-200 bg-neutral-50"}"}>
            <form id="prompt-form" phx-submit="new_agent" class="flex gap-2">
              <textarea
                name="prompt"
                placeholder="Start a new agent..."
                class={"flex-1 px-3 py-2 border rounded text-sm font-mono resize-y focus:outline-none focus:ring-2 focus:ring-blue-400/60 #{if @dark_mode, do: "bg-neutral-900 border-neutral-600 text-neutral-100 placeholder-neutral-500", else: "border-neutral-300 text-neutral-900 placeholder-neutral-400"}"}
                rows="3"
                phx-hook="PromptSubmit"
                id="prompt-textarea"
              ></textarea>
              <button
                type="submit"
                class="px-4 py-2 bg-blue-600 text-white rounded text-sm font-medium hover:bg-blue-700 self-end"
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
      <AgentComponents.terminal_pane pane={@p1} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
    </div>
    """
  end

  defp agent_layout(%{panes: [p1, p2]} = assigns) do
    assigns = assigns |> assign(:p1, p1) |> assign(:p2, p2)

    ~H"""
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p1} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p2} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
      </div>
    </div>
    """
  end

  defp agent_layout(%{panes: [p1, p2, p3]} = assigns) do
    assigns = assigns |> assign(:p1, p1) |> assign(:p2, p2) |> assign(:p3, p3)

    ~H"""
    <div class="flex-1 overflow-hidden">
      <AgentComponents.terminal_pane pane={@p1} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
    </div>
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p2} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p3} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
      </div>
    </div>
    """
  end

  defp agent_layout(%{panes: [p1, p2, p3, p4 | _]} = assigns) do
    assigns = assigns |> assign(:p1, p1) |> assign(:p2, p2) |> assign(:p3, p3) |> assign(:p4, p4)

    ~H"""
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p1} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p2} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
      </div>
    </div>
    <div class="flex-1 flex gap-px overflow-hidden">
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p3} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
      </div>
      <div class="flex-1 overflow-hidden">
        <AgentComponents.terminal_pane pane={@p4} dark_mode={@dark_mode} yolo_mode={@yolo_mode} />
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

  def handle_event("toggle_yolo_mode", %{"id" => id_str}, socket) do
    run_id = String.to_integer(id_str)
    current = Map.get(socket.assigns.yolo_mode, run_id, socket.assigns.yolo_default)
    new_yolo = Map.put(socket.assigns.yolo_mode, run_id, !current)

    socket = assign(socket, :yolo_mode, new_yolo)
    {:noreply, patch_url(socket, socket.assigns.pane_order, socket.assigns.dark_mode)}
  end

  def handle_event("start_rename", %{"id" => id_str}, socket) do
    {:noreply, assign(socket, :editing_run_id, String.to_integer(id_str))}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :editing_run_id, nil)}
  end

  def handle_event("save_rename", %{"run_id" => id_str, "title" => title}, socket) do
    run_id = String.to_integer(id_str)
    title = String.trim(title)

    case Runs.get_run(run_id) do
      %Run{} = run ->
        Runs.update_run(run, %{title: if(title == "", do: nil, else: title)})

      nil ->
        :ok
    end

    socket =
      socket
      |> assign(:editing_run_id, nil)
      |> assign(:run_history, Runs.list_runs())

    {:noreply, socket}
  end

  def handle_event("archive_run", %{"id" => id_str}, socket) do
    run_id = String.to_integer(id_str)

    case Runs.get_run(run_id) do
      %Run{} = run -> Runs.archive_run(run)
      nil -> :ok
    end

    new_order = List.delete(socket.assigns.pane_order, run_id)

    socket =
      socket
      |> assign(:run_history, Runs.list_runs())
      |> assign(:pane_runs, Map.delete(socket.assigns.pane_runs, run_id))
      |> assign(:pane_events, Map.delete(socket.assigns.pane_events, run_id))

    {:noreply, patch_url(socket, new_order, socket.assigns.dark_mode)}
  end

  def handle_event("clean_house", _params, socket) do
    {count, _} = Runs.archive_stale_runs(24)

    pane_order = socket.assigns.pane_order
    active_ids = Runs.list_runs() |> Enum.map(& &1.id)
    new_order = Enum.filter(pane_order, &(&1 in active_ids))

    socket =
      socket
      |> assign(:run_history, Runs.list_runs())
      |> put_flash(:info, "Archived #{count} stale run#{if count != 1, do: "s"}")

    {:noreply, patch_url(socket, new_order, socket.assigns.dark_mode)}
  end

  def handle_event(
        "approve_permission",
        %{"run-id" => run_id_str, "tool-use-id" => tool_use_id},
        socket
      ) do
    run_id = String.to_integer(run_id_str)
    Orchestrator.respond_to_permission(run_id, tool_use_id, "allow")
    {:noreply, mark_permission_resolved(socket, run_id, tool_use_id, :approved)}
  end

  def handle_event(
        "deny_permission",
        %{"run-id" => run_id_str, "tool-use-id" => tool_use_id},
        socket
      ) do
    run_id = String.to_integer(run_id_str)
    Orchestrator.respond_to_permission(run_id, tool_use_id, "deny", "Denied by user")
    {:noreply, mark_permission_resolved(socket, run_id, tool_use_id, :denied)}
  end

  def handle_event("toggle_decision_tree", %{"id" => id_str}, socket) do
    run_id = String.to_integer(id_str)

    socket =
      if socket.assigns.decision_tree_open == run_id do
        # Close the tree
        socket
        |> assign(:decision_tree_open, nil)
        |> assign(:decision_tree_data, nil)
      else
        # Open the tree - fetch data
        case Map.get(socket.assigns.pane_runs, run_id) do
          %{deciduous_root: root_id} when not is_nil(root_id) ->
            case TermDiff.Agent.Deciduous.fetch_tree(root_id) do
              {:ok, tree_data} ->
                socket
                |> assign(:decision_tree_open, run_id)
                |> assign(:decision_tree_data, tree_data)

              {:error, _reason} ->
                put_flash(socket, :error, "Failed to load decision tree")
            end

          _ ->
            put_flash(socket, :error, "No decision tree found for this run")
        end
      end

    {:noreply, socket}
  end

  def handle_event("close_decision_tree", _params, socket) do
    socket =
      socket
      |> assign(:decision_tree_open, nil)
      |> assign(:decision_tree_data, nil)

    {:noreply, socket}
  end

  # ── handle_info ──────────────────────────────────────────

  @impl true
  def handle_info({:permission_request, run_id, event_data}, socket) do
    if Map.get(socket.assigns.yolo_mode, run_id, false) do
      tool_use_id = event_data["tool_use_id"] || event_data["request_id"]
      if tool_use_id, do: Orchestrator.respond_to_permission(run_id, tool_use_id, "allow")
      event_data = Map.put(event_data, "resolved", :approved)
      pane_events = socket.assigns.pane_events
      events = Map.get(pane_events, run_id, []) ++ [event_data]
      {:noreply, assign(socket, :pane_events, Map.put(pane_events, run_id, events))}
    else
      pane_events = socket.assigns.pane_events
      events = Map.get(pane_events, run_id, []) ++ [event_data]
      {:noreply, assign(socket, :pane_events, Map.put(pane_events, run_id, events))}
    end
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

  defp parse_yolo_ids(%{"yolo" => yolo_str}) when is_binary(yolo_str) and yolo_str != "" do
    yolo_str
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_integer/1)
    |> Enum.uniq()
  rescue
    ArgumentError -> []
  end

  defp parse_yolo_ids(_params), do: []

  defp parse_noyolo_ids(%{"noyolo" => noyolo_str})
       when is_binary(noyolo_str) and noyolo_str != "" do
    noyolo_str
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_integer/1)
    |> Enum.uniq()
  rescue
    ArgumentError -> []
  end

  defp parse_noyolo_ids(_params), do: []

  defp build_agent_path(pane_order, dark_mode, yolo_mode, yolo_default) do
    yolo_ids = yolo_mode |> Enum.filter(fn {_, v} -> v end) |> Enum.map(fn {k, _} -> k end)
    noyolo_ids = yolo_mode |> Enum.filter(fn {_, v} -> !v end) |> Enum.map(fn {k, _} -> k end)

    # Only encode explicit overrides vs the config default.
    # When default=false: encode yolo= for explicit ONs (backward compat)
    # When default=true: encode noyolo= for explicit OFFs
    explicit_on = if yolo_default, do: [], else: yolo_ids
    explicit_off = if yolo_default, do: noyolo_ids, else: []

    params =
      []
      |> then(fn p ->
        if pane_order != [], do: [{"panes", Enum.join(pane_order, ",")} | p], else: p
      end)
      |> then(fn p -> if dark_mode, do: [{"dark", "1"} | p], else: p end)
      |> then(fn p ->
        if explicit_on != [], do: [{"yolo", Enum.join(explicit_on, ",")} | p], else: p
      end)
      |> then(fn p ->
        if explicit_off != [], do: [{"noyolo", Enum.join(explicit_off, ",")} | p], else: p
      end)

    case URI.encode_query(params) do
      "" -> "/agents"
      qs -> "/agents?#{qs}"
    end
  end

  defp patch_url(socket, pane_order, dark_mode) do
    push_patch(socket,
      to:
        build_agent_path(
          pane_order,
          dark_mode,
          socket.assigns.yolo_mode,
          socket.assigns.yolo_default
        )
    )
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

defmodule TermDiffWeb.AgentRunLive do
  @moduledoc """
  Detail view for a single agent run.

  Shows full prompt, metadata, and streaming block output
  with auto-scrolling for live runs.
  """
  use TermDiffWeb, :live_view

  alias TermDiff.Agent.Events
  alias TermDiff.Agent.Orchestrator
  alias TermDiff.Agent.Runs
  alias TermDiffWeb.Agent.EventProcessor
  alias TermDiffWeb.AgentComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Runs.get_run!(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "run:#{run.id}")
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "events")
    end

    # Load persisted events and process into blocks
    persisted_events =
      Events.list_events(run_id: run.id, limit: 500)
      |> Enum.map(& &1.data)

    blocks = EventProcessor.process_events(persisted_events)

    socket =
      socket
      |> assign(:page_title, "Run ##{run.id}")
      |> assign(:run, run)
      |> assign(:blocks, blocks)
      |> assign(:streaming, run.status == "running")

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col font-mono text-[13px] leading-snug bg-white text-neutral-900">
      <AgentComponents.nav_bar active_page={:agents} />

      <div class="flex flex-1 overflow-hidden">
        <%!-- Left: metadata --%>
        <div class="w-80 border-r border-neutral-200 overflow-y-auto p-4 bg-neutral-50 shrink-0">
          <a href="/agents" class="text-blue-600 text-xs hover:underline mb-4 block">
            Back to Agents
          </a>

          <h2 class="text-lg font-semibold text-neutral-800 mb-4">Run #{@run.id}</h2>

          <div class="space-y-3">
            <.meta_row label="Status" value={@run.status} />
            <.meta_row label="Agent" value={@run.agent_type} />
            <.meta_row :if={@run.model} label="Model" value={@run.model} />
            <.meta_row :if={@run.exit_code} label="Exit code" value={to_string(@run.exit_code)} />
            <.meta_row
              :if={@run.total_tokens > 0}
              label="Tokens"
              value={to_string(@run.total_tokens)}
            />

            <div>
              <div class="text-xs text-neutral-400 font-semibold uppercase mb-1">Prompt</div>
              <div class="text-sm text-neutral-700 whitespace-pre-wrap bg-white border border-neutral-200 rounded p-2">
                {@run.prompt}
              </div>
            </div>

            <div :if={@run.error}>
              <div class="text-xs text-red-500 font-semibold uppercase mb-1">Error</div>
              <div class="text-sm text-red-700 bg-red-50 border border-red-200 rounded p-2">
                {@run.error}
              </div>
            </div>
          </div>

          <%!-- Continue form for finished runs with session --%>
          <div :if={@run.session_id && @run.status in ["succeeded", "failed"]} class="mt-6">
            <div class="text-xs text-neutral-400 font-semibold uppercase mb-2">Continue Session</div>
            <form phx-submit="continue_run" class="flex flex-col gap-2">
              <textarea
                name="prompt"
                placeholder="Continue with..."
                class="w-full px-3 py-2 border border-neutral-300 rounded text-sm font-mono resize-none focus:outline-none focus:ring-2 focus:ring-blue-400/60"
                rows="2"
              ></textarea>
              <button
                type="submit"
                class="px-4 py-2 bg-blue-600 text-white rounded text-sm font-medium hover:bg-blue-700"
              >
                Continue
              </button>
            </form>
          </div>
        </div>

        <%!-- Right: output blocks --%>
        <div class="flex-1 overflow-y-auto p-4" id="run-output" phx-hook="AgentAutoScroll">
          <div :if={@blocks == []} class="text-neutral-400 text-sm italic">
            No output yet.
          </div>
          <AgentComponents.block_list :if={@blocks != []} blocks={@blocks} />
          <div :if={@streaming} class="flex items-center gap-2 text-neutral-400 text-sm py-2 mt-2">
            <span class="animate-pulse">Working...</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── handle_event ─────────────────────────────────────────

  @impl true
  def handle_event("continue_run", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    if prompt == "" do
      {:noreply, socket}
    else
      case Orchestrator.continue_run(socket.assigns.run.id, prompt) do
        {:ok, new_run} ->
          {:noreply, push_navigate(socket, to: "/agents/#{new_run.id}")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to continue session")}
      end
    end
  end

  # ── handle_info ──────────────────────────────────────────

  @impl true
  def handle_info({:agent_event, _run_id, event_data}, socket) do
    blocks = EventProcessor.append_event(event_data, socket.assigns.blocks)
    {:noreply, assign(socket, :blocks, blocks)}
  end

  def handle_info({:run_updated, run}, socket) do
    if run.id == socket.assigns.run.id do
      streaming = run.status == "running"

      socket =
        socket
        |> assign(:run, run)
        |> assign(:streaming, streaming)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event, %{type: "run.finished", data: %{"run_id" => run_id}}}, socket) do
    if run_id == socket.assigns.run.id do
      run = Runs.get_run!(run_id)

      socket =
        socket
        |> assign(:run, run)
        |> assign(:streaming, false)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ── Private components ───────────────────────────────────

  defp meta_row(assigns) do
    ~H"""
    <div>
      <div class="text-xs text-neutral-400 font-semibold uppercase">{@label}</div>
      <div class="text-sm text-neutral-700">{@value}</div>
    </div>
    """
  end
end

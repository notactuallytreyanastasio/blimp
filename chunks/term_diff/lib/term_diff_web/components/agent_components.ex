defmodule TermDiffWeb.AgentComponents do
  @moduledoc """
  Function components for the agent multiplexer UI.

  Provides reusable components for terminal panes, block output,
  prompt input, and navigation.
  """
  use Phoenix.Component

  alias TermDiffWeb.Agent.EventProcessor

  # ── nav_bar ──────────────────────────────────────────────

  attr :active_page, :atom, required: true
  attr :dark_mode, :boolean, default: false

  def nav_bar(assigns) do
    ~H"""
    <nav class={"flex items-center gap-4 px-4 py-1.5 border-b text-sm shrink-0 #{if @dark_mode, do: "border-neutral-700 bg-neutral-800", else: "border-neutral-200 bg-neutral-50"}"}>
      <.link
        navigate="/"
        class={"font-medium #{if @active_page == :diffs, do: (if @dark_mode, do: "text-blue-400 underline underline-offset-4", else: "text-blue-600 underline underline-offset-4"), else: (if @dark_mode, do: "text-neutral-400 hover:text-neutral-200", else: "text-neutral-500 hover:text-neutral-800")}"}
      >
        Diffs
      </.link>
      <.link
        navigate="/agents"
        class={"font-medium #{if @active_page == :agents, do: (if @dark_mode, do: "text-blue-400 underline underline-offset-4", else: "text-blue-600 underline underline-offset-4"), else: (if @dark_mode, do: "text-neutral-400 hover:text-neutral-200", else: "text-neutral-500 hover:text-neutral-800")}"}
      >
        Agents
      </.link>
      <div class="flex-1"></div>
      <button
        :if={@active_page == :agents}
        phx-click="toggle_dark"
        class={"text-xs px-2 py-1 rounded #{if @dark_mode, do: "bg-neutral-700 text-neutral-300 hover:bg-neutral-600", else: "bg-neutral-200 text-neutral-600 hover:bg-neutral-300"}"}
      >
        {if @dark_mode, do: "Light", else: "Dark"}
      </button>
    </nav>
    """
  end

  # ── terminal_pane ──────────────────────────────────────────

  attr :pane, :map, required: true
  attr :dark_mode, :boolean, default: false

  def terminal_pane(assigns) do
    blocks =
      assigns.pane.events
      |> Enum.take(-500)
      |> EventProcessor.process_events()

    dark = assigns.dark_mode
    assigns = assigns |> assign(:blocks, blocks) |> assign(:dark, dark)

    ~H"""
    <div class={"h-full flex flex-col overflow-hidden #{if @dark, do: "bg-neutral-900", else: "bg-white"}"}>
      <%!-- Pane header --%>
      <div class={"flex items-center justify-between px-3 py-1.5 border-b shrink-0 #{if @dark, do: "bg-neutral-800 border-neutral-700", else: "bg-neutral-50 border-neutral-200"}"}>
        <div class="flex items-center gap-2 min-w-0">
          <.status_dot status={@pane.run.status} />
          <span class="text-xs text-neutral-400">#{@pane.run.id}</span>
          <span class={"text-xs truncate #{if @dark, do: "text-neutral-400", else: "text-neutral-500"}"}>{prompt_preview(@pane.run.prompt)}</span>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <span class={"text-[10px] px-1.5 py-0.5 rounded #{status_badge_class(@pane.run.status)}"}>
            {@pane.run.status}
          </span>
          <button
            phx-click="close_pane"
            phx-value-id={@pane.run.id}
            class="text-[10px] text-neutral-400 hover:text-red-500"
            title="Close pane"
          >
            x
          </button>
        </div>
      </div>

      <%!-- Scrollable output --%>
      <div
        class="flex-1 overflow-y-auto p-3 space-y-1"
        id={"pane-output-#{@pane.run.id}"}
        phx-hook="AgentAutoScroll"
      >
        <div :if={@blocks == []} class={"text-xs italic #{if @dark, do: "text-neutral-600", else: "text-neutral-400"}"}>
          Waiting for output...
        </div>
        <.pane_block :for={block <- @blocks} block={block} dark={@dark} />
      </div>

      <%!-- Per-pane chat input --%>
      <div class={"border-t px-2 py-1.5 shrink-0 #{if @dark, do: "border-neutral-700 bg-neutral-800", else: "border-neutral-200 bg-neutral-50"}"}>
        <form phx-submit="continue_pane" class="flex gap-1.5" id={"pane-chat-#{@pane.run.id}"}>
          <input type="hidden" name="run_id" value={@pane.run.id} />
          <input
            type="text"
            name="prompt"
            placeholder={if @pane.run.status == "running", do: "Running...", else: "Continue..."}
            disabled={@pane.run.status == "running"}
            class={"flex-1 px-2 py-1 border rounded text-xs font-mono focus:outline-none focus:ring-1 focus:ring-blue-400/60 #{if @dark, do: "bg-neutral-900 border-neutral-600 text-neutral-100 placeholder-neutral-500 disabled:bg-neutral-800 disabled:text-neutral-500", else: "border-neutral-200 text-neutral-900 placeholder-neutral-400 disabled:bg-neutral-100 disabled:text-neutral-400"}"}
          />
          <button
            type="submit"
            disabled={@pane.run.status == "running"}
            class="px-2 py-1 bg-blue-600 text-white rounded text-[10px] font-medium hover:bg-blue-700 disabled:opacity-40"
          >
            Send
          </button>
        </form>
      </div>
    </div>
    """
  end

  # ── prompt_input ─────────────────────────────────────────

  attr :submit_event, :string, default: "submit_prompt"
  attr :disabled, :boolean, default: false

  def prompt_input(assigns) do
    ~H"""
    <form id="prompt-form" phx-submit={@submit_event} class="flex gap-2">
      <textarea
        name="prompt"
        placeholder="Send a prompt to Claude..."
        class="flex-1 px-3 py-2 border border-neutral-300 rounded text-sm font-mono text-neutral-900 placeholder-neutral-400 resize-none focus:outline-none focus:ring-2 focus:ring-blue-400/60"
        rows="1"
        disabled={@disabled}
        phx-hook="PromptSubmit"
        id="prompt-textarea"
      ></textarea>
      <button
        type="submit"
        disabled={@disabled}
        class="px-4 py-2 bg-blue-600 text-white rounded text-sm font-medium hover:bg-blue-700 disabled:opacity-50"
      >
        Send
      </button>
    </form>
    """
  end

  # ── block_list (used by AgentRunLive detail page) ───────

  attr :blocks, :list, required: true

  def block_list(assigns) do
    ~H"""
    <div class="space-y-2" id="block-list">
      <.block_item :for={block <- @blocks} block={block} />
    </div>
    """
  end

  # ── run_list_item (used by detail page sidebar) ─────────

  attr :run, :map, required: true
  attr :active, :boolean, default: false

  def run_list_item(assigns) do
    ~H"""
    <div
      phx-click="select_run"
      phx-value-id={@run.id}
      class={"flex items-center gap-2 px-3 py-2 cursor-pointer hover:bg-neutral-100 text-sm #{if @active, do: "bg-blue-50 border-l-2 border-blue-500", else: ""}"}
    >
      <.status_dot status={@run.status} />
      <div class="flex-1 min-w-0">
        <div class="truncate text-neutral-700">{prompt_preview(@run.prompt)}</div>
        <div class="flex items-center gap-2 text-xs text-neutral-400">
          <span>{@run.agent_type || "agent"}</span>
          <span :if={@run.inserted_at}>{relative_time(@run.inserted_at)}</span>
        </div>
      </div>
    </div>
    """
  end

  # ── Private: pane block rendering (compact for splits) ──

  defp pane_block(%{block: %{type: :system}} = assigns) do
    ~H"""
    <div class="text-[10px] text-neutral-500 flex items-center gap-1">
      <span>{@block.model || "agent"}</span>
      <span :if={@block.session_id} class="font-mono">{String.slice(@block.session_id, 0, 8)}</span>
    </div>
    """
  end

  defp pane_block(%{block: %{type: :text}, dark: true} = assigns) do
    ~H"""
    <div class="text-xs text-neutral-300 whitespace-pre-wrap break-words leading-relaxed">
      {@block.content}
    </div>
    """
  end

  defp pane_block(%{block: %{type: :text}} = assigns) do
    ~H"""
    <div class="text-xs text-neutral-700 whitespace-pre-wrap break-words leading-relaxed">
      {@block.content}
    </div>
    """
  end

  defp pane_block(%{block: %{type: :tool_use}, dark: true} = assigns) do
    ~H"""
    <div class="border border-neutral-700 rounded overflow-hidden my-1">
      <div class="flex items-center gap-1.5 px-2 py-1 text-xs bg-neutral-800">
        <span class="font-mono text-[10px] text-neutral-400 bg-neutral-700 px-1 py-0.5 rounded">{@block.tool_name}</span>
        <span class="text-neutral-500 truncate flex-1 text-[10px] font-mono">{tool_summary(@block)}</span>
        <span :if={@block.result == nil} class="text-amber-400 text-[10px] animate-pulse">...</span>
        <span :if={@block.result != nil && @block.is_error} class="text-red-400 text-[10px]">err</span>
        <span :if={@block.result != nil && !@block.is_error} class="text-green-400 text-[10px]">ok</span>
      </div>
      <div :if={@block.result} class="px-2 py-1 text-[10px] font-mono text-neutral-400 max-h-24 overflow-y-auto">
        <pre class="whitespace-pre-wrap break-all">{tool_result_content(@block)}</pre>
      </div>
    </div>
    """
  end

  defp pane_block(%{block: %{type: :tool_use}} = assigns) do
    ~H"""
    <div class="border border-neutral-200 rounded overflow-hidden my-1">
      <div class="flex items-center gap-1.5 px-2 py-1 text-xs bg-neutral-50">
        <span class="font-mono text-[10px] text-neutral-500 bg-neutral-200 px-1 py-0.5 rounded">{@block.tool_name}</span>
        <span class="text-neutral-400 truncate flex-1 text-[10px] font-mono">{tool_summary(@block)}</span>
        <span :if={@block.result == nil} class="text-amber-500 text-[10px] animate-pulse">...</span>
        <span :if={@block.result != nil && @block.is_error} class="text-red-500 text-[10px]">err</span>
        <span :if={@block.result != nil && !@block.is_error} class="text-green-500 text-[10px]">ok</span>
      </div>
      <div :if={@block.result} class="px-2 py-1 text-[10px] font-mono text-neutral-500 max-h-24 overflow-y-auto">
        <pre class="whitespace-pre-wrap break-all">{tool_result_content(@block)}</pre>
      </div>
    </div>
    """
  end

  defp pane_block(%{block: %{type: :result}, dark: true} = assigns) do
    ~H"""
    <div class="border-t border-neutral-700 pt-1 mt-1">
      <div class="flex items-center gap-2 text-[10px] text-neutral-500">
        <span>Done</span>
        <span :if={@block.cost_usd} class="font-mono">${format_cost(@block.cost_usd)}</span>
        <span :if={@block.duration_ms}>{format_duration(@block.duration_ms)}</span>
        <span :if={@block.tokens} class="font-mono">
          {format_tokens(@block.tokens.input)}in / {format_tokens(@block.tokens.output)}out
        </span>
      </div>
    </div>
    """
  end

  defp pane_block(%{block: %{type: :result}} = assigns) do
    ~H"""
    <div class="border-t border-neutral-200 pt-1 mt-1">
      <div class="flex items-center gap-2 text-[10px] text-neutral-400">
        <span>Done</span>
        <span :if={@block.cost_usd} class="font-mono">${format_cost(@block.cost_usd)}</span>
        <span :if={@block.duration_ms}>{format_duration(@block.duration_ms)}</span>
        <span :if={@block.tokens} class="font-mono">
          {format_tokens(@block.tokens.input)}in / {format_tokens(@block.tokens.output)}out
        </span>
      </div>
    </div>
    """
  end

  defp pane_block(%{block: %{type: :permission_request, resolved: nil}, dark: true} = assigns) do
    ~H"""
    <div class="border border-amber-600/50 rounded overflow-hidden my-2 bg-amber-900/20">
      <div class="flex items-center gap-2 px-3 py-2 text-xs">
        <span class="text-amber-400 font-semibold">Permission</span>
        <span class="font-mono text-[10px] text-neutral-400 bg-neutral-700 px-1 py-0.5 rounded">{@block.tool_name}</span>
        <span class="text-neutral-500 truncate flex-1 text-[10px] font-mono">{tool_summary(@block)}</span>
      </div>
      <div class="flex gap-2 px-3 py-2 border-t border-amber-600/30">
        <button
          phx-click="approve_permission"
          phx-value-run-id={@block.run_id}
          phx-value-tool-use-id={@block.tool_use_id}
          class="px-3 py-1 text-xs bg-green-600 text-white rounded font-medium hover:bg-green-700"
        >
          Allow
        </button>
        <button
          phx-click="deny_permission"
          phx-value-run-id={@block.run_id}
          phx-value-tool-use-id={@block.tool_use_id}
          class="px-3 py-1 text-xs bg-red-600 text-white rounded font-medium hover:bg-red-700"
        >
          Deny
        </button>
      </div>
    </div>
    """
  end

  defp pane_block(%{block: %{type: :permission_request, resolved: nil}} = assigns) do
    ~H"""
    <div class="border border-amber-300 rounded overflow-hidden my-2 bg-amber-50">
      <div class="flex items-center gap-2 px-3 py-2 text-xs">
        <span class="text-amber-600 font-semibold">Permission</span>
        <span class="font-mono text-[10px] text-neutral-500 bg-neutral-200 px-1 py-0.5 rounded">{@block.tool_name}</span>
        <span class="text-neutral-400 truncate flex-1 text-[10px] font-mono">{tool_summary(@block)}</span>
      </div>
      <div class="flex gap-2 px-3 py-2 border-t border-amber-200">
        <button
          phx-click="approve_permission"
          phx-value-run-id={@block.run_id}
          phx-value-tool-use-id={@block.tool_use_id}
          class="px-3 py-1 text-xs bg-green-600 text-white rounded font-medium hover:bg-green-700"
        >
          Allow
        </button>
        <button
          phx-click="deny_permission"
          phx-value-run-id={@block.run_id}
          phx-value-tool-use-id={@block.tool_use_id}
          class="px-3 py-1 text-xs bg-red-600 text-white rounded font-medium hover:bg-red-700"
        >
          Deny
        </button>
      </div>
    </div>
    """
  end

  defp pane_block(%{block: %{type: :permission_request, resolved: resolved}} = assigns) do
    assigns = assign(assigns, :resolved, resolved)

    ~H"""
    <div class="flex items-center gap-2 px-2 py-1 text-[10px] text-neutral-400 my-1">
      <span class="font-mono">{@block.tool_name}</span>
      <span :if={@resolved == :approved} class="text-green-500">approved</span>
      <span :if={@resolved == :denied} class="text-red-500">denied</span>
    </div>
    """
  end

  defp pane_block(assigns) do
    ~H"""
    <div></div>
    """
  end

  # ── Private: full block rendering (detail page) ─────────

  defp block_item(%{block: %{type: :system}} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 text-[11px] text-neutral-400 py-1">
      <span>{@block.model || "agent"}</span>
      <span :if={@block.session_id} class="font-mono">{String.slice(@block.session_id, 0, 8)}</span>
    </div>
    """
  end

  defp block_item(%{block: %{type: :text}} = assigns) do
    ~H"""
    <div class="text-sm text-neutral-700 whitespace-pre-wrap">
      {@block.content}
    </div>
    """
  end

  defp block_item(%{block: %{type: :tool_use}} = assigns) do
    ~H"""
    <div class="border border-neutral-200 rounded-lg overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-2 text-sm bg-neutral-50">
        <span class="font-mono text-xs text-neutral-500 bg-neutral-200 px-1.5 py-0.5 rounded">{@block.tool_name}</span>
        <span class="text-neutral-400 truncate flex-1 text-xs font-mono">{tool_summary(@block)}</span>
        <span :if={@block.result == nil} class="text-amber-500 text-xs">running...</span>
        <span :if={@block.result != nil && @block.is_error} class="text-red-500 text-xs">error</span>
        <span :if={@block.result != nil && !@block.is_error} class="text-green-500 text-xs">done</span>
      </div>
      <div :if={@block.result} class="px-3 py-2 text-xs font-mono text-neutral-600 max-h-48 overflow-y-auto bg-white">
        <pre class="whitespace-pre-wrap break-all">{tool_result_content(@block)}</pre>
      </div>
    </div>
    """
  end

  defp block_item(%{block: %{type: :result}} = assigns) do
    ~H"""
    <div class="border-t border-neutral-200 pt-2 mt-2">
      <div :if={@block.text} class="text-sm text-neutral-700 mb-2">{@block.text}</div>
      <div class="flex items-center gap-3 text-xs text-neutral-400">
        <span>Done</span>
        <span :if={@block.cost_usd} class="font-mono">${format_cost(@block.cost_usd)}</span>
        <span :if={@block.duration_ms}>{format_duration(@block.duration_ms)}</span>
        <span :if={@block.tokens} class="font-mono">
          {format_tokens(@block.tokens.input)} in / {format_tokens(@block.tokens.output)} out
        </span>
      </div>
    </div>
    """
  end

  defp block_item(assigns) do
    ~H"""
    <div></div>
    """
  end

  # ── Status helpers (public for sidebar use) ──────────────

  def status_dot(assigns) do
    ~H"""
    <span class={"w-2 h-2 rounded-full shrink-0 #{status_dot_color(@status)}"}></span>
    """
  end

  defp status_dot_color("running"), do: "bg-green-500"
  defp status_dot_color("pending"), do: "bg-yellow-500 animate-pulse"
  defp status_dot_color("failed"), do: "bg-red-500"
  defp status_dot_color("succeeded"), do: "bg-blue-500"
  defp status_dot_color("cancelled"), do: "bg-neutral-500"
  defp status_dot_color(_), do: "bg-neutral-600"

  defp status_badge_class("running"), do: "bg-green-100 text-green-700"
  defp status_badge_class("pending"), do: "bg-yellow-100 text-yellow-700"
  defp status_badge_class("failed"), do: "bg-red-100 text-red-700"
  defp status_badge_class("succeeded"), do: "bg-blue-100 text-blue-700"
  defp status_badge_class("cancelled"), do: "bg-neutral-100 text-neutral-500"
  defp status_badge_class(_), do: "bg-neutral-100 text-neutral-500"

  # ── Private: content helpers ────────────────────────────

  defp prompt_preview(nil), do: ""
  defp prompt_preview(prompt), do: String.slice(prompt, 0, 80)

  defp tool_summary(%{tool_name: "Bash", input: %{"command" => cmd}}),
    do: String.slice(cmd, 0, 60)

  defp tool_summary(%{tool_name: name, input: %{"file_path" => path}})
       when name in ["Edit", "Write", "Read"],
       do: path

  defp tool_summary(%{tool_name: "Glob", input: %{"pattern" => p}}), do: p
  defp tool_summary(%{tool_name: "Grep", input: %{"pattern" => p}}), do: p
  defp tool_summary(%{tool_name: name}), do: name

  defp tool_result_content(%{result: %{stdout: stdout}}) when is_binary(stdout) and stdout != "",
    do: stdout

  defp tool_result_content(%{result: %{content: content}}) when is_binary(content),
    do: content

  defp tool_result_content(_), do: ""

  defp format_cost(cost) when is_float(cost), do: :erlang.float_to_binary(cost, decimals: 2)
  defp format_cost(cost) when is_integer(cost), do: "#{cost}.00"
  defp format_cost(_), do: "0.00"

  defp format_duration(ms) when is_integer(ms) do
    seconds = div(ms, 1000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  defp format_duration(_), do: ""

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_tokens(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_tokens(n) when is_integer(n), do: to_string(n)
  defp format_tokens(_), do: "0"

  def relative_time(nil), do: ""

  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  def relative_time(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> relative_time(dt)
      _ -> ""
    end
  end

  def relative_time(_), do: ""
end

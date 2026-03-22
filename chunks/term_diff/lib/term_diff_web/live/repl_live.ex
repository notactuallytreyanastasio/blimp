defmodule TermDiffWeb.ReplLive do
  use TermDiffWeb, :live_view

  alias TermDiff.Blimp

  @impl true
  def mount(_params, _session, socket) do
    files = Blimp.example_files()
    first_file = List.first(files)

    socket =
      socket
      |> assign(:page_title, "Blimp REPL")
      |> assign(:files, files)
      |> assign(:file_path, first_file)
      |> assign(:source, "")
      |> assign(:actors, [])
      |> assign(:error, nil)
      |> assign(:selected_actor, nil)
      |> assign(:selected_hole, nil)
      |> assign(:hole_prompt, "")
      |> load_file(first_file)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    {:noreply, socket |> assign(:selected_hole, nil) |> load_file(path)}
  end

  def handle_event("toggle_actor", %{"name" => name}, socket) do
    selected =
      if socket.assigns.selected_actor == name, do: nil, else: name

    {:noreply, assign(socket, :selected_actor, selected)}
  end

  def handle_event("click_hole", %{"index" => index_str, "actor" => actor_name}, socket) do
    index = String.to_integer(index_str)

    hole =
      socket.assigns.actors
      |> Enum.find(&(&1["name"] == actor_name))
      |> case do
        nil -> nil
        actor -> Enum.at(actor["holes"] || [], index)
      end

    case hole do
      nil ->
        {:noreply, socket}

      hole ->
        {:noreply,
         socket
         |> assign(:selected_hole, Map.put(hole, "actor", actor_name))
         |> assign(:hole_prompt, "")}
    end
  end

  def handle_event("close_hole", _params, socket) do
    {:noreply, assign(socket, :selected_hole, nil)}
  end

  def handle_event("update_hole_prompt", %{"prompt" => text}, socket) do
    {:noreply, assign(socket, :hole_prompt, text)}
  end

  def handle_event("submit_hole", _params, socket) do
    # Future: send to AI agent for hole filling
    {:noreply, socket}
  end

  defp load_file(socket, nil), do: socket

  defp load_file(socket, path) do
    source =
      case Blimp.read_source(path) do
        {:ok, content} -> content
        {:error, _} -> ""
      end

    {actors, error} =
      case Blimp.introspect(path) do
        {:ok, %{"actors" => actors}} -> {actors, nil}
        {:error, err} -> {[], err}
      end

    socket
    |> assign(:file_path, path)
    |> assign(:source, source)
    |> assign(:actors, actors)
    |> assign(:error, error)
    |> assign(:selected_actor, get_in(actors, [Access.at(0), "name"]))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white text-neutral-900">
      <%!-- File picker bar --%>
      <div class="flex items-center gap-1 px-3 py-1.5 border-b border-neutral-200 bg-neutral-50 overflow-x-auto flex-shrink-0">
        <span class="text-neutral-400 text-xs mr-2">blimp</span>
        <button
          :for={file <- @files}
          phx-click="select_file"
          phx-value-path={file}
          class={"px-2 py-0.5 rounded text-xs #{if file == @file_path, do: "bg-neutral-800 text-white", else: "text-neutral-600 hover:bg-neutral-200"}"}
        >
          {Path.basename(file)}
        </button>
      </div>

      <%!-- Error bar --%>
      <div :if={@error} class="px-3 py-1.5 bg-red-50 border-b border-red-200 text-red-700 text-xs font-mono whitespace-pre-wrap">
        {@error}
      </div>

      <%!-- Main split: source + sidebar --%>
      <div class="flex flex-1 min-h-0">
        <%!-- Source pane --%>
        <div class="flex-1 overflow-auto border-r border-neutral-200">
          <pre class="p-3"><code><span
              :for={{line, idx} <- Enum.with_index(String.split(@source, "\n"), 1)}
              class={"block #{hole_line_class(line)}"}
            ><span class="inline-block w-8 text-right text-neutral-300 select-none mr-3">{idx}</span>{highlight_line(line)}</span></code></pre>
        </div>

        <%!-- Actor sidebar --%>
        <div class="w-80 flex-shrink-0 overflow-auto bg-neutral-50">
          <div :if={@actors == []} class="p-4 text-neutral-400 text-xs">No actors found</div>
          <div :for={actor <- @actors} class="border-b border-neutral-100">
            <%!-- Actor header --%>
            <button
              phx-click="toggle_actor"
              phx-value-name={actor["name"]}
              class={"w-full text-left px-3 py-1.5 text-xs font-bold flex items-center gap-1 #{if @selected_actor == actor["name"], do: "bg-blue-50 text-blue-800", else: "hover:bg-neutral-100"}"}
            >
              <span class={"transition-transform #{if @selected_actor == actor["name"], do: "rotate-90"}"}>&#9656;</span>
              {actor["name"]}
            </button>

            <%!-- Actor detail (expanded) --%>
            <div :if={@selected_actor == actor["name"]} class="px-3 pb-2">
              <%!-- State fields --%>
              <div :if={actor["state"] != []} class="mt-1">
                <div class="text-neutral-400 text-xs uppercase tracking-wide mb-0.5">state</div>
                <div :for={field <- actor["state"]} class="text-xs pl-2 py-0.5 flex justify-between">
                  <span>
                    <span class="text-neutral-800">{field["name"]}</span><span class="text-neutral-400">:</span>
                    <span class="text-blue-600">{field["type"]}</span>
                  </span>
                  <span :if={field["default"]} class="text-neutral-400">= {field["default"]}</span>
                </div>
              </div>

              <%!-- Handlers --%>
              <div :if={actor["handlers"] != []} class="mt-2">
                <div class="text-neutral-400 text-xs uppercase tracking-wide mb-0.5">handlers</div>
                <div :for={handler <- actor["handlers"]} class="text-xs pl-2 py-0.5">
                  <span class="text-purple-600">:{handler["message"]}</span><span
                    :if={handler["params"] != []}
                    class="text-neutral-500"
                  >(<span :for={{param, pidx} <- Enum.with_index(handler["params"])}>{if pidx > 0, do: ", "}<span class="text-neutral-700">{param["name"]}</span><span class="text-neutral-400">:</span> <span class="text-blue-600">{param["type"]}</span></span>)</span>
                  <span :if={handler["return_type"]} class="text-neutral-400"> -&gt; </span>
                  <span :if={handler["return_type"]} class="text-green-600">{handler["return_type"]}</span>
                  <span :if={handler["guard"]} class="text-amber-600 ml-1">when {handler["guard"]}</span>
                  <span :if={handler["bubbles"]} class="text-red-500 ml-1">bubbles({handler["bubbles"]})</span>
                </div>
              </div>

              <%!-- Holes --%>
              <div :if={actor["holes"] != [] and actor["holes"] != nil} class="mt-2">
                <div class="text-neutral-400 text-xs uppercase tracking-wide mb-0.5">holes</div>
                <div :for={{hole, hidx} <- Enum.with_index(actor["holes"])} class="text-xs pl-2 py-1 bg-amber-50 rounded my-0.5">
                  <div class="flex items-start justify-between gap-1">
                    <div>
                      <span class="text-amber-700">L{hole["line"]}</span>
                      <span :if={hole["directive"]} class="text-neutral-600 ml-1">{hole["directive"]}</span>
                    </div>
                    <button
                      phx-click="click_hole"
                      phx-value-index={hidx}
                      phx-value-actor={actor["name"]}
                      class="px-1.5 py-0.5 bg-amber-200 hover:bg-amber-300 text-amber-800 rounded text-xs flex-shrink-0"
                    >
                      Fill
                    </button>
                  </div>
                  <div class="text-neutral-400 mt-0.5">{hole["context"]}</div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Hole fill prompt panel --%>
      <div :if={@selected_hole} class="border-t border-neutral-200 bg-neutral-50 px-4 py-3 flex-shrink-0">
        <div class="flex items-center justify-between mb-2">
          <div class="text-xs">
            <span class="text-neutral-400">Filling hole in</span>
            <span class="font-bold text-neutral-700 ml-1">{@selected_hole["actor"]}</span>
            <span class="text-neutral-400 ml-2">at line {@selected_hole["line"]}</span>
          </div>
          <button phx-click="close_hole" class="text-neutral-400 hover:text-neutral-700 text-xs">close</button>
        </div>
        <div :if={@selected_hole["directive"]} class="text-xs text-amber-700 mb-2">
          Directive: {@selected_hole["directive"]}
        </div>
        <form phx-submit="submit_hole" class="flex gap-2">
          <input
            type="text"
            name="prompt"
            value={@hole_prompt}
            phx-change="update_hole_prompt"
            placeholder="Describe what should fill this hole..."
            class="flex-1 px-2 py-1 text-xs border border-neutral-300 rounded bg-white focus:outline-none focus:border-blue-400"
          />
          <button type="submit" class="px-3 py-1 text-xs bg-blue-600 text-white rounded hover:bg-blue-700">
            Fill with AI
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp hole_line_class(line) do
    if String.contains?(line, "_ #"), do: "bg-amber-50", else: ""
  end

  defp highlight_line(line) do
    # Basic keyword highlighting for Blimp source
    line
    |> highlight_comments()
    |> Phoenix.HTML.raw()
  end

  defp highlight_comments(line) do
    case String.split(line, "#", parts: 2) do
      [code, comment] ->
        escaped_code = Phoenix.HTML.html_escape(code) |> Phoenix.HTML.safe_to_string()
        escaped_comment = Phoenix.HTML.html_escape("#" <> comment) |> Phoenix.HTML.safe_to_string()
        highlight_keywords(escaped_code) <> ~s(<span class="text-neutral-400">) <> escaped_comment <> "</span>"

      [code] ->
        escaped = Phoenix.HTML.html_escape(code) |> Phoenix.HTML.safe_to_string()
        highlight_keywords(escaped)
    end
  end

  @keywords ~w(actor do end state on become reply when bubbles situation case orelse)

  defp highlight_keywords(html) do
    Enum.reduce(@keywords, html, fn kw, acc ->
      String.replace(acc, ~r/\b(#{kw})\b/, ~s(<span class="text-fuchsia-700 font-bold">\\1</span>))
    end)
  end
end

defmodule TermDiffWeb.DiffLive do
  use TermDiffWeb, :live_view

  alias TermDiff.Git.{Runner, Status, Diff, Log, Watcher}
  alias TermDiff.Git.Types.RepoState
  alias TermDiff.Diff.Navigation

  @impl true
  def mount(params, _session, socket) do
    configured_path = Application.get_env(:term_diff, :repo_path, File.cwd!())
    repo_path = params["path"] || configured_path

    if connected?(socket) do
      Watcher.subscribe()
      send(self(), :refresh)
    end

    socket =
      socket
      |> assign(:repo_path, repo_path)
      |> assign(:repo_state, %RepoState{})
      |> assign(:nav, %Navigation{})
      |> assign(:selected_diff, nil)
      |> assign(:log_entries, [])
      |> assign(:commit_detail, nil)
      |> assign(:commit_diff, nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="term-diff" phx-hook="KeyNav" class="h-screen flex flex-col font-mono text-[13px] leading-snug bg-white text-neutral-900">
      <.status_bar repo_state={@repo_state} nav={@nav} repo_path={@repo_path} />
      <.keybinding_bar nav={@nav} />

      <div class="flex flex-1 overflow-hidden">
        <%= if @nav.focus in [:log_view, :log_detail] do %>
          <.log_layout
            nav={@nav}
            log_entries={@log_entries}
            commit_detail={@commit_detail}
            commit_diff={@commit_diff}
          />
        <% else %>
          <.diff_layout
            nav={@nav}
            repo_state={@repo_state}
            selected_diff={@selected_diff}
          />
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_info(:repo_changed, socket) do
    send(self(), :refresh)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    repo_state = fetch_repo_state(socket.assigns.repo_path)
    nav = %{socket.assigns.nav | file_count: length(repo_state.files)}

    selected_file = select_file_for_nav(repo_state.files, nav)
    selected_diff = if selected_file, do: Map.get(repo_state.diffs, selected_file)

    nav =
      if nav.following do
        latest = find_latest_modified(repo_state.files)
        hunk_count = hunk_count_for(repo_state.diffs, latest)
        Navigation.follow_to_latest(nav, latest, hunk_count)
      else
        %{nav | selected_file: selected_file}
      end

    socket =
      socket
      |> assign(:repo_state, repo_state)
      |> assign(:nav, nav)
      |> assign(:selected_diff, selected_diff)

    {:noreply, socket}
  end

  @impl true
  def handle_event("keydown", %{"key" => key}, socket) do
    nav = Navigation.handle_key(socket.assigns.nav, key)

    socket =
      socket
      |> handle_open_file(nav)
      |> handle_nav_change(nav)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_repo_path", %{"path" => path}, socket) do
    path = String.trim(path)

    if File.dir?(path) do
      socket =
        socket
        |> assign(:repo_path, path)

      send(self(), :refresh)
      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Not a valid directory: #{path}")}
    end
  end

  defp handle_open_file(socket, nav) do
    if nav.open_file do
      Runner.open_editor(socket.assigns.repo_path, nav.open_file)
      nav = Navigation.clear_open_file(nav)
      assign(socket, :nav, nav)
    else
      socket
    end
  end

  defp handle_nav_change(socket, nav) do
    cond do
      nav.focus == :log_view and socket.assigns.log_entries == [] ->
        log_entries = fetch_log(socket.assigns.repo_path)
        nav = %{nav | log_count: length(log_entries)}
        selected_file = select_file_for_nav(socket.assigns.repo_state.files, nav)
        nav = %{nav | selected_file: selected_file}

        socket
        |> assign(:nav, nav)
        |> assign(:log_entries, log_entries)

      nav.focus == :log_detail and nav.selected_commit != socket.assigns.nav.selected_commit ->
        commit = Enum.at(socket.assigns.log_entries, nav.log_index)
        hash = if commit, do: commit.hash

        if hash do
          {detail, diff} = fetch_commit_detail(socket.assigns.repo_path, hash)
          hunk_count = if diff, do: length(diff.hunks), else: 0
          nav = %{nav | selected_commit: hash, hunk_count: hunk_count}

          socket
          |> assign(:nav, nav)
          |> assign(:commit_detail, detail)
          |> assign(:commit_diff, diff)
        else
          assign(socket, :nav, nav)
        end

      nav.focus == :log_detail and is_nil(socket.assigns.nav.selected_commit) ->
        commit = Enum.at(socket.assigns.log_entries, nav.log_index)
        hash = if commit, do: commit.hash

        if hash do
          {detail, diff} = fetch_commit_detail(socket.assigns.repo_path, hash)
          hunk_count = if diff, do: length(diff.hunks), else: 0
          nav = %{nav | selected_commit: hash, hunk_count: hunk_count}

          socket
          |> assign(:nav, nav)
          |> assign(:commit_detail, detail)
          |> assign(:commit_diff, diff)
        else
          assign(socket, :nav, nav)
        end

      nav.focus in [:file_list, :diff_view] ->
        selected_file = select_file_for_nav(socket.assigns.repo_state.files, nav)
        selected_diff = if selected_file, do: Map.get(socket.assigns.repo_state.diffs, selected_file)
        hunk_count = if selected_diff, do: length(selected_diff.hunks), else: 0
        nav = %{nav | selected_file: selected_file, hunk_count: hunk_count}

        socket
        |> assign(:nav, nav)
        |> assign(:selected_diff, selected_diff)

      true ->
        assign(socket, :nav, nav)
    end
  end

  defp fetch_repo_state(repo_path) do
    with {:ok, status_raw} <- Runner.status(repo_path),
         {:ok, diff_unstaged} <- Runner.diff(repo_path),
         {:ok, diff_staged} <- Runner.diff_staged(repo_path),
         {:ok, branch} <- Runner.branch(repo_path) do
      files = Status.parse(status_raw)

      unstaged_diffs = Diff.parse(diff_unstaged)
      staged_diffs = Diff.parse(diff_staged)

      diff_map =
        Map.merge(
          Map.new(staged_diffs, fn d -> {d.path, d} end),
          Map.new(unstaged_diffs, fn d -> {d.path, d} end)
        )

      %RepoState{
        files: files,
        diffs: diff_map,
        branch: branch,
        last_updated: DateTime.utc_now()
      }
    else
      _ -> %RepoState{}
    end
  end

  defp fetch_log(repo_path) do
    case Runner.log_oneline(repo_path) do
      {:ok, raw} -> Log.parse_oneline(raw)
      _ -> []
    end
  end

  defp fetch_commit_detail(repo_path, hash) do
    detail =
      case Runner.log_show(repo_path, hash) do
        {:ok, raw} -> raw
        _ -> nil
      end

    diff =
      case Runner.log_diff(repo_path, hash) do
        {:ok, raw} ->
          case Diff.parse(raw) do
            [first | _] -> first
            _ -> nil
          end

        _ ->
          nil
      end

    {detail, diff}
  end

  defp select_file_for_nav(files, nav) do
    case Enum.at(files, nav.file_index) do
      nil -> nil
      entry -> entry.path
    end
  end

  defp find_latest_modified(files) do
    case files do
      [] -> nil
      [first | _] -> first.path
    end
  end

  defp hunk_count_for(_diffs, nil), do: 0

  defp hunk_count_for(diffs, file) do
    case Map.get(diffs, file) do
      nil -> 0
      diff -> length(diff.hunks)
    end
  end

  # ── Layout Components ──

  defp diff_layout(assigns) do
    ~H"""
    <div class={"w-80 border-r border-neutral-200 overflow-y-auto p-2 shrink-0 #{if @nav.focus == :file_list, do: "ring-1 ring-blue-400 ring-inset", else: ""}"}>
      <.file_list files={@repo_state.files} nav={@nav} diffs={@repo_state.diffs} />
    </div>
    <div class="flex-1 overflow-y-auto p-2" id="diff-pane" phx-hook="AutoScroll">
      <.diff_pane diff={@selected_diff} nav={@nav} />
    </div>
    """
  end

  defp log_layout(assigns) do
    ~H"""
    <%= if @nav.focus == :log_view do %>
      <div class="flex-1 overflow-y-auto p-2">
        <.log_list entries={@log_entries} nav={@nav} />
      </div>
    <% else %>
      <div class="w-1/2 border-r border-neutral-200 overflow-y-auto p-2">
        <.commit_message detail={@commit_detail} />
      </div>
      <div class="flex-1 overflow-y-auto p-2" id="diff-pane" phx-hook="AutoScroll">
        <.diff_pane diff={@commit_diff} nav={@nav} />
      </div>
    <% end %>
    """
  end

  # ── UI Components ──

  defp status_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-3 py-1 border-b border-neutral-200 text-neutral-500 text-xs">
      <div class="flex items-center gap-3">
        <span class="text-neutral-900 font-semibold"><%= @repo_state.branch || "no branch" %></span>
        <span><%= length(@repo_state.files) %> files</span>
        <span class="text-neutral-300 truncate max-w-xs"><%= @repo_path %></span>
      </div>
      <div class="flex gap-4">
        <span :if={@nav.following} class="text-blue-600 font-semibold">FOLLOWING</span>
        <span :if={@nav.focus in [:log_view, :log_detail]} class="text-purple-600 font-semibold">LOG</span>
      </div>
    </div>
    """
  end

  defp keybinding_bar(assigns) do
    ~H"""
    <div class="flex items-center px-3 py-0.5 border-b border-neutral-100 text-neutral-400 text-[11px] gap-4">
      <span><kbd class="text-neutral-600">j</kbd>/<kbd class="text-neutral-600">k</kbd> nav</span>
      <span><kbd class="text-neutral-600">Enter</kbd> select</span>
      <span><kbd class="text-neutral-600">q</kbd> back</span>
      <span><kbd class="text-neutral-600">l</kbd> log</span>
      <span><kbd class="text-neutral-600">o</kbd> open in $EDITOR</span>
      <span><kbd class="text-neutral-600">F</kbd> follow</span>
      <span><kbd class="text-neutral-600">Tab</kbd> switch pane</span>
    </div>
    """
  end

  defp file_list(assigns) do
    ~H"""
    <div :if={@files == []} class="text-neutral-400 p-2">No changes</div>
    <div
      :for={{file, idx} <- Enum.with_index(@files)}
      class={"flex items-center gap-2 px-1 py-0.5 cursor-default #{if idx == @nav.file_index && @nav.focus == :file_list, do: "bg-blue-50 text-blue-900", else: ""}"}
    >
      <span class={"w-4 text-center font-semibold #{status_color(file.unstaged_status || file.staged_status)}"}><%= status_char(file.unstaged_status || file.staged_status) %></span>
      <span class="truncate"><%= file.path %></span>
      <span :if={diff = @diffs[file.path]} class="ml-auto text-xs text-neutral-400">
        <span :if={diff.additions > 0} class="text-green-600">+<%= diff.additions %></span>
        <span :if={diff.deletions > 0} class="text-red-600 ml-1">-<%= diff.deletions %></span>
      </span>
    </div>
    """
  end

  defp log_list(assigns) do
    ~H"""
    <div :if={@entries == []} class="text-neutral-400 p-2">No commits</div>
    <div
      :for={{entry, idx} <- Enum.with_index(@entries)}
      class={"flex items-center gap-2 px-1 py-0.5 cursor-default #{if idx == @nav.log_index, do: "bg-purple-50 text-purple-900", else: ""}"}
    >
      <span class="text-amber-600 font-semibold w-16 shrink-0"><%= entry.hash %></span>
      <span class="truncate"><%= entry.message %></span>
    </div>
    """
  end

  defp commit_message(%{detail: nil} = assigns) do
    ~H"""
    <div class="text-neutral-400 p-4">No commit selected</div>
    """
  end

  defp commit_message(assigns) do
    ~H"""
    <pre class="whitespace-pre-wrap text-[12px] leading-relaxed p-2"><%= @detail %></pre>
    """
  end

  defp diff_pane(%{diff: nil} = assigns) do
    ~H"""
    <div class="text-neutral-400 p-4">Select a file to view diff</div>
    """
  end

  defp diff_pane(assigns) do
    ~H"""
    <div>
      <div class="text-neutral-500 text-xs mb-2 px-1"><%= @diff.path %></div>
      <div :if={@diff.binary} class="text-neutral-400 px-1">Binary file</div>
      <div :for={{hunk, idx} <- Enum.with_index(@diff.hunks)} class="mb-4">
        <div class={"px-2 py-1 text-xs bg-blue-50 text-blue-700 border-y border-neutral-200 #{if @nav.focus == :diff_view && idx == @nav.hunk_index, do: "ring-1 ring-blue-400", else: ""} #{if @nav.focus == :log_detail && idx == @nav.hunk_index, do: "ring-1 ring-purple-400", else: ""}"}>
          <%= hunk.header %>
        </div>
        <div :for={line <- hunk.lines} class={"flex #{line_class(line, hunk)}"}>
          <span class="w-8 text-right pr-2 text-neutral-300 select-none shrink-0"><%= line.old_line_number || "" %></span>
          <span class="w-8 text-right pr-2 text-neutral-300 select-none shrink-0"><%= line.new_line_number || "" %></span>
          <span class="px-1 whitespace-pre flex-1"><%= line_prefix(line.type) %><%= line.content %></span>
        </div>
      </div>
    </div>
    """
  end

  defp status_char(:modified), do: "M"
  defp status_char(:added), do: "A"
  defp status_char(:deleted), do: "D"
  defp status_char(:renamed), do: "R"
  defp status_char(:untracked), do: "?"
  defp status_char(_), do: " "

  defp status_color(:modified), do: "text-amber-600"
  defp status_color(:added), do: "text-green-600"
  defp status_color(:deleted), do: "text-red-600"
  defp status_color(:untracked), do: "text-neutral-400"
  defp status_color(_), do: ""

  defp line_class(line, hunk) do
    hot? = hunk.highlighted_at && DateTime.diff(DateTime.utc_now(), hunk.highlighted_at, :second) < 3

    case {line.type, hot?} do
      {:addition, true} -> "bg-green-200"
      {:addition, false} -> "bg-green-50"
      {:deletion, true} -> "bg-red-200"
      {:deletion, false} -> "bg-red-50"
      _ -> ""
    end
  end

  defp line_prefix(:addition), do: "+"
  defp line_prefix(:deletion), do: "-"
  defp line_prefix(:context), do: " "
end

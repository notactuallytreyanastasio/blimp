defmodule TermDiffWeb.DiffLive do
  use TermDiffWeb, :live_view

  alias TermDiff.Diff.{CommitState, Navigation}
  alias TermDiff.Git.{Diff, Log, Runner, Status, Watcher}
  alias TermDiff.Git.Types.RepoState
  alias TermDiff.Commentary.Store, as: CommentaryStore

  @impl true
  def mount(params, _session, socket) do
    configured_path = Application.get_env(:term_diff, :repo_path, File.cwd!())
    repo_path = params["path"] || configured_path

    if connected?(socket) do
      Watcher.subscribe()
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "commentary:updates")
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
      |> assign(:commentary_status, :idle)
      |> assign(:expanded_comments, MapSet.new())
      |> assign(:commit, CommitState.new())

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="term-diff" phx-hook="KeyNav" class="h-screen flex flex-col font-mono text-[13px] leading-snug bg-white text-neutral-900">
      <.status_bar repo_state={@repo_state} nav={@nav} repo_path={@repo_path} commentary_status={@commentary_status} />
      <.keybinding_bar nav={@nav} />

      <div class="flex flex-1 overflow-hidden">
        <.commit_layout :if={CommitState.active?(@commit)} commit={@commit} repo_state={@repo_state} />
        <.log_layout
          :if={!CommitState.active?(@commit) && @nav.focus in [:log_view, :log_detail]}
          nav={@nav}
          log_entries={@log_entries}
          commit_detail={@commit_detail}
          commit_diff={@commit_diff}
        />
        <.diff_layout
          :if={!CommitState.active?(@commit) && @nav.focus not in [:log_view, :log_detail]}
          nav={@nav}
          repo_state={@repo_state}
          selected_diff={@selected_diff}
          expanded_comments={@expanded_comments}
        />
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
  def handle_info(:commentary_reviewing, socket) do
    {:noreply, assign(socket, :commentary_status, :reviewing)}
  end

  @impl true
  def handle_info(:commentary_ready, socket) do
    {:noreply, assign(socket, :commentary_status, :ready)}
  end

  @impl true
  def handle_info(:commentary_error, socket) do
    {:noreply, assign(socket, :commentary_status, :error)}
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

    # Kick off async commentary review if there are diffs
    maybe_request_review(repo_state, socket.assigns.repo_path)

    socket =
      socket
      |> assign(:repo_state, repo_state)
      |> assign(:nav, nav)
      |> assign(:selected_diff, selected_diff)

    {:noreply, socket}
  end

  @impl true
  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    if CommitState.active?(socket.assigns.commit) do
      {:noreply, assign(socket, :commit, CommitState.cancel(socket.assigns.commit))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("keydown", _params, socket) when socket.assigns.commit.phase in [:editing, :submitting] do
    {:noreply, socket}
  end

  @impl true
  def handle_event("keydown", %{"key" => key}, socket) do
    # Dismiss commit error on any key
    socket =
      if socket.assigns.commit.phase == :error do
        assign(socket, :commit, CommitState.cancel(socket.assigns.commit))
      else
        socket
      end

    current_nav = socket.assigns.nav
    current_file = select_file_for_nav(socket.assigns.repo_state.files, current_nav)
    current_nav = %{current_nav | selected_file: current_file}

    nav = Navigation.handle_key(current_nav, key)

    socket =
      socket
      |> handle_open_file(nav)
      |> handle_stage_actions(nav)
      |> handle_nav_change(nav)
      |> handle_commit_enter(key)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_file", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    nav = %{socket.assigns.nav | file_index: idx, focus: :diff_view}

    selected_file = select_file_for_nav(socket.assigns.repo_state.files, nav)
    selected_diff = if selected_file, do: Map.get(socket.assigns.repo_state.diffs, selected_file)
    hunk_count = if selected_diff, do: length(selected_diff.hunks), else: 0
    nav = %{nav | selected_file: selected_file, hunk_count: hunk_count, hunk_index: 0}

    socket =
      socket
      |> assign(:nav, nav)
      |> assign(:selected_diff, selected_diff)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_commit_message", %{"message" => message}, socket) do
    commit = CommitState.update_message(socket.assigns.commit, message)
    {:noreply, assign(socket, :commit, commit)}
  end

  @impl true
  def handle_event("submit_commit", %{"message" => message}, socket) do
    commit =
      socket.assigns.commit
      |> CommitState.update_message(message)
      |> CommitState.submit()

    {:noreply, execute_commit(socket, commit)}
  end

  @impl true
  def handle_event("cancel_commit", _params, socket) do
    {:noreply, assign(socket, :commit, CommitState.cancel(socket.assigns.commit))}
  end

  @impl true
  def handle_event("toggle_comment", %{"id" => annotation_id}, socket) do
    expanded = socket.assigns.expanded_comments

    expanded =
      if MapSet.member?(expanded, annotation_id),
        do: MapSet.delete(expanded, annotation_id),
        else: MapSet.put(expanded, annotation_id)

    {:noreply, assign(socket, :expanded_comments, expanded)}
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

  defp execute_commit(socket, %{phase: :submitting} = commit) do
    commit
    |> run_git_commit(socket.assigns.repo_path)
    |> handle_commit_result(socket, commit)
  end

  defp execute_commit(socket, commit), do: assign(socket, :commit, commit)

  defp run_git_commit(%{mode: :amend, message: message}, repo_path) do
    Runner.commit_amend(repo_path, String.trim(message))
  end

  defp run_git_commit(%{message: message}, repo_path) do
    Runner.commit(repo_path, String.trim(message))
  end

  defp handle_commit_result({:ok, _output}, socket, commit) do
    send(self(), :refresh)
    assign(socket, :commit, CommitState.complete(commit))
  end

  defp handle_commit_result({:error, error}, socket, commit) do
    assign(socket, :commit, CommitState.fail(commit, error))
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

  defp handle_stage_actions(socket, nav) do
    cond do
      nav.stage_file ->
        Runner.stage(socket.assigns.repo_path, nav.stage_file)
        nav = Navigation.clear_stage_action(nav)
        socket = assign(socket, :nav, nav)
        send(self(), :refresh)
        socket

      nav.unstage_file ->
        file_entry = Enum.find(socket.assigns.repo_state.files, &(&1.path == nav.unstage_file))
        staged_status = if file_entry, do: file_entry.staged_status
        Runner.unstage(socket.assigns.repo_path, nav.unstage_file, staged_status: staged_status)
        nav = Navigation.clear_stage_action(nav)
        socket = assign(socket, :nav, nav)
        send(self(), :refresh)
        socket

      true ->
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

      untracked_files =
        files
        |> Enum.filter(fn f -> f.unstaged_status == :untracked end)
        |> Enum.map(& &1.path)

      untracked_diffs =
        Enum.flat_map(untracked_files, fn path ->
          case Runner.diff_untracked(repo_path, path) do
            {:ok, raw} -> Diff.parse(raw)
            _ -> []
          end
        end)

      diff_map =
        Map.merge(
          Map.new(staged_diffs, fn d -> {d.path, d} end),
          Map.new(unstaged_diffs, fn d -> {d.path, d} end)
        )
        |> Map.merge(Map.new(untracked_diffs, fn d -> {d.path, d} end))

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

  defp handle_commit_enter(socket, "cc") do
    staged_count = count_staged(socket.assigns.repo_state.files)
    commit = CommitState.enter(:commit, staged_count: staged_count)
    assign(socket, :commit, commit)
  end

  defp handle_commit_enter(socket, "a") do
    last_message =
      case Runner.last_commit_message(socket.assigns.repo_path) do
        {:ok, msg} -> msg
        _ -> nil
      end

    commit = CommitState.enter(:amend, last_message: last_message)
    assign(socket, :commit, commit)
  end

  defp handle_commit_enter(socket, _key), do: socket

  defp count_staged(files) do
    Enum.count(files, fn f -> f.staged_status && f.staged_status != :untracked end)
  end

  defp maybe_request_review(_repo_state, repo_path) do
    raw_diff = build_raw_diff(repo_path)

    if raw_diff != "" do
      TermDiff.Commentary.Server.request_review(raw_diff, repo_path)
    end
  end

  defp build_raw_diff(repo_path) do
    case Runner.diff(repo_path) do
      {:ok, diff} -> diff
      _ -> ""
    end
  end

  defp annotations_for_line(file_path, line_number) do
    CommentaryStore.get_annotations_for_line(file_path, line_number)
  end

  # ── Layout Components ──

  defp commit_layout(%{commit: %{phase: :error}} = assigns) do
    ~H"""
    <div class="flex flex-1 items-center justify-center">
      <div class="bg-red-50 border border-red-200 rounded p-4 max-w-md text-center">
        <div class="text-red-700 text-sm font-semibold mb-2">{@commit.error}</div>
        <div class="text-neutral-500 text-xs">Press any key or Esc to dismiss</div>
      </div>
    </div>
    """
  end

  defp commit_layout(assigns) do
    ~H"""
    <div class="flex flex-1 overflow-hidden">
      <div class="w-1/2 border-r border-neutral-200 flex flex-col p-4">
        <div class="text-xs text-neutral-500 mb-2 font-semibold">
          {if @commit.mode == :amend, do: "AMEND COMMIT", else: "COMMIT MESSAGE"}
        </div>
        <form phx-submit="submit_commit" phx-change="update_commit_message" class="flex flex-col flex-1">
          <textarea
            name="message"
            value={@commit.message}
            placeholder="First line: concise summary&#10;&#10;Body: explain WHY, not just WHAT changed."
            class="flex-1 w-full p-3 bg-neutral-50 border border-neutral-200 rounded text-[13px] font-mono leading-relaxed resize-none focus:outline-none focus:ring-2 focus:ring-green-400/60 focus:border-transparent"
            autofocus
          ></textarea>
          <div class="flex items-center justify-between mt-3">
            <div class="text-[11px] text-neutral-400">
              <span>{length(@repo_state.files)} files</span>
            </div>
            <div class="flex gap-2">
              <button type="button" phx-click="cancel_commit" class="px-3 py-1 text-xs border border-neutral-300 rounded hover:bg-neutral-100">
                Cancel (Esc)
              </button>
              <button type="submit" class="px-3 py-1 text-xs bg-green-600 text-white rounded hover:bg-green-700">
                {if @commit.mode == :amend, do: "Amend", else: "Commit"}
              </button>
            </div>
          </div>
        </form>
      </div>
      <div class="w-1/2 flex flex-col p-4 overflow-y-auto">
        <div class="text-xs text-neutral-500 mb-2 font-semibold">STAGED CHANGES</div>
        <div :for={file <- @repo_state.files} class="text-[12px] py-0.5">
          <span :if={file.staged_status && file.staged_status != :untracked} class={"font-semibold #{status_color(file.staged_status)}"}>{status_char(file.staged_status)}</span>
          <span :if={file.staged_status && file.staged_status != :untracked} class="ml-2">{file.path}</span>
        </div>
      </div>
    </div>
    """
  end

  defp diff_layout(assigns) do
    ~H"""
    <div class={"w-80 border-r border-neutral-200 overflow-y-auto p-2 shrink-0 #{pane_glow(@nav.focus == :file_list)}"}>
      <.file_list files={@repo_state.files} nav={@nav} diffs={@repo_state.diffs} />
    </div>
    <div class={"flex-1 overflow-y-auto p-2 #{pane_glow(@nav.focus == :diff_view)}"} id="diff-pane" phx-hook="AutoScroll">
      <.diff_pane diff={@selected_diff} nav={@nav} expanded_comments={@expanded_comments} />
    </div>
    """
  end

  defp log_layout(assigns) do
    ~H"""
    <div :if={@nav.focus == :log_view} class={"flex-1 overflow-y-auto p-2 #{pane_glow(true)}"}>
      <.log_list entries={@log_entries} nav={@nav} />
    </div>
    <div :if={@nav.focus != :log_view} class={"w-1/2 border-r border-neutral-200 overflow-y-auto p-2 #{pane_glow(@nav.focus == :log_detail)}"}>
      <.commit_message detail={@commit_detail} />
    </div>
    <div :if={@nav.focus != :log_view} class={"flex-1 overflow-y-auto p-2 #{pane_glow(@nav.focus == :log_detail)}"} id="diff-pane" phx-hook="AutoScroll">
      <.diff_pane diff={@commit_diff} nav={@nav} />
    </div>
    """
  end

  defp pane_glow(true), do: "ring-2 ring-green-400/60 ring-inset shadow-[inset_0_0_8px_rgba(74,222,128,0.2)]"
  defp pane_glow(false), do: ""

  # ── UI Components ──

  defp status_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-3 py-1 border-b border-neutral-200 text-neutral-500 text-xs">
      <div class="flex items-center gap-3">
        <span class="text-neutral-900 font-semibold">{@repo_state.branch || "no branch"}</span>
        <span>{length(@repo_state.files)} files</span>
        <span class="text-neutral-300 truncate max-w-xs">{@repo_path}</span>
      </div>
      <div class="flex gap-4">
        <span :if={@commentary_status == :reviewing} class="text-amber-600 font-semibold animate-pulse">REVIEWING</span>
        <span :if={@commentary_status == :ready} class="text-blue-600 font-semibold">AI</span>
        <span :if={@commentary_status == :error} class="text-red-500 font-semibold">AI ERR</span>
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
      <span><kbd class="text-neutral-600">s</kbd> stage</span>
      <span><kbd class="text-neutral-600">u</kbd> unstage</span>
      <span><kbd class="text-neutral-600">cc</kbd> commit</span>
      <span><kbd class="text-neutral-600">a</kbd> amend</span>
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
      phx-click="select_file"
      phx-value-index={idx}
      data-selected={if idx == @nav.file_index && @nav.focus == :file_list, do: "true"}
      class={"flex items-center gap-2 px-1 py-0.5 cursor-pointer hover:bg-neutral-50 relative #{file_row_class(idx, @nav)}"}
    >
      <span class={"w-4 text-center font-semibold #{status_color(file.unstaged_status || file.staged_status)}"}>{status_char(file.unstaged_status || file.staged_status)}</span>
      <span :if={file.staged_status && file.staged_status != :untracked} class="text-green-600 text-[10px] font-semibold w-3">S</span>
      <span :if={!file.staged_status || file.staged_status == :untracked} class="w-3"></span>
      <span class="truncate" title={file.path}>{file.path}</span>
      <span :if={diff = @diffs[file.path]} class="ml-auto text-xs text-neutral-400">
        <span :if={diff.additions > 0} class="text-green-600">+{diff.additions}</span>
        <span :if={diff.deletions > 0} class="text-red-600 ml-1">-{diff.deletions}</span>
      </span>
    </div>
    """
  end

  defp log_list(assigns) do
    ~H"""
    <div :if={@entries == []} class="text-neutral-400 p-2">No commits</div>
    <div
      :for={{entry, idx} <- Enum.with_index(@entries)}
      data-selected={if idx == @nav.log_index && @nav.focus == :log_view, do: "true"}
      class={"flex items-center gap-2 px-1 py-0.5 cursor-default #{log_row_class(idx, @nav)}"}
    >
      <span class="text-amber-600 font-semibold w-16 shrink-0">{entry.hash}</span>
      <span class="truncate">{entry.message}</span>
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
    <pre class="whitespace-pre-wrap text-[12px] leading-relaxed p-2">{@detail}</pre>
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
      <div class="text-neutral-500 text-xs mb-2 px-1">{@diff.path}</div>
      <div :if={@diff.binary} class="text-neutral-400 px-1">Binary file</div>
      <div :for={{hunk, idx} <- Enum.with_index(@diff.hunks)} class="mb-4">
        <div
          data-selected={if @nav.focus in [:diff_view, :log_detail] && idx == @nav.hunk_index, do: "true"}
          class={"px-2 py-1 text-xs border-y border-neutral-200 #{if (@nav.focus == :diff_view || @nav.focus == :log_detail) && idx == @nav.hunk_index, do: "bg-blue-400/5 ring-1 ring-blue-400/40 text-blue-700", else: "bg-blue-50 text-blue-700"}"}
        >
          {hunk.header}
        </div>
        <div :for={line <- hunk.lines}>
          <% line_annotations = if line.new_line_number, do: annotations_for_line(@diff.path, line.new_line_number), else: [] %>
          <div class={"flex #{line_class(line, hunk)}"}>
            <span class="w-8 text-right pr-2 text-neutral-300 select-none shrink-0">{line.old_line_number || ""}</span>
            <span class="w-8 text-right pr-2 text-neutral-300 select-none shrink-0">{line.new_line_number || ""}</span>
            <span
              :if={line_annotations != []}
              phx-click="toggle_comment"
              phx-value-id={hd(line_annotations).id}
              class={"w-4 text-center cursor-pointer shrink-0 #{severity_color_dot(hd(line_annotations).severity)}"}
              title={hd(line_annotations).comment}
            >{severity_icon(hd(line_annotations).severity)}</span>
            <span :if={line_annotations == []} class="w-4 shrink-0"></span>
            <span class="px-1 whitespace-pre flex-1">{line_prefix(line.type)}{line.content}</span>
          </div>
          <div
            :for={ann <- Enum.filter(line_annotations, &MapSet.member?(@expanded_comments, &1.id))}
            class="ml-24 p-2 mb-1 bg-amber-50 border-l-2 border-amber-400 text-xs text-neutral-700"
          >
            {ann.comment}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp file_row_class(idx, nav) do
    cond do
      idx == nav.file_index && nav.focus == :file_list ->
        "bg-blue-400/5 ring-1 ring-blue-400/40 text-blue-900"

      idx == nav.file_index && nav.focus == :diff_view ->
        "bg-blue-50 text-blue-900"

      true ->
        ""
    end
  end

  defp log_row_class(idx, nav) do
    cond do
      idx == nav.log_index && nav.focus == :log_view ->
        "bg-blue-400/5 ring-1 ring-blue-400/40 text-purple-900"

      idx == nav.log_index ->
        "bg-purple-50 text-purple-900"

      true ->
        ""
    end
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

  defp severity_icon(:issue), do: "!"
  defp severity_icon(:warning), do: "~"
  defp severity_icon(_), do: "."

  defp severity_color_dot(:issue), do: "text-red-500"
  defp severity_color_dot(:warning), do: "text-amber-500"
  defp severity_color_dot(_), do: "text-blue-500"
end

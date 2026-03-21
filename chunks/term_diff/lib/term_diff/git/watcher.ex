defmodule TermDiff.Git.Watcher do
  @moduledoc """
  Watches a git repository for file changes.
  Debounces rapid events and broadcasts via PubSub.

  Watches both working tree changes AND git internal state:
  .git/index (stage/unstage), .git/refs/ (commits, branches),
  .git/HEAD (checkout), .git/MERGE_HEAD, .git/REBASE_HEAD.
  """
  use GenServer

  @debounce_ms 200
  @topic "repo:changes"

  # Git internal paths that indicate state changes we care about
  @git_watch_patterns ["/index", "/refs/", "/HEAD", "/MERGE_HEAD", "/REBASE_HEAD"]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)
    GenServer.start_link(__MODULE__, repo_path, name: __MODULE__)
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(TermDiff.PubSub, @topic)
  end

  @impl true
  def init(repo_path) do
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [repo_path], latency: 0)
    FileSystem.subscribe(watcher_pid)

    {:ok, %{repo_path: repo_path, watcher_pid: watcher_pid, debounce_ref: nil}}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    if relevant_change?(path) do
      if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
      ref = Process.send_after(self(), :debounced_change, @debounce_ms)
      {:noreply, %{state | debounce_ref: ref}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:debounced_change, state) do
    Phoenix.PubSub.broadcast(TermDiff.PubSub, @topic, :repo_changed)
    {:noreply, %{state | debounce_ref: nil}}
  end

  defp relevant_change?(path) do
    cond do
      git_state_change?(path) -> true
      String.contains?(path, "/.git/") -> false
      true -> true
    end
  end

  defp git_state_change?(path) do
    Enum.any?(@git_watch_patterns, &String.contains?(path, &1))
  end
end

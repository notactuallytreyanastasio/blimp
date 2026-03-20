defmodule TermDiff.Commentary.Server do
  @moduledoc """
  Orchestrates AI review cycles.

  Spawns Tasks under a Task.Supervisor to call Claude, stores results
  in the Commentary.Store, and broadcasts updates via PubSub.

  Accepts injectable :caller, :store, and :task_supervisor options
  for testing without hitting the real Claude CLI.
  """

  use GenServer

  require Logger

  alias TermDiff.Commentary.{Hash, Parser, Prompt, Store}

  # ── Client API ──

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec request_review(String.t(), String.t(), GenServer.server()) :: :ok
  def request_review(raw_diff, repo_path, server \\ __MODULE__) do
    GenServer.cast(server, {:request_review, raw_diff, repo_path})
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    state = %{
      repo_path: Keyword.get(opts, :repo_path),
      caller: Keyword.get(opts, :caller, &default_caller/3),
      store: Keyword.get(opts, :store, Store),
      task_supervisor: Keyword.get(opts, :task_supervisor, TermDiff.Commentary.TaskSupervisor),
      current_task_ref: nil,
      current_task_pid: nil,
      last_diff_hash: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:request_review, raw_diff, repo_path}, state) do
    diff_hash = Hash.hash_diff(raw_diff)

    if diff_hash == state.last_diff_hash do
      broadcast(:commentary_ready)
      {:noreply, state}
    else
      state = cancel_current_task(state)

      Store.mark_reviewing(state.store)
      broadcast(:commentary_reviewing)

      task =
        Task.Supervisor.async_nolink(
          state.task_supervisor,
          fn -> run_review(raw_diff, repo_path, diff_hash, state.caller) end
        )

      {:noreply, %{state | current_task_ref: task.ref, current_task_pid: task.pid, last_diff_hash: diff_hash}}
    end
  end

  @impl true
  def handle_info({ref, {:ok, review_result}}, %{current_task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    Store.put_review(review_result, state.store)
    broadcast(:commentary_ready)
    {:noreply, %{state | current_task_ref: nil, current_task_pid: nil}}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, %{current_task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    Logger.warning("Commentary review failed: #{inspect(reason)}")
    broadcast(:commentary_error)
    {:noreply, %{state | current_task_ref: nil, current_task_pid: nil}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task_ref: ref} = state) do
    Logger.warning("Commentary task crashed: #{inspect(reason)}")
    broadcast(:commentary_error)
    {:noreply, %{state | current_task_ref: nil, current_task_pid: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──

  defp run_review(raw_diff, repo_path, diff_hash, caller) do
    prompt = Prompt.build(raw_diff)

    case caller.(prompt, repo_path, model: "sonnet") do
      {:ok, response_text} ->
        case Parser.parse_response(response_text) do
          {:ok, result} ->
            {:ok, %{result | diff_hash: diff_hash}}

          {:error, reason} ->
            {:error, "Failed to parse response: #{reason}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_current_task(%{current_task_ref: nil} = state), do: state

  defp cancel_current_task(%{current_task_ref: ref, current_task_pid: pid} = state) do
    Process.demonitor(ref, [:flush])
    Task.Supervisor.terminate_child(state.task_supervisor, pid)
    %{state | current_task_ref: nil, current_task_pid: nil}
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(TermDiff.PubSub, "commentary:updates", message)
  end

  defp default_caller(prompt, repo_path, opts) do
    TermDiff.AI.Claude.ask(prompt, repo_path, opts)
  end
end

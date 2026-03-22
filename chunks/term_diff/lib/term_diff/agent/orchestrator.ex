defmodule TermDiff.Agent.Orchestrator do
  @moduledoc """
  Central coordinator GenServer for managing agent runs.

  The Orchestrator:
  - Tracks all active and queued runs in memory
  - Enforces `max_concurrent` agent slots (default 5)
  - Queues runs when at capacity and auto-dispatches when slots open
  - Detects stalled agents (no events for a configurable timeout)
  - Retries failed runs with exponential backoff
  """
  use GenServer

  require Logger

  alias TermDiff.Agent.Events
  alias TermDiff.Agent.Run
  alias TermDiff.Agent.Runner.ClaudeCode
  alias TermDiff.Agent.Runner.Supervisor, as: RunnerSupervisor
  alias TermDiff.Agent.Runs

  @default_max_concurrent 5
  @default_stall_timeout_ms 300_000
  @default_max_retries 2
  @stall_check_interval_ms 30_000

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            max_concurrent: pos_integer(),
            stall_timeout_ms: pos_integer(),
            max_retries: non_neg_integer(),
            active: %{
              integer() => %{
                pid: pid(),
                monitor_ref: reference(),
                last_event_at: DateTime.t(),
                attempt: non_neg_integer()
              }
            },
            queue: [{integer(), non_neg_integer()}],
            retry_timers: %{integer() => reference()},
            runner_config: map()
          }

    defstruct [
      :max_concurrent,
      :stall_timeout_ms,
      :max_retries,
      active: %{},
      queue: [],
      retry_timers: %{},
      runner_config: %{}
    ]
  end

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec dispatch(integer(), GenServer.server()) :: {:ok, :dispatched | :queued} | {:error, term()}
  def dispatch(run_id, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(server, {:dispatch, run_id})
    end
  end

  @spec cancel(integer(), GenServer.server()) :: :ok | {:error, :not_found}
  def cancel(run_id, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> {:error, :not_found}
      _pid -> GenServer.call(server, {:cancel, run_id})
    end
  end

  @spec continue_run(integer(), String.t(), GenServer.server()) ::
          {:ok, TermDiff.Agent.Run.t()} | {:error, term()}
  def continue_run(parent_run_id, prompt, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(server, {:continue, parent_run_id, prompt})
    end
  end

  @spec get_state(GenServer.server()) :: State.t()
  def get_state(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %State{max_concurrent: 0, stall_timeout_ms: 0, max_retries: 0}
      _pid -> GenServer.call(server, :get_state)
    end
  end

  @spec respond_to_permission(
          integer(),
          String.t(),
          String.t(),
          String.t() | nil,
          GenServer.server()
        ) :: :ok | {:error, term()}
  def respond_to_permission(run_id, tool_use_id, behavior, message \\ nil, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(server, {:permission_response, run_id, tool_use_id, behavior, message})
    end
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    Phoenix.PubSub.subscribe(TermDiff.PubSub, "events:run.finished")
    Phoenix.PubSub.subscribe(TermDiff.PubSub, "events:run.output")

    schedule_stall_check()

    state = %State{
      max_concurrent: Keyword.get(opts, :max_concurrent, @default_max_concurrent),
      stall_timeout_ms: Keyword.get(opts, :stall_timeout_ms, @default_stall_timeout_ms),
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      runner_config: Keyword.get(opts, :runner_config, %{})
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:dispatch, run_id}, _from, state) do
    if slots_available?(state) do
      case do_dispatch(run_id, 0, state) do
        {:ok, new_state} ->
          {:reply, {:ok, :dispatched}, new_state}

        {:error, reason, new_state} ->
          {:reply, {:error, reason}, new_state}
      end
    else
      new_state = %{state | queue: state.queue ++ [{run_id, 0}]}
      {:reply, {:ok, :queued}, new_state}
    end
  end

  def handle_call({:cancel, run_id}, _from, state) do
    cond do
      Map.has_key?(state.active, run_id) ->
        new_state = cancel_active_run(run_id, state)
        new_state = dispatch_next_from_queue(new_state)
        {:reply, :ok, new_state}

      queue_has_run?(state.queue, run_id) ->
        new_queue = Enum.reject(state.queue, fn {id, _attempt} -> id == run_id end)
        new_state = %{state | queue: new_queue}
        mark_run_cancelled(run_id)
        {:reply, :ok, new_state}

      true ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:continue, parent_run_id, prompt}, _from, state) do
    parent_run = Runs.get_run!(parent_run_id)

    case create_and_dispatch_continuation(parent_run, prompt, state) do
      {:ok, run, new_state} -> {:reply, {:ok, run}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:permission_response, run_id, tool_use_id, behavior, message}, _from, state) do
    result =
      case Map.fetch(state.active, run_id) do
        {:ok, %{pid: pid}} ->
          dispatch_permission_response(pid, tool_use_id, behavior, message)

        :error ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(
        {:event, %{type: "run.finished", data: %{"run_id" => run_id} = data}},
        state
      ) do
    case Map.fetch(state.active, run_id) do
      {:ok, %{attempt: attempt}} ->
        status = Map.get(data, "status", "failed")
        new_state = %{state | active: Map.delete(state.active, run_id)}

        new_state =
          if status == "failed" do
            maybe_retry(run_id, attempt, new_state)
          else
            new_state
          end

        new_state = dispatch_next_from_queue(new_state)
        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:event, %{type: "run.output", data: %{"run_id" => run_id}}},
        state
      ) do
    if Map.has_key?(state.active, run_id) do
      new_active =
        Map.update!(state.active, run_id, fn entry ->
          %{entry | last_event_at: DateTime.utc_now()}
        end)

      {:noreply, %{state | active: new_active}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:check_stalled, state) do
    new_state = detect_stalled_agents(state)
    schedule_stall_check()
    {:noreply, new_state}
  end

  def handle_info({:retry, run_id, attempt}, state) do
    new_timers = Map.delete(state.retry_timers, run_id)
    state = %{state | retry_timers: new_timers}

    if slots_available?(state) do
      case do_dispatch(run_id, attempt, state) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, _reason, new_state} ->
          {:noreply, new_state}
      end
    else
      new_state = %{state | queue: state.queue ++ [{run_id, attempt}]}
      {:noreply, new_state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_run_by_monitor(state.active, ref, pid) do
      {:ok, run_id, %{attempt: attempt}} ->
        Logger.warning("Agent process for run #{run_id} went down: #{inspect(reason)}")

        new_active = Map.delete(state.active, run_id)
        new_state = %{state | active: new_active}

        case Runs.get_run(run_id) do
          %Run{status: "running"} = run ->
            Runs.update_run(run, %{
              status: "failed",
              error: "Agent process crashed: #{inspect(reason)}",
              finished_at: DateTime.utc_now()
            })

            Events.emit(%{
              type: "run.finished",
              source: "orchestrator",
              data: %{
                "run_id" => run_id,
                "status" => "failed",
                "reason" => "process_down"
              }
            })

          _gone_or_terminal ->
            :ok
        end

        new_state = maybe_retry(run_id, attempt, new_state)
        new_state = dispatch_next_from_queue(new_state)
        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private Functions ---

  defp dispatch_permission_response(pid, tool_use_id, behavior, message) do
    if function_exported?(ClaudeCode, :respond_to_permission, 5) do
      ClaudeCode.respond_to_permission(pid, tool_use_id, behavior, message, nil)
    else
      {:error, :not_supported}
    end
  end

  defp slots_available?(state) do
    map_size(state.active) < state.max_concurrent
  end

  defp do_dispatch_with_config(run_id, attempt, config, state) do
    run = Runs.get_run!(run_id)
    prompt = run.prompt
    workspace = run.repo_path || run.workspace_path || System.tmp_dir!()

    case RunnerSupervisor.start_child(ClaudeCode, config, prompt, workspace) do
      {:ok, pid} ->
        monitor_ref = Process.monitor(pid)

        entry = %{
          pid: pid,
          monitor_ref: monitor_ref,
          last_event_at: DateTime.utc_now(),
          attempt: attempt
        }

        new_active = Map.put(state.active, run_id, entry)
        {:ok, %{state | active: new_active}}

      {:error, reason} ->
        Logger.error("Failed to start agent for run #{run_id}: #{inspect(reason)}")
        _ = run
        {:error, reason, state}
    end
  end

  defp create_and_dispatch_continuation(parent_run, prompt, state) do
    with session_id when not is_nil(session_id) <- parent_run.session_id,
         {:ok, run} <-
           Runs.create_run(%{
             agent_type: parent_run.agent_type,
             prompt: prompt,
             title: parent_run.title,
             repo_path: parent_run.repo_path,
             workspace_path: parent_run.workspace_path,
             parent_run_id: parent_run.id,
             permission_mode: parent_run.permission_mode,
             status: "pending"
           }) do
      config =
        %{run_id: run.id, resume_session_id: session_id}
        |> Map.merge(state.runner_config)
        |> apply_run_permission_mode(run)

      case dispatch_or_queue(run.id, config, state) do
        {:ok, new_state} -> {:ok, run, new_state}
        {{:error, reason}, new_state} -> {:error, reason, new_state}
      end
    else
      nil -> {:error, :no_session_id, state}
      {:error, changeset} -> {:error, changeset, state}
    end
  end

  defp dispatch_or_queue(run_id, config, state) do
    if slots_available?(state) do
      case do_dispatch_with_config(run_id, 0, config, state) do
        {:ok, new_state} -> {:ok, new_state}
        {:error, reason, new_state} -> {{:error, reason}, new_state}
      end
    else
      {:ok, %{state | queue: state.queue ++ [{run_id, 0}]}}
    end
  end

  defp do_dispatch(run_id, attempt, state) do
    config =
      %{run_id: run_id}
      |> Map.merge(state.runner_config)
      |> apply_run_permission_mode_from_id(run_id)
      |> maybe_inject_deciduous_context(run_id)

    do_dispatch_with_config(run_id, attempt, config, state)
  end

  defp maybe_inject_deciduous_context(config, run_id) do
    alias TermDiff.Agent.Deciduous

    case Runs.get_run(run_id) do
      %Run{prompt: prompt} = run when not is_nil(prompt) ->
        case Deciduous.create_root_node(prompt) do
          {:ok, root_id} ->
            Runs.update_run(run, %{deciduous_root: root_id})

            active_runs =
              Runs.list_runs()
              |> Enum.filter(&(&1.status == "running" and &1.id != run_id))

            preamble = Deciduous.build_agent_preamble(run_id, root_id, prompt, active_runs)

            existing = Map.get(config, :append_system_prompt, "")
            Map.put(config, :append_system_prompt, existing <> "\n" <> preamble)

          {:error, _reason} ->
            config
        end

      _ ->
        config
    end
  end

  defp cancel_active_run(run_id, state) do
    case Map.fetch(state.active, run_id) do
      {:ok, %{pid: pid}} ->
        RunnerSupervisor.stop_child(pid)
        mark_run_cancelled(run_id)
        %{state | active: Map.delete(state.active, run_id)}

      :error ->
        state
    end
  end

  defp mark_run_cancelled(run_id) do
    case Runs.get_run(run_id) do
      %Run{} = run ->
        Runs.update_run(run, %{
          status: "cancelled",
          finished_at: DateTime.utc_now()
        })

      nil ->
        :ok
    end

    Events.emit(%{
      type: "run.cancelled",
      source: "orchestrator",
      data: %{"run_id" => run_id}
    })
  end

  defp dispatch_next_from_queue(state) do
    case state.queue do
      [] ->
        state

      [{next_run_id, attempt} | rest] ->
        new_state = %{state | queue: rest}

        case do_dispatch(next_run_id, attempt, new_state) do
          {:ok, dispatched_state} ->
            dispatched_state

          {:error, _reason, failed_state} ->
            dispatch_next_from_queue(failed_state)
        end
    end
  end

  defp maybe_retry(run_id, previous_attempt, state) do
    case Runs.get_run(run_id) do
      %Run{} = run when previous_attempt < state.max_retries ->
        next_attempt = previous_attempt + 1
        delay = retry_delay(next_attempt)

        Logger.info("Scheduling retry #{next_attempt} for run #{run_id} in #{delay}ms")

        timer_ref = Process.send_after(self(), {:retry, run_id, next_attempt}, delay)
        new_timers = Map.put(state.retry_timers, run_id, timer_ref)

        Runs.update_run(run, %{status: "pending"})

        %{state | retry_timers: new_timers}

      %Run{} ->
        Logger.warning("Run #{run_id} exceeded max retries (#{state.max_retries})")
        state

      nil ->
        state
    end
  end

  defp retry_delay(attempt) do
    min(10_000 * Integer.pow(2, attempt), 300_000)
  end

  defp detect_stalled_agents(state) do
    now = DateTime.utc_now()

    stalled_run_ids =
      state.active
      |> Enum.filter(fn {_run_id, %{last_event_at: last_event_at}} ->
        diff = DateTime.diff(now, last_event_at, :millisecond)
        diff >= state.stall_timeout_ms
      end)
      |> Enum.map(fn {run_id, _entry} -> run_id end)

    Enum.reduce(stalled_run_ids, state, fn run_id, acc ->
      Logger.warning("Run #{run_id} detected as stalled, killing agent")
      entry = Map.fetch!(acc.active, run_id)
      RunnerSupervisor.stop_child(entry.pid)

      case Runs.get_run(run_id) do
        %Run{} = run ->
          Runs.update_run(run, %{
            status: "failed",
            error: "Agent stalled (no events for #{acc.stall_timeout_ms}ms)",
            finished_at: DateTime.utc_now()
          })

        nil ->
          :ok
      end

      Events.emit(%{
        type: "run.finished",
        source: "orchestrator",
        data: %{
          "run_id" => run_id,
          "status" => "failed",
          "reason" => "stalled"
        }
      })

      new_active = Map.delete(acc.active, run_id)
      new_state = %{acc | active: new_active}
      maybe_retry(run_id, entry.attempt, new_state)
    end)
    |> dispatch_next_from_queue()
  end

  defp find_run_by_monitor(active, ref, pid) do
    Enum.find_value(active, :error, fn {run_id, entry} ->
      if entry.monitor_ref == ref or entry.pid == pid do
        {:ok, run_id, entry}
      end
    end)
  end

  defp queue_has_run?(queue, run_id) do
    Enum.any?(queue, fn {id, _attempt} -> id == run_id end)
  end

  defp schedule_stall_check do
    Process.send_after(self(), :check_stalled, @stall_check_interval_ms)
  end

  defp apply_run_permission_mode(config, %{permission_mode: mode})
       when is_binary(mode) and mode not in ["default", ""] do
    if Map.has_key?(config, :permission_mode),
      do: config,
      else: Map.put(config, :permission_mode, mode)
  end

  defp apply_run_permission_mode(config, _run), do: config

  defp apply_run_permission_mode_from_id(config, run_id) do
    case Runs.get_run(run_id) do
      %Run{} = run -> apply_run_permission_mode(config, run)
      nil -> config
    end
  end
end

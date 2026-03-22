defmodule TermDiff.Agent.Runner.Supervisor do
  @moduledoc """
  DynamicSupervisor for agent runner processes.

  Each agent session (ClaudeCode) runs as a child
  of this supervisor. Provides start/stop/list operations.
  """
  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_child(module(), map(), String.t(), String.t()) ::
          {:ok, pid()} | {:error, term()}
  def start_child(runner_module, config, prompt, workspace_path) do
    spec = %{
      id: make_ref(),
      start: {runner_module, :start_run, [config, prompt, workspace_path]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @spec stop_child(pid()) :: :ok | {:error, :not_found}
  def stop_child(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @spec count_children() :: map()
  def count_children do
    DynamicSupervisor.count_children(__MODULE__)
  end
end

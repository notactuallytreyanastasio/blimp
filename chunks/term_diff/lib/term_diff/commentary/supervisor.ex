defmodule TermDiff.Commentary.Supervisor do
  @moduledoc "Supervises the commentary engine: Store, Server, and Task.Supervisor."

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    repo_path = Keyword.get(opts, :repo_path, Application.get_env(:term_diff, :repo_path, File.cwd!()))

    children = [
      TermDiff.Commentary.Store,
      {Task.Supervisor, name: TermDiff.Commentary.TaskSupervisor},
      {TermDiff.Commentary.Server, repo_path: repo_path}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

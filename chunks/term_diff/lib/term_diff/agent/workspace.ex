defmodule TermDiff.Agent.Workspace do
  @moduledoc """
  Manages git worktrees for agent sessions.

  Each agent run gets an isolated worktree so agents can modify files
  without interfering with each other or the main working directory.
  """

  require Logger

  @worktree_dir ".term_diff/worktrees"

  @doc """
  Creates a new git worktree for the given run.

  Returns `{:ok, worktree_path}` on success, or `{:error, reason}` on failure.
  The worktree is created under `<repo_path>/.term_diff/worktrees/<run_id>/`
  on a new branch named `term_diff/<run_id>`.
  """
  @spec create(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create(repo_path, run_id) do
    with :ok <- validate_path(repo_path),
         :ok <- ensure_git_repo(repo_path) do
      worktree_path = Path.join([repo_path, @worktree_dir, sanitize_id(run_id)])
      branch_name = "term_diff/#{sanitize_id(run_id)}"

      case System.cmd("git", ["worktree", "add", "-b", branch_name, worktree_path],
             cd: repo_path,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          Logger.info("Created worktree at #{worktree_path}")
          {:ok, worktree_path}

        {output, code} ->
          Logger.error("Failed to create worktree (exit #{code}): #{output}")
          {:error, {:git_error, output}}
      end
    end
  end

  @doc """
  Removes a previously created worktree and its associated branch.

  Returns `:ok` on success, or `{:error, reason}` on failure.
  """
  @spec cleanup(String.t(), String.t()) :: :ok | {:error, term()}
  def cleanup(repo_path, workspace_path) do
    case System.cmd("git", ["worktree", "remove", "--force", workspace_path],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        branch =
          workspace_path
          |> Path.basename()
          |> then(&"term_diff/#{&1}")

        System.cmd("git", ["branch", "-D", branch],
          cd: repo_path,
          stderr_to_stdout: true
        )

        Logger.info("Cleaned up worktree at #{workspace_path}")
        :ok

      {output, code} ->
        Logger.error("Failed to remove worktree (exit #{code}): #{output}")
        {:error, {:git_error, output}}
    end
  end

  defp validate_path(path) do
    if String.contains?(path, "..") do
      {:error, :invalid_path}
    else
      expanded = Path.expand(path)

      if File.dir?(expanded) do
        :ok
      else
        {:error, :not_a_directory}
      end
    end
  end

  defp ensure_git_repo(path) do
    case System.cmd("git", ["rev-parse", "--git-dir"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      _error -> {:error, :not_a_git_repo}
    end
  end

  defp sanitize_id(id) do
    id
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> String.slice(0, 50)
  end
end

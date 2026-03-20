defmodule TermDiff.Git.Runner do
  @moduledoc "Execute git commands via System.cmd. Imperative shell."

  @spec status(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def status(repo_path) do
    run(repo_path, ["status", "--porcelain=v1", "-u"])
  end

  @spec diff(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(repo_path) do
    run(repo_path, ["diff"])
  end

  @spec diff_staged(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff_staged(repo_path) do
    run(repo_path, ["diff", "--staged"])
  end

  @spec branch(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def branch(repo_path) do
    run(repo_path, ["rev-parse", "--abbrev-ref", "HEAD"])
  end

  @spec log_oneline(String.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def log_oneline(repo_path, count \\ 50) do
    run(repo_path, ["log", "--oneline", "--no-decorate", "-#{count}"])
  end

  @spec log_show(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def log_show(repo_path, commit_hash) do
    run(repo_path, ["show", commit_hash, "--stat", "--format=full"])
  end

  @spec log_diff(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def log_diff(repo_path, commit_hash) do
    run(repo_path, ["show", commit_hash, "--format="])
  end

  @spec stage(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def stage(repo_path, file_path) do
    run(repo_path, ["add", file_path])
  end

  @spec unstage(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def unstage(repo_path, file_path) do
    run(repo_path, ["reset", "HEAD", file_path])
  end

  @spec diff_untracked(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff_untracked(repo_path, file_path) do
    # Use relative path so git produces "diff --git a/path b/path" format
    case System.cmd("git", ["diff", "--no-index", "/dev/null", file_path],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      # exit code 1 means "differences found" which is expected
      {output, 1} -> {:ok, String.trim(output)}
      {output, 0} -> {:ok, String.trim(output)}
      {error, _code} -> {:error, String.trim(error)}
    end
  end

  @spec commit(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def commit(repo_path, message) do
    run(repo_path, ["commit", "-m", message])
  end

  @spec commit_amend(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def commit_amend(repo_path, message) do
    run(repo_path, ["commit", "--amend", "-m", message])
  end

  @spec last_commit_message(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def last_commit_message(repo_path) do
    run(repo_path, ["log", "-1", "--format=%B"])
  end

  @spec open_editor(String.t(), String.t()) :: :ok | {:error, String.t()}
  def open_editor(repo_path, file_path) do
    editor = System.get_env("EDITOR", "vim")
    full_path = Path.join(repo_path, file_path)

    spawn(fn ->
      System.cmd(editor, [full_path], into: IO.stream())
    end)

    :ok
  end

  @spec run(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  defp run(repo_path, args) do
    case System.cmd("git", args, cd: repo_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {error, _code} -> {:error, String.trim(error)}
    end
  end
end

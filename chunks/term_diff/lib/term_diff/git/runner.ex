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

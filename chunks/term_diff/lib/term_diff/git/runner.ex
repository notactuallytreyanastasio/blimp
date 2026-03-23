defmodule TermDiff.Git.Runner do
  @moduledoc "Execute git commands via Erlang Port. Imperative shell."

  @git_timeout 15_000

  @spec status(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def status(repo_path) do
    run(repo_path, ["status", "--porcelain=v1", "-u"])
  end

  @spec plumbing_status(String.t()) :: {:ok, [TermDiff.Diff.FileState.t()]} | {:error, String.t()}
  def plumbing_status(repo_path) do
    with {:ok, staged_raw} <- run(repo_path, ["diff-index", "--cached", "--name-status", "HEAD"]),
         {:ok, unstaged_raw} <- run(repo_path, ["diff-files", "--name-status"]),
         {:ok, untracked_raw} <- run(repo_path, ["ls-files", "--others", "--exclude-standard"]) do
      staged = parse_name_status(staged_raw)
      unstaged = parse_name_status(unstaged_raw)
      untracked = parse_untracked(untracked_raw)

      files = merge_file_states(staged, unstaged, untracked)
      {:ok, files}
    end
  end

  defp parse_name_status(""), do: %{}

  defp parse_name_status(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, "\t", parts: 2) do
        [status, path] -> {path, status_letter(status)}
        _ -> {line, :unknown}
      end
    end)
  end

  defp parse_untracked(""), do: []
  defp parse_untracked(raw), do: String.split(raw, "\n", trim: true)

  defp status_letter("M"), do: :modified
  defp status_letter("A"), do: :added
  defp status_letter("D"), do: :deleted
  defp status_letter("R" <> _), do: :renamed
  defp status_letter(_), do: :modified

  defp merge_file_states(staged, unstaged, untracked) do
    all_paths =
      (Map.keys(staged) ++ Map.keys(unstaged) ++ untracked)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(all_paths, fn path ->
      s = Map.get(staged, path)
      u = Map.get(unstaged, path)
      is_untracked = path in untracked

      status =
        cond do
          is_untracked -> :untracked
          s == :added && u == :modified -> :partial_modified
          s == :added -> :staged_new
          s == :modified && u == :modified -> :partial_modified
          s == :modified -> :staged_modified
          s == :deleted -> :staged_deleted
          s == :renamed && u == :modified -> :partial_modified
          s == :renamed -> :staged_renamed
          u == :modified -> :unstaged_modified
          u == :deleted -> :unstaged_deleted
          true -> :untracked
        end

      %TermDiff.Diff.FileState{path: path, status: status}
    end)
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
    # rev-parse is already plumbing
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

  @spec unstage(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def unstage(repo_path, file_path, opts \\ []) do
    staged_status = Keyword.get(opts, :staged_status)

    if staged_status == :added do
      run(repo_path, ["rm", "--cached", file_path])
    else
      run(repo_path, ["restore", "--staged", file_path])
    end
  end

  @spec exec_file_command(String.t(), TermDiff.Diff.FileState.command()) ::
          {:ok, String.t()} | {:error, String.t()} | :noop
  def exec_file_command(_repo_path, :noop), do: :noop
  def exec_file_command(repo_path, {:add, path}), do: run(repo_path, ["add", path])

  def exec_file_command(repo_path, {:rm_cached, path}),
    do: run(repo_path, ["rm", "--cached", path])

  def exec_file_command(repo_path, {:restore_staged, path}),
    do: run(repo_path, ["restore", "--staged", path])

  @spec diff_untracked(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff_untracked(repo_path, file_path) do
    run(repo_path, ["diff", "--no-index", "/dev/null", file_path], expected_exits: [0, 1])
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

  # ── Port-based execution ──

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  defp run(repo_path, args, opts \\ []) do
    expected_exits = Keyword.get(opts, :expected_exits, [0])
    git = System.find_executable("git")

    port =
      Port.open({:spawn_executable, git}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: repo_path
      ])

    collect_output(port, [], expected_exits)
  rescue
    ErlangError ->
      {:error, "failed to execute git"}
  end

  defp collect_output(port, acc, expected_exits) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | acc], expected_exits)

      {^port, {:exit_status, code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim_trailing()

        if code in expected_exits do
          {:ok, output}
        else
          {:error, output}
        end
    after
      @git_timeout ->
        Port.close(port)
        {:error, "git command timed out"}
    end
  end
end

defmodule TermDiff.Git.PlumbingStatusTest do
  use ExUnit.Case, async: true

  alias TermDiff.Diff.FileState

  describe "Runner.plumbing_status/1 integration" do
    @moduletag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)
      # Need an initial commit for diff-index to work
      File.write!(Path.join(tmp_dir, ".gitkeep"), "")
      System.cmd("git", ["add", ".gitkeep"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init"], cd: tmp_dir)

      %{repo: tmp_dir}
    end

    test "returns empty list for clean repo", %{repo: repo} do
      assert {:ok, []} = TermDiff.Git.Runner.plumbing_status(repo)
    end

    test "detects untracked file", %{repo: repo} do
      File.write!(Path.join(repo, "new.txt"), "hello")

      {:ok, files} = TermDiff.Git.Runner.plumbing_status(repo)
      assert [%FileState{path: "new.txt", status: :untracked}] = files
    end

    test "detects unstaged modified file", %{repo: repo} do
      File.write!(Path.join(repo, "a.txt"), "original")
      System.cmd("git", ["add", "a.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "add a"], cd: repo)
      File.write!(Path.join(repo, "a.txt"), "changed")

      {:ok, files} = TermDiff.Git.Runner.plumbing_status(repo)
      assert [%FileState{path: "a.txt", status: :unstaged_modified}] = files
    end

    test "detects staged modified file", %{repo: repo} do
      File.write!(Path.join(repo, "b.txt"), "original")
      System.cmd("git", ["add", "b.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "add b"], cd: repo)
      File.write!(Path.join(repo, "b.txt"), "changed")
      System.cmd("git", ["add", "b.txt"], cd: repo)

      {:ok, files} = TermDiff.Git.Runner.plumbing_status(repo)
      assert [%FileState{path: "b.txt", status: :staged_modified}] = files
    end

    test "detects partial modified (staged + unstaged)", %{repo: repo} do
      File.write!(Path.join(repo, "c.txt"), "v1")
      System.cmd("git", ["add", "c.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "add c"], cd: repo)
      File.write!(Path.join(repo, "c.txt"), "v2")
      System.cmd("git", ["add", "c.txt"], cd: repo)
      File.write!(Path.join(repo, "c.txt"), "v3")

      {:ok, files} = TermDiff.Git.Runner.plumbing_status(repo)
      assert [%FileState{path: "c.txt", status: :partial_modified}] = files
    end

    test "detects staged new file", %{repo: repo} do
      File.write!(Path.join(repo, "brand_new.txt"), "content")
      System.cmd("git", ["add", "brand_new.txt"], cd: repo)

      {:ok, files} = TermDiff.Git.Runner.plumbing_status(repo)
      assert [%FileState{path: "brand_new.txt", status: :staged_new}] = files
    end

    test "detects staged deleted file", %{repo: repo} do
      File.write!(Path.join(repo, "d.txt"), "content")
      System.cmd("git", ["add", "d.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "add d"], cd: repo)
      File.rm!(Path.join(repo, "d.txt"))
      System.cmd("git", ["add", "d.txt"], cd: repo)

      {:ok, files} = TermDiff.Git.Runner.plumbing_status(repo)
      assert [%FileState{path: "d.txt", status: :staged_deleted}] = files
    end

    test "detects unstaged deleted file", %{repo: repo} do
      File.write!(Path.join(repo, "e.txt"), "content")
      System.cmd("git", ["add", "e.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "add e"], cd: repo)
      File.rm!(Path.join(repo, "e.txt"))

      {:ok, files} = TermDiff.Git.Runner.plumbing_status(repo)
      assert [%FileState{path: "e.txt", status: :unstaged_deleted}] = files
    end

    test "handles multiple files in different states", %{repo: repo} do
      # Tracked modified (unstaged)
      File.write!(Path.join(repo, "tracked.txt"), "v1")
      System.cmd("git", ["add", "tracked.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "add tracked"], cd: repo)
      File.write!(Path.join(repo, "tracked.txt"), "v2")

      # Untracked
      File.write!(Path.join(repo, "untracked.txt"), "new")

      # Staged new
      File.write!(Path.join(repo, "staged_new.txt"), "added")
      System.cmd("git", ["add", "staged_new.txt"], cd: repo)

      {:ok, files} = TermDiff.Git.Runner.plumbing_status(repo)
      paths = Enum.map(files, & &1.path) |> Enum.sort()
      assert paths == ["staged_new.txt", "tracked.txt", "untracked.txt"]

      by_path = Map.new(files, &{&1.path, &1.status})
      assert by_path["tracked.txt"] == :unstaged_modified
      assert by_path["untracked.txt"] == :untracked
      assert by_path["staged_new.txt"] == :staged_new
    end
  end
end

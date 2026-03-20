defmodule TermDiff.Git.RunnerTest do
  use ExUnit.Case, async: true

  alias TermDiff.Git.Runner

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    System.cmd("git", ["init"], cd: tmp_dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

    %{repo: tmp_dir}
  end

  describe "status/1" do
    test "returns empty for clean repo", %{repo: repo} do
      # Need at least one commit for status to work
      File.write!(Path.join(repo, "init.txt"), "init")
      System.cmd("git", ["add", "init.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "init"], cd: repo)

      assert {:ok, ""} = Runner.status(repo)
    end

    test "shows modified files", %{repo: repo} do
      path = Path.join(repo, "foo.txt")
      File.write!(path, "hello")
      System.cmd("git", ["add", "foo.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "add foo"], cd: repo)
      File.write!(path, "changed")

      {:ok, output} = Runner.status(repo)
      assert output =~ "foo.txt"
    end
  end

  describe "stage/2 and unstage/2" do
    test "stages a file", %{repo: repo} do
      File.write!(Path.join(repo, "a.txt"), "content")

      assert {:ok, _} = Runner.stage(repo, "a.txt")

      {:ok, status} = Runner.status(repo)
      assert status =~ "A  a.txt"
    end

    test "unstages a file", %{repo: repo} do
      File.write!(Path.join(repo, "init.txt"), "init")
      System.cmd("git", ["add", "init.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "init"], cd: repo)

      File.write!(Path.join(repo, "b.txt"), "content")
      System.cmd("git", ["add", "b.txt"], cd: repo)

      assert {:ok, _} = Runner.unstage(repo, "b.txt")

      {:ok, status} = Runner.status(repo)
      assert status =~ "?? b.txt"
    end

    test "unstages a newly added file in a fresh repo with no commits", %{repo: repo} do
      File.write!(Path.join(repo, "NEW.md"), "brand new")
      System.cmd("git", ["add", "NEW.md"], cd: repo)

      {:ok, status_before} = Runner.status(repo)
      assert status_before =~ "A  NEW.md"

      assert {:ok, _} = Runner.unstage(repo, "NEW.md", staged_status: :added)

      {:ok, status_after} = Runner.status(repo)
      assert status_after =~ "?? NEW.md"
    end

    test "unstages a newly added file in a repo with existing commits", %{repo: repo} do
      File.write!(Path.join(repo, "init.txt"), "init")
      System.cmd("git", ["add", "init.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "init"], cd: repo)

      File.write!(Path.join(repo, "MAGIT.md"), "new file content")
      System.cmd("git", ["add", "MAGIT.md"], cd: repo)

      {:ok, status_before} = Runner.status(repo)
      assert status_before =~ "A  MAGIT.md"

      assert {:ok, _} = Runner.unstage(repo, "MAGIT.md", staged_status: :added)

      {:ok, status_after} = Runner.status(repo)
      assert status_after =~ "?? MAGIT.md"
    end

    test "unstages a modified file with restore --staged", %{repo: repo} do
      File.write!(Path.join(repo, "init.txt"), "init")
      System.cmd("git", ["add", "init.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "init"], cd: repo)

      File.write!(Path.join(repo, "init.txt"), "changed")
      System.cmd("git", ["add", "init.txt"], cd: repo)

      assert {:ok, _} = Runner.unstage(repo, "init.txt", staged_status: :modified)

      {:ok, status_after} = Runner.status(repo)
      assert status_after =~ "M init.txt"
    end
  end

  describe "commit/2" do
    test "creates a commit", %{repo: repo} do
      File.write!(Path.join(repo, "c.txt"), "data")
      System.cmd("git", ["add", "c.txt"], cd: repo)

      assert {:ok, output} = Runner.commit(repo, "test commit")
      assert output =~ "test commit"
    end
  end

  describe "diff/1" do
    test "returns diff of unstaged changes", %{repo: repo} do
      File.write!(Path.join(repo, "d.txt"), "original")
      System.cmd("git", ["add", "d.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "init"], cd: repo)
      File.write!(Path.join(repo, "d.txt"), "modified")

      {:ok, diff} = Runner.diff(repo)
      assert diff =~ "d.txt"
      assert diff =~ "+modified"
    end
  end

  describe "branch/1" do
    test "returns current branch name", %{repo: repo} do
      File.write!(Path.join(repo, "init.txt"), "init")
      System.cmd("git", ["add", "init.txt"], cd: repo)
      System.cmd("git", ["commit", "-m", "init"], cd: repo)

      {:ok, branch} = Runner.branch(repo)
      assert branch in ["main", "master"]
    end
  end

  describe "error handling" do
    test "returns error for invalid repo path" do
      assert {:error, _} = Runner.status("/nonexistent/path/here")
    end
  end
end

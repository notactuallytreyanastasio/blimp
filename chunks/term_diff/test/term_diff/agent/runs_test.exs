defmodule TermDiff.Agent.RunsTest do
  use TermDiff.DataCase, async: true

  alias TermDiff.Agent.Run
  alias TermDiff.Agent.Runs

  @valid_attrs %{
    status: "pending",
    agent_type: "claude_code",
    prompt: "Fix the bug"
  }

  defp create_run(attrs \\ %{}) do
    {:ok, run} = Runs.create_run(Map.merge(@valid_attrs, attrs))
    run
  end

  describe "create_run/1" do
    test "creates a run with valid attrs" do
      assert {:ok, %Run{} = run} = Runs.create_run(@valid_attrs)
      assert run.status == "pending"
      assert run.agent_type == "claude_code"
      assert run.prompt == "Fix the bug"
    end

    test "returns error changeset with invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = Runs.create_run(%{})
    end

    test "broadcasts :run_created on success" do
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "runs")
      {:ok, run} = Runs.create_run(@valid_attrs)
      assert_receive {:run_created, ^run}
    end
  end

  describe "get_run!/1 and get_run/1" do
    test "get_run! returns the run" do
      run = create_run()
      assert Runs.get_run!(run.id).id == run.id
    end

    test "get_run! raises for missing id" do
      assert_raise Ecto.NoResultsError, fn -> Runs.get_run!(0) end
    end

    test "get_run returns nil for missing id" do
      assert Runs.get_run(0) == nil
    end
  end

  describe "update_run/2" do
    test "updates with valid attrs" do
      run = create_run()
      assert {:ok, updated} = Runs.update_run(run, %{status: "running"})
      assert updated.status == "running"
    end

    test "rejects invalid status" do
      run = create_run()
      assert {:error, changeset} = Runs.update_run(run, %{status: "invalid"})
      assert %{status: [_]} = errors_on(changeset)
    end

    test "broadcasts :run_updated on success" do
      run = create_run()
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "runs")
      {:ok, updated} = Runs.update_run(run, %{status: "running"})
      assert_receive {:run_updated, ^updated}
    end
  end

  describe "list_runs/1" do
    test "returns non-archived runs ordered by inserted_at desc" do
      r1 = create_run(%{prompt: "first"})
      r2 = create_run(%{prompt: "second"})

      runs = Runs.list_runs()
      ids = Enum.map(runs, & &1.id)
      assert r2.id in ids
      assert r1.id in ids
      # Most recent first
      assert hd(ids) == r2.id
    end

    test "excludes archived runs" do
      run = create_run()
      {:ok, _} = Runs.archive_run(run)

      runs = Runs.list_runs()
      refute Enum.any?(runs, &(&1.id == run.id))
    end

    test "filters by repo_path" do
      create_run(%{repo_path: "/repo/a"})
      create_run(%{repo_path: "/repo/b"})

      runs = Runs.list_runs(repo_path: "/repo/a")
      assert length(runs) == 1
      assert hd(runs).repo_path == "/repo/a"
    end
  end

  describe "archive_run/1" do
    test "sets archived_at" do
      run = create_run()
      assert {:ok, archived} = Runs.archive_run(run)
      assert archived.archived_at
    end

    test "broadcasts :run_archived" do
      run = create_run()
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "runs")
      {:ok, archived} = Runs.archive_run(run)
      assert_receive {:run_archived, ^archived}
    end
  end

  describe "archive_stale_runs/1" do
    test "archives old completed runs" do
      run = create_run(%{status: "succeeded"})

      # Manually backdate updated_at
      Repo.update_all(
        from(r in Run, where: r.id == ^run.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(), -48 * 3600)]
      )

      {count, nil} = Runs.archive_stale_runs(24)
      assert count == 1

      archived = Runs.get_run!(run.id)
      assert archived.archived_at
    end

    test "does not archive running or pending runs" do
      run = create_run(%{status: "running"})

      Repo.update_all(
        from(r in Run, where: r.id == ^run.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(), -48 * 3600)]
      )

      {count, nil} = Runs.archive_stale_runs(24)
      assert count == 0
    end
  end

  describe "get_run_chain/1" do
    test "single run returns list of one" do
      run = create_run()
      assert [%Run{id: id}] = Runs.get_run_chain(run)
      assert id == run.id
    end

    test "follows parent chain" do
      parent = create_run(%{prompt: "parent"})

      child =
        create_run(%{prompt: "child", parent_run_id: parent.id})

      chain = Runs.get_run_chain(child)
      assert length(chain) == 2
      assert hd(chain).id == parent.id
      assert List.last(chain).id == child.id
    end
  end

  describe "change_run/2" do
    test "returns a changeset" do
      run = create_run()
      assert %Ecto.Changeset{} = Runs.change_run(run)
    end
  end
end

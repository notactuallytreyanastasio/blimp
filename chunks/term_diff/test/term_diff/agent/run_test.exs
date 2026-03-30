defmodule TermDiff.Agent.RunTest do
  use TermDiff.DataCase, async: true

  alias TermDiff.Agent.Run

  @valid_attrs %{
    status: "pending",
    agent_type: "claude_code",
    prompt: "Fix the bug in auth module"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Run.changeset(%Run{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid with nil status" do
      changeset = Run.changeset(%Run{}, Map.put(@valid_attrs, :status, nil))
      refute changeset.valid?
      assert %{status: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without agent_type" do
      changeset = Run.changeset(%Run{}, Map.delete(@valid_attrs, :agent_type))
      refute changeset.valid?
      assert %{agent_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without prompt" do
      changeset = Run.changeset(%Run{}, Map.delete(@valid_attrs, :prompt))
      refute changeset.valid?
      assert %{prompt: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates status inclusion" do
      for status <- ~w(pending running succeeded failed cancelled) do
        changeset = Run.changeset(%Run{}, %{@valid_attrs | status: status})
        assert changeset.valid?, "Expected #{status} to be valid"
      end

      changeset = Run.changeset(%Run{}, %{@valid_attrs | status: "bogus"})
      refute changeset.valid?
      assert %{status: [_]} = errors_on(changeset)
    end

    test "validates turn_number greater than 0" do
      changeset = Run.changeset(%Run{}, Map.put(@valid_attrs, :turn_number, 0))
      refute changeset.valid?
      assert %{turn_number: [_]} = errors_on(changeset)

      changeset = Run.changeset(%Run{}, Map.put(@valid_attrs, :turn_number, -1))
      refute changeset.valid?
    end

    test "validates max_turns greater than 0" do
      changeset = Run.changeset(%Run{}, Map.put(@valid_attrs, :max_turns, 0))
      refute changeset.valid?
      assert %{max_turns: [_]} = errors_on(changeset)
    end

    test "accepts all optional fields" do
      now = DateTime.utc_now()

      attrs =
        Map.merge(@valid_attrs, %{
          title: "My run",
          workspace_path: "/tmp/workspace",
          repo_path: "/tmp/repo",
          model: "claude-4",
          session_id: "sess-123",
          parent_run_id: 42,
          permission_mode: "auto",
          turn_number: 3,
          max_turns: 10,
          input_tokens: 100,
          output_tokens: 200,
          total_tokens: 300,
          exit_code: 0,
          error: nil,
          started_at: now,
          finished_at: now,
          archived_at: now,
          deciduous_root: 7
        })

      changeset = Run.changeset(%Run{}, attrs)
      assert changeset.valid?
    end

    test "defaults for numeric fields" do
      _changeset = Run.changeset(%Run{}, @valid_attrs)
      # Defaults come from the schema, check them on a struct
      run = %Run{}
      assert run.turn_number == 1
      assert run.input_tokens == 0
      assert run.output_tokens == 0
      assert run.total_tokens == 0
      assert run.status == "pending"
    end

    test "persists to database" do
      {:ok, run} =
        %Run{}
        |> Run.changeset(@valid_attrs)
        |> Repo.insert()

      assert run.id
      assert run.inserted_at
      assert run.updated_at
      assert run.status == "pending"
    end
  end
end

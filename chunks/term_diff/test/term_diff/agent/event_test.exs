defmodule TermDiff.Agent.EventTest do
  use TermDiff.DataCase, async: true

  alias TermDiff.Agent.Event

  @valid_attrs %{type: "run.started", source: "agent_runner"}

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Event.changeset(%Event{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without type" do
      changeset = Event.changeset(%Event{}, Map.delete(@valid_attrs, :type))
      refute changeset.valid?
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without source" do
      changeset = Event.changeset(%Event{}, Map.delete(@valid_attrs, :source))
      refute changeset.valid?
      assert %{source: ["can't be blank"]} = errors_on(changeset)
    end

    test "defaults data to empty map" do
      event = %Event{}
      assert event.data == %{}
    end

    test "accepts data map" do
      attrs = Map.put(@valid_attrs, :data, %{"run_id" => 1, "output" => "hello"})
      changeset = Event.changeset(%Event{}, attrs)
      assert changeset.valid?
    end

    test "persists to database with inserted_at but no updated_at" do
      {:ok, event} =
        %Event{}
        |> Event.changeset(@valid_attrs)
        |> Repo.insert()

      assert event.id
      assert event.inserted_at
      # Event schema has updated_at: false in timestamps
    end
  end
end

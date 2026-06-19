defmodule TermDiff.Agent.EventsTest do
  use TermDiff.DataCase, async: true

  alias TermDiff.Agent.Event
  alias TermDiff.Agent.Events

  @valid_attrs %{type: "run.started", source: "agent_runner", data: %{"run_id" => 1}}

  describe "emit/1" do
    test "persists event to database" do
      assert {:ok, %Event{} = event} = Events.emit(@valid_attrs)
      assert event.id
      assert event.type == "run.started"
      assert event.source == "agent_runner"
      assert event.data == %{"run_id" => 1}
    end

    test "returns error for invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = Events.emit(%{})
    end

    test "broadcasts to events topic" do
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "events")
      {:ok, event} = Events.emit(@valid_attrs)
      assert_receive {:event, ^event}
    end

    test "broadcasts to typed topic" do
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "events:run.started")
      {:ok, event} = Events.emit(@valid_attrs)
      assert_receive {:event, ^event}
    end

    test "does not broadcast on failure" do
      Phoenix.PubSub.subscribe(TermDiff.PubSub, "events")
      {:error, _} = Events.emit(%{})
      refute_receive {:event, _}
    end
  end

  describe "list_events/1" do
    test "returns events ordered by inserted_at asc" do
      {:ok, e1} = Events.emit(%{type: "run.started", source: "s1"})
      {:ok, e2} = Events.emit(%{type: "run.finished", source: "s1"})

      events = Events.list_events()
      ids = Enum.map(events, & &1.id)
      assert hd(ids) == e1.id
      assert List.last(ids) == e2.id
    end

    test "filters by type" do
      {:ok, _} = Events.emit(%{type: "run.started", source: "s1"})
      {:ok, _} = Events.emit(%{type: "run.finished", source: "s1"})

      events = Events.list_events(type: "run.started")
      assert length(events) == 1
      assert hd(events).type == "run.started"
    end

    test "filters by source" do
      {:ok, _} = Events.emit(%{type: "run.started", source: "s1"})
      {:ok, _} = Events.emit(%{type: "run.started", source: "s2"})

      events = Events.list_events(source: "s1")
      assert length(events) == 1
    end

    test "filters by since" do
      {:ok, old} = Events.emit(%{type: "run.started", source: "s1"})
      # Use the old event's timestamp as the cutoff
      events = Events.list_events(since: old.inserted_at)
      # since is strictly greater than, so old event excluded
      refute Enum.any?(events, &(&1.id == old.id))
    end

    test "filters by run_id in data" do
      {:ok, _} = Events.emit(%{type: "run.started", source: "s1", data: %{"run_id" => 99}})
      {:ok, _} = Events.emit(%{type: "run.started", source: "s1", data: %{"run_id" => 100}})

      events = Events.list_events(run_id: 99)
      assert length(events) == 1
      assert hd(events).data["run_id"] == 99
    end

    test "respects limit" do
      for i <- 1..5 do
        Events.emit(%{type: "run.output", source: "s1", data: %{"i" => i}})
      end

      events = Events.list_events(limit: 2)
      assert length(events) == 2
    end
  end
end

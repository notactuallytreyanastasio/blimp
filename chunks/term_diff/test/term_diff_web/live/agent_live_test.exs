defmodule TermDiffWeb.AgentLiveTest do
  use TermDiffWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TermDiff.Agent.Runs

  # ── AgentLive mount and rendering ──

  describe "AgentLive mount" do
    test "renders agent dashboard with new agent form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Start a new agent"
      assert html =~ "New Agent"
    end

    test "has navigation links to diffs and agents", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Diffs"
      assert html =~ "Agents"
    end

    test "shows empty state when no panes open", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Click a run in the sidebar"
    end

    test "shows run history in sidebar", %{conn: conn} do
      {:ok, _run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "test prompt for history",
          status: "succeeded"
        })

      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Runs"
      assert html =~ "test prompt for history"
    end
  end

  # ── Sidebar pane toggling ──

  describe "toggle_pane" do
    test "clicking a run in sidebar opens it as a pane", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "open me in a pane",
          status: "succeeded"
        })

      {:ok, view, _html} = live(conn, "/agents")

      view
      |> element("[phx-click=\"toggle_pane\"][phx-value-id=\"#{run.id}\"]")
      |> render_click()

      html = render(view)
      assert html =~ "pane-output-#{run.id}"
      assert html =~ "open me in a pane"
    end

    test "clicking an open run closes its pane", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "toggle me",
          status: "succeeded"
        })

      {:ok, view, _html} = live(conn, "/agents")

      # Open
      view
      |> element("[phx-click=\"toggle_pane\"][phx-value-id=\"#{run.id}\"]")
      |> render_click()

      assert render(view) =~ "pane-output-#{run.id}"

      # Close
      view
      |> element("[phx-click=\"toggle_pane\"][phx-value-id=\"#{run.id}\"]")
      |> render_click()

      refute render(view) =~ "pane-output-#{run.id}"
    end
  end

  # ── New agent creation ──

  describe "new agent" do
    test "new agent button creates a run and shows it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      # Simulate run creation + broadcast
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "hello from new agent",
          status: "running"
        })

      send(view.pid, {:run_created, run})

      html = render(view)
      assert html =~ "hello from new agent"
    end
  end

  # ── Streaming events ──

  describe "streaming events" do
    test "agent_event appends to pane output", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "streaming test",
          status: "running"
        })

      {:ok, view, _html} = live(conn, "/agents")

      send(view.pid, {:run_created, run})

      send(
        view.pid,
        {:agent_event, run.id,
         %{"type" => "assistant", "message" => %{"content" => "hello from agent"}}}
      )

      html = render(view)
      assert html =~ "hello from agent"
    end

    test "run_updated keeps finished run visible with updated status", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "update test",
          status: "running"
        })

      {:ok, view, _html} = live(conn, "/agents")

      send(view.pid, {:run_created, run})

      updated_run = %{run | status: "succeeded"}
      send(view.pid, {:run_updated, updated_run})

      html = render(view)
      assert html =~ "update test"
      assert html =~ "succeeded"
    end
  end

  # ── AgentRunLive (detail page) ──

  describe "AgentRunLive" do
    test "renders run detail page", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "detail test prompt",
          status: "succeeded"
        })

      {:ok, _view, html} = live(conn, "/agents/#{run.id}")

      assert html =~ "detail test prompt"
    end

    test "shows run metadata", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "metadata test",
          status: "succeeded",
          model: "claude-sonnet-4-5"
        })

      {:ok, _view, html} = live(conn, "/agents/#{run.id}")

      assert html =~ "claude-code"
      assert html =~ "succeeded"
    end

    test "has back link to agent list", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "back link test",
          status: "succeeded"
        })

      {:ok, _view, html} = live(conn, "/agents/#{run.id}")

      assert html =~ "Agents"
    end
  end
end

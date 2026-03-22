defmodule TermDiffWeb.AgentLiveTest do
  use TermDiffWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TermDiff.Agent.Runs

  # ── Mount and URL params ──

  describe "mount with no params" do
    test "renders empty agent dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Runs"
      assert html =~ "Click a run in the sidebar"
    end
  end

  describe "mount with panes param" do
    test "opens specified runs as panes", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "pane test",
          status: "succeeded"
        })

      {:ok, _view, html} = live(conn, "/agents?panes=#{run.id}")

      assert html =~ "pane-output-#{run.id}"
      assert html =~ "pane test"
    end

    test "opens multiple panes", %{conn: conn} do
      {:ok, run1} = Runs.create_run(%{agent_type: "claude-code", prompt: "first", status: "succeeded"})
      {:ok, run2} = Runs.create_run(%{agent_type: "claude-code", prompt: "second", status: "succeeded"})

      {:ok, _view, html} = live(conn, "/agents?panes=#{run1.id},#{run2.id}")

      assert html =~ "pane-output-#{run1.id}"
      assert html =~ "pane-output-#{run2.id}"
    end

    test "ignores invalid pane IDs gracefully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents?panes=999999")

      assert html =~ "Click a run in the sidebar"
    end
  end

  describe "mount with dark param" do
    test "activates dark mode", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents?dark=1")

      assert html =~ "bg-neutral-900"
    end
  end

  # ── Sidebar pane toggling via URL ──

  describe "toggle_pane updates URL" do
    test "clicking a run patches URL with pane ID", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "toggle url test",
          status: "succeeded"
        })

      {:ok, view, _html} = live(conn, "/agents")

      view
      |> element("[phx-click=\"toggle_pane\"][phx-value-id=\"#{run.id}\"]")
      |> render_click()

      assert_patch(view, "/agents?panes=#{run.id}")
    end

    test "clicking again removes pane from URL", %{conn: conn} do
      {:ok, run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "close url test",
          status: "succeeded"
        })

      {:ok, view, _html} = live(conn, "/agents?panes=#{run.id}")

      view
      |> element("[phx-click=\"toggle_pane\"][phx-value-id=\"#{run.id}\"]")
      |> render_click()

      assert_patch(view, "/agents")
    end
  end

  describe "dark mode toggle updates URL" do
    test "toggling dark mode patches URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      view |> element("button", "Dark") |> render_click()

      assert_patch(view, "/agents?dark=1")
    end
  end

  # ── New agent creation ──

  describe "new agent" do
    test "creating agent adds it to URL panes", %{conn: conn} do
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

      {:ok, view, _html} = live(conn, "/agents?panes=#{run.id}")

      send(
        view.pid,
        {:agent_event, run.id,
         %{"type" => "assistant", "message" => %{"content" => "hello from agent"}}}
      )

      html = render(view)
      assert html =~ "hello from agent"
    end
  end

  # ── Run history sidebar ──

  describe "sidebar" do
    test "shows run history", %{conn: conn} do
      {:ok, _run} =
        Runs.create_run(%{
          agent_type: "claude-code",
          prompt: "sidebar history test",
          status: "succeeded"
        })

      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "sidebar history test"
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
  end
end

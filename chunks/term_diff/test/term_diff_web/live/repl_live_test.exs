defmodule TermDiffWeb.ReplLiveTest do
  use TermDiffWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders REPL interface", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/repl")

      assert html =~ "blimp&gt;"
      assert html =~ "State"
    end
  end

  describe "eval with empty input" do
    test "ignores empty input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/repl")

      html = render_submit(view, "eval", %{"input" => ""})

      # No crash, still showing REPL
      assert html =~ "blimp&gt;"
    end
  end

  describe "accessibility" do
    test "eval button has aria-label", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/repl")

      assert html =~ ~s(aria-label="Evaluate expression")
    end

    test "input has aria-label", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/repl")

      assert html =~ ~s(aria-label="REPL input")
    end
  end
end

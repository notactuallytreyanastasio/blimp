defmodule TermDiffWeb.PageControllerTest do
  use TermDiffWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "term-diff"
  end
end

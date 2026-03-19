defmodule TermDiffWeb.PageController do
  use TermDiffWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

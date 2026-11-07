defmodule HarnessForgeWeb.PageController do
  use HarnessForgeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

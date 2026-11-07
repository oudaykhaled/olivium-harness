defmodule HarnessForgeWeb.Router do
  use HarnessForgeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HarnessForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :private_response
  end

  pipeline :authenticated do
    plug HarnessForgeWeb.Plugs.OperatorSession
  end

  pipeline :download do
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :private_response
  end

  scope "/", HarnessForgeWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/session", SessionController, :delete
  end

  scope "/", HarnessForgeWeb do
    pipe_through [:browser, :authenticated]

    get "/verification", VerificationController, :index
    get "/verification/report", VerificationController, :report

    live_session :operator, on_mount: [{HarnessForgeWeb.Plugs.OperatorSession, :operator}] do
      live "/", PortalLive, :index
      live "/setup", SetupLive, :index
      live "/setup/:id/:step", SetupLive, :show
      live "/company/corpus", CorpusReviewLive, :index
      live "/harnesses/:digest", HarnessLive, :show
    end
  end

  scope "/", HarnessForgeWeb do
    pipe_through [:download, :authenticated]
    get "/harnesses/:digest/download", HarnessDownloadController, :download
  end

  defp private_response(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "same-origin")
  end
end

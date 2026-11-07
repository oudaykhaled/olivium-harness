defmodule HarnessForgeWeb.HarnessDownloadController do
  use HarnessForgeWeb, :controller
  alias HarnessForgeWeb.HarnessDelivery
  alias HarnessForgeWeb.Plugs.OperatorSession

  def download(conn, %{"digest" => digest}) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

    with true <- OperatorSession.valid?(get_session(conn, "operator_auth")),
         {:ok, result} <- HarnessDelivery.download(digest),
         true <- OperatorSession.valid?(get_session(conn, "operator_auth")) do
      send_download(conn, {:binary, result["bytes"]},
        filename: result["filename"],
        content_type: "application/zip"
      )
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:not_found, "Harness unavailable.")
    end
  end
end

defmodule HarnessForgeWeb.VerificationController do
  use HarnessForgeWeb, :controller

  @report %{
    "version" => "HarnessForge.WebVerification.v1",
    "recorded_release" => "WEB16",
    "scope" => "Public synthetic company; recorded browser observations, not a live health check",
    "recorded_on" => "2026-11-04",
    "browser_checks" => [
      "Normal workspace login",
      "Choose saved company context and goal",
      "Retrieve four selected evidence passages for an emergency review question",
      "Open the exact UTF-8 policy passage, including Café, and close with the keyboard"
    ],
    "side_effects" =>
      "One retrieval run and four items; no new model call, permission, approval or export",
    "source_snapshot_sha256" =>
      "b9ff73e841f001bf53ca6ae034a7f112151393f28f11e6e90d920e2187c13d17",
    "evidence_records" => ["web16-verification01.json", "root-web16-qa-consumption01.json"],
    "screenshots" => %{"available" => false, "reason" => "Authenticated pixels are restricted"},
    "harness_generation" =>
      "Earlier synthetic journey generated eight files using a scripted provider",
    "task_evaluation" =>
      "No representative isolated editing task has completed; runtime prerequisites are blocked",
    "real_model_result" => "Two later public-synthetic model attempts remain uncertain",
    "not_established" => [
      "Real company usefulness",
      "Real model quality",
      "Representative task benefit",
      "Physical scale",
      "Comprehensive accessibility"
    ]
  }

  def index(conn, _params),
    do: render(conn, :index, report: @report, page_title: "Checks and evidence")

  def report(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="harnessforge-web-evidence.json")
    )
    |> send_resp(200, Jason.encode!(@report, pretty: true))
  end
end

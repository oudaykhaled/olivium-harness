defmodule HarnessForgeWeb.VerificationController do
  use HarnessForgeWeb, :controller
  alias HarnessForge.Contracts

  @recordings_file Path.expand("../../../priv/showcase/recordings.json", __DIR__)
  @external_resource @recordings_file
  @recordings @recordings_file |> File.read!() |> Jason.decode!()
  @report %{
    "version" => "HarnessForge.WebVerification.v5",
    "recorded_release" => "WEB20 / WEB21 / WEB22 / WEB23 / WEB25",
    "scope" => "Recorded synthetic company checks; not a live health check",
    "recorded_on" => "2026-11-04",
    "browser_checks" => [
      "Open the actual eight-file harness and download its ZIP",
      "Verify every downloaded payload against the generated artifact",
      "Keep the exact harness selected across task-page reload",
      "Deny stale files and open the current source review",
      "Issue and revoke assistant source access",
      "Capture public GitHub records and complete an unchanged resync",
      "Reject invalid model guidance without admitting a claim",
      "Review real model guidance, separately approve its claim and Company plan, then build and download",
      "Recapture a changed file, deny stale delivery and build a separately reviewed successor"
    ],
    "recordings" => @recordings,
    "screenshots" => %{"available" => false, "reason" => "Authenticated pixels are restricted"},
    "harness_generation" =>
      "A real Qwen2.5:7b-instruct-q4_K_M proposal was reviewed and corrected, then separately approved as a claim and Company plan to generate eight files",
    "generation_route" => "Normal Company UI build and browser ZIP download verified",
    "harness_digest" => "4025ce80fa4c24ae70aed92061f4efb455d38cdc99b2f4ddde58108175edcc3e",
    "download_payloads_verified" => 8,
    "task_evaluation" =>
      "Earlier Task04: Clamp passed, ReverseWords failed; Company Task05: generated code rejected by protected code checks",
    "benefit" => "Not demonstrated",
    "paired_comparison" => "Both failed · one public-PR diagnostic pair",
    "paired_results" => %{
      "baseline_run" => "967624e9-e319-4c69-bbb5-08e61776673f",
      "candidate_run" => "a9f761ef-d741-4e39-b60a-cbb8f283c26d",
      "baseline_outcome" => "failed",
      "candidate_outcome" => "failed",
      "comparable" => true,
      "qualified" => false,
      "sample_count" => 1,
      "qualification" => "current_knowledge_diagnostic_replay",
      "limit" =>
        "Same runtime, model, task and limits; only approved guidance differs. Historical cutoff unverified; no general productivity claim."
    },
    "connector_contracts" => %{
      "passed" => 148,
      "failed" => 0,
      "qualification" => "Synthetic HTTP contract tests; not live account verification"
    },
    "mcp_sdk_checks" => 14,
    "mcp_positive_metadata_checks" => 7,
    "source_recovery" => %{
      "recorded_release" => "WEB25",
      "scope" => "Manual synthetic agent QA; no model generation",
      "stale_delivery" => "denied",
      "successor_payloads_verified" => 8,
      "model_requests" => 0
    },
    "github_live" => %{
      "records" => 21,
      "pull_requests" => 12,
      "issues" => 6,
      "reviews" => 2,
      "repositories" => 1,
      "unchanged_resync" => true
    },
    "historical_grader_controls" => 8,
    "evidence_records" => [
      "web20-video-files01.json",
      "web21-task-context01.json",
      "real-harness-browser01.json",
      "real-harness-files01.json",
      "environment/verification-final.json",
      "connectors/results/contracts-03/receipt.json",
      "connectors/sdk/results/actual-sdk-01/receipt.json",
      "github-live-result01.json",
      "environment/task02-diagnosis/diagnosis.json",
      "environment/company-analysis01/diagnosis.json",
      "company-model-plan-build01-browser.json",
      "environment/company-model-plan-build01/verification.json",
      "environment/company-model-plan-build01/zip-verification.json",
      "task04-browser01.json",
      "environment/task04-diagnosis/diagnosis.json",
      "task05-browser01.json",
      "environment/task05-diagnosis/diagnosis.json",
      "verification-recordings-update01.json",
      "source-recovery-v2-browser01.json",
      "environment/source-recovery01/verification01.json",
      "connectors/sdk/results/actual-metadata-03-after-recovery/receipt.json",
      "historical-pilot/evidence/controls01/summary.json",
      "historical-pilot/paired-prep/receipts/pair01-comparison.json"
    ],
    "not_established" => [
      "Real company usefulness",
      "Historical task benefit",
      "All live connectors",
      "Real Graphiti/Jev synthesis",
      "Large-company scale"
    ]
  }

  def index(conn, _params) do
    recordings = Enum.map(recordings(), &Map.put(&1, "available", present?(&1)))

    render(conn, :index,
      report: Map.put(@report, "recordings", recordings),
      page_title: "Checks and evidence"
    )
  end

  def report(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="harnessforge-web-evidence.json")
    )
    |> send_resp(200, Jason.encode!(@report, pretty: true))
  end

  def media(conn, %{"id" => id}) do
    with %{} = entry <- Enum.find(recordings(), &(&1["id"] == id)),
         {:ok, bytes} <- File.read(media_path(entry)),
         true <- byte_size(bytes) == entry["bytes"] and Contracts.sha256(bytes) == entry["sha256"] do
      conn
      |> put_resp_content_type("video/webm")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "Recording unavailable")
    end
  end

  # The .webm files are distributed separately, so a public checkout has none.
  # File names come only from manifest ids, never from the request path.
  defp recordings, do: Application.get_env(:harness_forge, :verification_recordings, @recordings)

  defp media_path(entry) do
    dir =
      Application.get_env(:harness_forge, :verification_media_dir) ||
        Application.app_dir(:harness_forge, "priv/showcase")

    Path.join(dir, entry["id"] <> ".webm")
  end

  # Size only: hashing every recording on each page view would read about 100 MB.
  # Serving still checks the digest.
  defp present?(%{"bytes" => bytes} = entry) do
    match?({:ok, %File.Stat{type: :regular, size: ^bytes}}, File.stat(media_path(entry)))
  end
end

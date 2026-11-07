defmodule HarnessForgeWeb.VerificationHTML do
  use HarnessForgeWeb, :html

  def index(assigns) do
    ~H"""
    <main
      id="verification-page"
      class="content stack company-builder"
      style="max-width: 64rem; margin: 0 auto;"
    >
      <.link href="/" class="button secondary" id="verification-home">Return to Home</.link>
      <header>
        <p class="eyebrow">CHECKS AND EVIDENCE</p>
        <h1>What has actually been checked?</h1>
        <p>
          Recorded review: {@report["recorded_release"]} · {@report["recorded_on"]}. Public synthetic company data.
        </p>
        <p>These results describe that review build. They do not certify your company's harness.</p>
      </header>
      <section class="panel" aria-labelledby="verification-browser-title">
        <h2 id="verification-browser-title">Evidence search — browser verified</h2>
        <ol id="verification-browser-checks">
          <li :for={check <- @report["browser_checks"]}>{check}</li>
        </ol>
        <p>{@report["side_effects"]}.</p>
      </section>
      <section class="panel" aria-labelledby="verification-images-title">
        <h2 id="verification-images-title">Screenshots — unavailable</h2>
        <p id="verification-images-status">
          No current screenshots or videos are saved. Authenticated pixels are restricted.
        </p>
        <p>
          Available proof contains browser observations, page geometry, downloaded files and independent file/database checks.
        </p>
      </section>
      <section class="panel" aria-labelledby="verification-harness-title">
        <h2 id="verification-harness-title">
          Harness generation — demonstrated with a scripted provider
        </h2>
        <p>
          {@report["harness_generation"]}. The operator approved the exact claim and separately approved the plan.
        </p>
        <p>
          Recorded file checks passed. ZIP timestamps varied; identical ZIP container bytes are not established.
        </p>
        <h3>Useful task execution — not demonstrated</h3>
        <p>{@report["task_evaluation"]}.</p>
        <p>
          {@report["real_model_result"]}. A successful real-company result has not been established.
        </p>
      </section>
      <details class="panel" id="verification-details">
        <summary>Evidence identity and remaining checks</summary>
        <p>Source snapshot: <code>{@report["source_snapshot_sha256"]}</code></p>
        <ul>
          <li :for={name <- @report["evidence_records"]}><code>{name}</code></li>
        </ul>
        <p>Not yet established: {Enum.join(@report["not_established"], ", ")}.</p>
      </details>
      <.link href="/verification/report" class="button secondary" id="verification-download">Download evidence summary</.link>
    </main>
    """
  end
end

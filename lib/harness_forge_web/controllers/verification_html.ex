defmodule HarnessForgeWeb.VerificationHTML do
  use HarnessForgeWeb, :html

  attr :video, :map, required: true

  defp recording(assigns) do
    ~H"""
    <video
      :if={@video["available"]}
      controls
      preload="none"
      style="width:100%;max-height:34rem;background:#111;"
      aria-label={@video["title"]}
    >
      <source src={"/verification/media/#{@video["id"]}"} type="video/webm" />
      <a href={"/verification/media/#{@video["id"]}"}>Open recording</a>
    </video>
    <p :if={!@video["available"]} id={"verification-unavailable-" <> @video["id"]}>
      Recording unavailable in this installation. Recordings are distributed separately.
    </p>
    """
  end

  def index(assigns) do
    ~H"""
    <main
      id="verification-page"
      class="content stack company-builder"
      style="max-width:64rem;margin:0 auto;"
    >
      <.link href="/" class="button secondary" id="verification-home">Home</.link>
      <header>
        <p class="eyebrow">RECORDED EVIDENCE · {@report["recorded_on"]}</p>
        <h1>See the actual runs</h1>
        <p>Synthetic harness + public GitHub · {@report["recorded_release"]}</p>
      </header>
      <div class="hf-outcome-stages" id="verification-statuses">
        <span>✓ Real model</span><span>✓ 8 files verified</span><span>✕ Task failed</span><span>? Benefit not proven</span>
      </div>
      <section aria-label="Recorded walkthroughs" class="stack">
        <article
          :for={video <- Enum.take(@report["recordings"], 3)}
          id={"verification-featured-" <> video["id"]}
          class="panel"
        >
          <h2>{video["title"]}</h2>
          <p>{video["result"]} · {video["duration"]}</p>
          <.recording video={video} />
          <p>{video["recorded_release"]}</p>
        </article>
        <details class="panel" id="verification-more-runs">
          <summary>Task failures and earlier runs</summary>
          <p>Original recordings preserve earlier UI wording.</p>
          <article
            :for={video <- Enum.drop(@report["recordings"], 3)}
            id={"verification-earlier-" <> video["id"]}
            class="panel"
          >
            <h2>{video["title"]}</h2>
            <p>{video["result"]} · {video["duration"]}</p>
            <.recording video={video} />
            <p>{video["recorded_release"]}</p>
          </article>
        </details>
      </section>
      <details class="panel" id="verification-details">
        <summary>Results and limits</summary>
        <p>{@report["harness_generation"]}. {@report["generation_route"]}.</p>
        <p>{@report["task_evaluation"]}.</p>
        <p>Benefit: {@report["benefit"]} · Matched pair: {@report["paired_comparison"]}.</p>
        <h3>Browser checks</h3>
        <ul id="verification-browser-checks">
          <li :for={check <- @report["browser_checks"]}>{check}</li>
        </ul>
        <p>
          148 connector contract checks and 14 official MCP client checks passed. GitHub captured 21 public records; other live providers remain unverified.
        </p>
        <p id="verification-images-status">
          Screenshots — unavailable. Original videos are for human viewing and have not been visually inspected by a model.
        </p>
        <p>Not established: {Enum.join(@report["not_established"], ", ")}.</p>
        <p>These recorded results do not qualify another company's harness.</p>
        <ul>
          <li :for={name <- @report["evidence_records"]}><code>{name}</code></li>
        </ul>
      </details>
      <.link href="/verification/report" class="button secondary" id="verification-download">Download evidence summary</.link>
    </main>
    """
  end
end

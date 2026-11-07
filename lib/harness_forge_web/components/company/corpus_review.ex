defmodule HarnessForgeWeb.Company.CorpusReview do
  @moduledoc "Stateless presentation of authorized, bounded corpus inspection DTOs."
  use HarnessForgeWeb, :html
  alias HarnessForgeWeb.Company.Analysis

  @choice_fields [
    {:connections, "connection", "connection_id", "Captured corpus"},
    {:projects, "project", "project_id", "Saved project"},
    {:goals, "goal", "goal_id", "Assigned saved goal"}
  ]

  attr :state, :map, required: true
  attr :pipeline, :map, default: nil
  attr :generation, :string, required: true
  attr :restriction, :map, default: %{}
  attr :interactive, :boolean, default: false
  attr :setup_return, :string, default: nil

  def review(assigns) do
    assigns =
      assigns
      |> assign(:choice_fields, @choice_fields)
      |> assign(:scope, assigns.state[:scope])
      |> assign(:page, assigns.state[:page])
      |> assign(:passage, assigns.state[:passage])
      |> assign(:recommendation, assigns.state[:recommendation])
      |> assign(
        :restriction_view,
        !!(assigns.restriction[:receipt] || assigns.restriction[:error])
      )

    ~H"""
    <section id="corpus-review-content" class="corpus-review" aria-labelledby="corpus-review-title">
      <header class="corpus-intro">
        <p class="eyebrow">COMPANY EVIDENCE</p>
        <h1 id="corpus-review-title">Corpus evidence review</h1>
        <p>
          Build from company evidence: ask a focused question, inspect its sources, then review proposed guidance.
        </p>
      </header>
      <.restriction_notice
        restriction={@restriction}
        generation={@generation}
        interactive={@interactive}
      />
      <div :if={@state[:error]} id="corpus-error" class="notice error" role="alert" tabindex="-1">
        {@state.error}
      </div>
      <p :if={@state[:notice]} id="corpus-notice" class="context-note" role="status" tabindex="-1">
        {@state.notice}
      </p>
      <section :if={!@restriction_view} class="corpus-card" aria-labelledby="corpus-scope-title">
        <h2 id="corpus-scope-title">
          {if @scope, do: "Selected company scope", else: "1. Prepare company context"}
        </h2>
        <.scope_summary :if={@scope} scope={@scope} />
        <p
          :for={entry <- omitted_entries(@pipeline)}
          id={"corpus-omitted-" <> entry["connection_id"]}
          class="corpus-boundary"
        >
          Optional source omitted: {entry["name"]} · {entry["reason_code"]}. Required scope remains separate.
        </p>
        <details id="corpus-scope-settings" open={is_nil(@scope)}>
          <summary>
            {if @scope, do: "Change scope or inspect saved context", else: "Choose company context"}
          </summary>
          <p id="corpus-scope-help">
            Choose an active connection, saved project and assigned goal. Choosing it does not assign its sources to the project or make them analysis inputs.
          </p>
          <p class="field-help">
            Need setup? <.link href="/?setup=company">Save a company profile and project</.link>, <.link href="/?setup=goals">save a future goal</.link>, then assign that goal to the profile or project in Company. <.link
              id="corpus-manage-connections"
              href={connections_path(@setup_return)}
            >Manage connections and models</.link>.
          </p>
          <.form
            for={%{}}
            id="corpus-scope-form"
            phx-change="corpus_scope_change"
            phx-submit="corpus_scope_open"
            phx-auto-recover="ignore"
            class="corpus-scope-form"
            aria-describedby="corpus-scope-help"
          >
            <input type="hidden" name="corpus_generation" value={@generation} />
            <input
              type="hidden"
              name="scope[goal_content_hash]"
              value={@state.selection["goal_content_hash"]}
            />
            <div :for={{key, kind, field, label} <- @choice_fields} class="corpus-choice-field">
              <label for={"corpus-" <> kind}>{label}</label>
              <select id={"corpus-" <> kind} name={"scope[#{field}]"} required>
                <option value="" selected={@state.selection[field] in [nil, ""]}>
                  Choose {String.downcase(label)}
                </option>
                <option
                  :if={off_page_choice(@state, key, field)}
                  value={@state.selection[field]}
                  selected
                >
                  {off_page_choice(@state, key, field)["title"]} · current selection outside this page
                </option>
                <option
                  :for={choice <- choice_rows(@state, key)}
                  value={choice["id"]}
                  selected={choice["id"] == @state.selection[field]}
                >
                  {choice["title"]}
                </option>
              </select>
              <p :if={choice_rows(@state, key) == []} class="field-help">
                {empty_choice_label(kind)}
              </p>
              <button
                :if={choice_cursor(@state, key)}
                id={"corpus-" <> kind <> "-choices-next"}
                type="button"
                class="button secondary"
                phx-click="corpus_choices_next"
                phx-value-corpus_generation={@generation}
                phx-value-kind={kind}
              >More {choice_label(kind)}</button>
            </div>
            <button id="corpus-scope-open" type="submit" class="button primary">Open selected scope</button>
          </.form>
          <.scope_facts :if={@scope} scope={@scope} counts={@page && @page["counts"]} />
        </details>
      </section>

      <.pipeline
        :if={@scope && @pipeline}
        state={@pipeline}
        scope={@scope}
        generation={@generation}
        interactive={@interactive}
        setup_return={@setup_return}
      />
      <HarnessForgeWeb.Company.Requirements.panel
        :if={@scope && @pipeline}
        state={@state}
        pipeline={@pipeline}
        generation={@generation}
      />

      <div :if={@scope} class="corpus-review-columns">
        <section class="corpus-card" aria-labelledby="corpus-preview-title">
          <h2 id="corpus-preview-title">Supplementary inspection</h2>
          <p class="corpus-boundary">Not part of this recommendation’s model input.</p>
          <.form
            for={%{}}
            id="corpus-search-form"
            phx-submit="corpus_search"
            phx-auto-recover="ignore"
            class="stack"
          >
            <input type="hidden" name="corpus_generation" value={@generation} />
            <label for="corpus-query">Find words in captured evidence</label>
            <input
              id="corpus-query"
              name="search[query]"
              value={@state[:query] || ""}
              maxlength="256"
              aria-describedby="corpus-query-help"
            />
            <p id="corpus-query-help" class="field-help">
              Literal word matching, up to 8 words. A match is candidate evidence that needs review. Try both expected guidance and contrary incidents. Leave blank to browse.
            </p>
            <div class="company-actions">
              <button id="corpus-search" type="submit" class="button primary">Find captured evidence</button>
              <button
                id="corpus-refresh"
                type="button"
                class="button secondary"
                phx-click="corpus_refresh"
                phx-value-corpus_generation={@generation}
              >Refresh current scope</button>
            </div>
          </.form>
          <div id="corpus-results" tabindex="-1" aria-labelledby="corpus-results-title">
            <h3 id="corpus-results-title">Candidate evidence · needs review</h3>
            <p id="corpus-results-status" role="status">
              {length(page_rows(@page))} sources on this live page · at most 25 per page.
              <span :if={@page && is_integer(@page["counts"]["matches"])}>{@page["counts"]["matches"]} literal matches in this captured corpus.</span>
            </p>
            <p :if={@page && page_rows(@page) == []} class="context-note">
              No matching captured sources. This does not establish that obligations, relevant evidence or contradictions are absent. Change the words or browse without a query.
            </p>
            <article
              :for={source <- page_rows(@page)}
              id={"corpus-source-" <> source["id"]}
              class="corpus-source"
            >
              <h4>{source["title"]}</h4>
              <p>Candidate evidence · needs review</p>
              <p>
                {if source["eligible"],
                  do: "Current captured revision",
                  else: "Unavailable for inspection"}
              </p>
              <p>Captured: {known(get_in(source, ["latest_revision", "captured_at"]))}.</p>
              <.source_metadata source={source} id={"corpus-source-" <> source["id"] <> "-metadata"} />
              <button
                :if={source["eligible"] && source["latest_revision"]}
                id={"corpus-source-open-" <> source["id"]}
                type="button"
                class="button secondary"
                phx-click="corpus_passage_open"
                phx-value-corpus_generation={@generation}
                phx-value-source_id={source["id"]}
                phx-value-revision_id={source["latest_revision"]["id"]}
                phx-value-body_hash={source["latest_revision"]["body_hash"]}
                phx-value-start_byte={source["match_start_byte"] || 0}
                aria-label={"Open exact passage from " <> source["title"]}
              >{if is_integer(source["match_start_byte"]),
                do: "Open matching passage",
                else: "Open first text window"}</button>
            </article>
            <nav class="company-actions" aria-label="Captured source pages">
              <button
                id="corpus-page-previous"
                type="button"
                class="button secondary"
                phx-click="corpus_page_previous"
                phx-value-corpus_generation={@generation}
                disabled={!@state[:previous?]}
              >Previous source page</button>
              <button
                id="corpus-page-next"
                type="button"
                class="button secondary"
                phx-click="corpus_page_next"
                phx-value-corpus_generation={@generation}
                disabled={!(@page && @page["next_cursor"])}
              >Next source page</button>
            </nav>
            <p class="field-help">
              These are live pages. New or changed captures may require an explicit refresh; this is not a snapshot of all company evidence.
            </p>
          </div>
          <.passage
            :if={@passage}
            passage={@passage}
            generation={@generation}
            interactive={@interactive}
          />
        </section>

        <section class="corpus-card" aria-labelledby="corpus-original-title">
          <h2 id="corpus-original-title">Compare an original recommendation</h2>
          <p>
            Choose an existing recommendation for this saved project and goal to compare its original findings with your inspection.
          </p>
          <details id="corpus-recommendation-choices" open={is_nil(@recommendation)}>
            <summary>
              Saved recommendations · {length(choice_rows(@state, :recommendations))} on this page
            </summary>
            <p :if={choice_rows(@state, :recommendations) == []} class="field-help">
              No matching saved recommendation on this page. Use the question and synthesis flow above to propose guidance; inspection remains available.
            </p>
            <div :for={choice <- choice_rows(@state, :recommendations)} class="corpus-source">
              <p>{choice["title"]}</p>
              <button
                id={"corpus-recommendation-open-" <> choice["id"]}
                type="button"
                class="button secondary"
                phx-click="corpus_recommendation_open"
                phx-value-corpus_generation={@generation}
                phx-value-claim_id={choice["id"]}
                phx-value-revision_hash={choice["revision_hash"]}
              >Open original findings</button>
            </div>
            <button
              :if={choice_cursor(@state, :recommendations)}
              id="corpus-recommendation-choices-next"
              type="button"
              class="button secondary"
              phx-click="corpus_choices_next"
              phx-value-corpus_generation={@generation}
              phx-value-kind="recommendation"
            >More saved recommendations</button>
          </details>
          <.original_report
            :if={@recommendation}
            recommendation={@recommendation}
            generation={@generation}
          />
        </section>
      </div>
    </section>
    """
  end

  attr :scope, :map, required: true

  defp scope_summary(assigns) do
    ~H"""
    <div id="corpus-scope-summary" class="corpus-selected-scope">
      <p><strong>{@scope["project"]["name"]}</strong> · {@scope["connection"]["name"]}</p>
      <p><strong>Assigned goal:</strong> {@scope["goal"]["title"]}</p>
    </div>
    """
  end

  attr :scope, :map, required: true
  attr :counts, :any, default: nil

  defp scope_facts(assigns) do
    ~H"""
    <div id="corpus-scope-facts" class="context-note">
      <h3>Saved context and capture facts</h3>
      <p>Captured corpus: {@scope["connection"]["name"]} · {@scope["connection"]["provider"]}</p>
      <p>Owner: {@scope["goal"]["owner"]} · Acceptance: {@scope["goal"]["acceptance"]}</p>
      <p>
        <strong>Project source assignments:</strong> {@scope["assignment_counts"]["project_sources"]} · company profile assignments: {@scope[
          "assignment_counts"
        ]["profile_sources"]} · distinct assigned sources: {@scope["assignment_counts"][
          "distinct_sources"
        ]}.
      </p>
      <dl :if={@counts} class="corpus-counts">
        <div>
          <dt>Locally captured</dt><dd>{@counts["captured"]}</dd>
        </div>
        <div>
          <dt>Current available captures</dt><dd>{@counts["current"]}</dd>
        </div>
        <div>
          <dt>Unavailable captures</dt><dd>{@counts["unavailable"]}</dd>
        </div>
      </dl>
      <p>
        <strong>Discovery coverage:</strong>
        unknown. <strong>Whole-corpus model coverage:</strong>
        unknown.
      </p>
      <details>
        <summary>Capture facts and saved scope identities</summary>
        <p>
          Stored sync state: {known(@scope["connection"]["sync_state"])} · stored sync complete: {boolean_label(
            @scope["connection"]["sync_complete"]
          )}.
        </p>
        <p>
          Last sync: {known(@scope["connection"]["last_synced_at"])}. These local capture facts do not establish that all company files were discovered or analyzed.
        </p>
        <p>
          Connection <code>{@scope["connection"]["id"]}</code>
          · project <code>{@scope["project"]["id"]}</code>
        </p>
        <p>
          Goal <code>{@scope["goal"]["id"]}</code>
          · saved goal hash <code>{@scope["goal"]["content_hash"]}</code>
        </p>
      </details>
    </div>
    """
  end

  attr :source, :map, required: true
  attr :id, :string, required: true

  defp source_metadata(assigns) do
    assigns = assign(assigns, :revision, assigns.source["latest_revision"] || %{})

    ~H"""
    <details id={@id} class="corpus-metadata">
      <summary>Capture dates, original link and exact identity</summary>
      <p>
        Captured: {known(@revision["captured_at"])} · source last updated: {known(
          @revision["source_updated_at"]
        )}.
      </p>
      <p>
        Document status: {known(get_in(@revision, ["metadata", "document_status"]))} · effective date: {known(
          get_in(@revision, ["metadata", "effective_at"])
        )} · event date: {known(get_in(@revision, ["metadata", "event_at"]))}.
      </p>
      <p>Capture order does not establish policy chronology or approval.</p>
      <a
        :if={Analysis.source_url(@source)}
        id={@id <> "-link"}
        href={Analysis.source_url(@source)}
        target="_blank"
        rel="noopener noreferrer"
      >Open stored source link (opens in a new tab)</a>
      <p :if={!Analysis.source_url(@source)}>Source link unavailable.</p>
      <p>Stored links may have changed since capture.</p>
      <p>Source <code>{@source["id"]}</code> · revision <code>{@revision["id"]}</code></p>
      <p>
        Body hash <code>{@revision["body_hash"]}</code>
        · captured body length: {known(@revision["body_bytes"])} UTF-8 bytes.
      </p>
    </details>
    """
  end

  attr :passage, :map, required: true
  attr :generation, :string, required: true
  attr :interactive, :boolean, default: false

  defp passage(assigns) do
    ~H"""
    <section
      id="corpus-passage"
      class="corpus-passage"
      tabindex="-1"
      aria-labelledby="corpus-passage-title"
    >
      <h3 id="corpus-passage-title">Exact captured text window</h3>
      <p><strong>{@passage["source"]["title"]}</strong></p>
      <p>Captured: {known(get_in(@passage, ["source", "latest_revision", "captured_at"]))}.</p>
      <p>
        UTF-8 bytes {@passage["start_byte"]}–{@passage["end_byte"]} (exclusive end) of {@passage[
          "body_bytes"
        ]} bytes. At most 4,096 bytes are open.
      </p>
      <p :if={@passage["truncated_before"] || @passage["truncated_after"]} class="corpus-boundary">
        Partial parent context. {if @passage["truncated_before"], do: "Earlier text is omitted. "}{if @passage[
                                                                                                        "truncated_after"
                                                                                                      ],
                                                                                                      do:
                                                                                                        "Later text is omitted. "}Read surrounding context before judging meaning.
      </p>
      <p :if={!@passage["truncated_before"] && !@passage["truncated_after"]}>
        This window contains the full captured text; external freshness and meaning still need review.
      </p>
      <pre id="corpus-passage-text" tabindex="0" aria-label="Exact captured passage">{@passage["text"]}</pre>
      <.source_metadata source={@passage["source"]} id="corpus-passage-metadata" />
      <p>
        Exact revision <code>{@passage["revision_id"]}</code>
        · body hash <code>{@passage["body_hash"]}</code>
      </p>
      <.block_use inspection="supplementary" generation={@generation} interactive={@interactive} />
      <div class="company-actions">
        <button
          :if={@passage["truncated_before"]}
          id="corpus-passage-start"
          type="button"
          class="button secondary"
          phx-click="corpus_passage_open"
          phx-value-corpus_generation={@generation}
          phx-value-source_id={@passage["source"]["id"]}
          phx-value-revision_id={@passage["revision_id"]}
          phx-value-body_hash={@passage["body_hash"]}
          phx-value-start_byte="0"
        >Read context from start</button>
        <button
          :if={is_integer(@passage["next_start_byte"])}
          id="corpus-passage-next"
          type="button"
          class="button secondary"
          phx-click="corpus_passage_next"
          phx-value-corpus_generation={@generation}
          phx-value-source_id={@passage["source"]["id"]}
          phx-value-revision_id={@passage["revision_id"]}
          phx-value-body_hash={@passage["body_hash"]}
          phx-value-start_byte={@passage["next_start_byte"]}
        >Read next text window</button>
        <button
          id="corpus-passage-close"
          type="button"
          class="button secondary"
          phx-click="corpus_passage_close"
          phx-value-corpus_generation={@generation}
        >Close text window</button>
      </div>
    </section>
    """
  end

  attr :recommendation, :map, required: true
  attr :generation, :string, required: true

  defp original_report(assigns) do
    report = assigns.recommendation["report"]

    assigns =
      assigns
      |> assign(:report, report)
      |> assign(:findings, report["findings"])
      |> assign(:resolution_required, resolution_required?(report))

    ~H"""
    <article id="corpus-original-report" aria-labelledby="corpus-original-report-title">
      <h3 id="corpus-original-report-title" tabindex="-1">Original recommendation and findings</h3>
      <p>
        <strong>Original recommendation status:</strong> {get_in(@report, ["recommendation", "status"]) ||
          "No recommendation recorded"}.
      </p>
      <p>
        <strong>Original analyzed scope:</strong> {length(@recommendation["analyzed_sources"])} {if @recommendation[
                                                                                                      "origin_version"
                                                                                                    ] ==
                                                                                                      2,
                                                                                                    do:
                                                                                                      "selected input sources",
                                                                                                    else:
                                                                                                      "explicitly selected sources"}. Additional preview evidence above is outside this original model input.
        <span :if={@recommendation["origin_version"] == 2}>
          Exact selected passages and additional graph lineage remain pinned in the sealed manifest.
        </span>
      </p>
      <p :if={@recommendation["outside_inspection_connection"]} class="corpus-boundary">
        This original analysis includes sources outside the selected captured corpus. It does not establish coverage of this corpus.
      </p>
      <p><strong>Original uncertainty:</strong> {@report["uncertainty"]}</p>
      <p>
        <strong>Goal rationale:</strong> {get_in(@report, ["recommendation", "goal_rationale"]) ||
          "No recommendation recorded"}
      </p>
      <p>
        Recorded conflict findings: {Enum.count(@findings, &(&1["kind"] == "conflict"))} · recorded unknown findings: {Enum.count(
          @findings,
          &(&1["kind"] == "unknown")
        )}. Missing conflict findings do not establish that contradictions are absent.
      </p>
      <p :if={@resolution_required} class="corpus-boundary">
        Human resolution is required before approval because the original report declares uncertainty or conflict. A saved resolution records your judgment; it is not automated proof.
      </p>
      <p :if={@recommendation["review_resolution"]}>
        <strong>Saved human resolution:</strong> {@recommendation["review_resolution"]}
      </p>
      <article
        :for={{finding, index} <- Enum.with_index(@findings)}
        id={"corpus-original-finding-#{index}"}
        class="corpus-finding"
      >
        <h4>{String.capitalize(finding["kind"])}</h4>
        <p>{finding["statement"]}</p>
        <p :if={finding["kind"] == "unknown"}>This original unknown has no supporting excerpt.</p>
        <blockquote :for={citation <- finding["citations"]}>
          <p>{citation["snippet"]}</p>
          <footer>
            Source <code>{citation["source_id"]}</code>
            · revision <code>{citation["revision_id"]}</code>
            · UTF-8 bytes {citation["start_byte"]}–{citation["end_byte"]} (exclusive end).
          </footer>
        </blockquote>
      </article>
      <details id="corpus-original-provenance">
        <summary>Original model-input identities and current guidance</summary>
        <p :for={source <- @recommendation["analyzed_sources"]}>
          Included source <code>{source["source_id"] || source["id"]}</code>
          · revision <code>{source["revision_id"] || get_in(source, ["latest_revision", "id"])}</code>
          · body hash
          <code>{source["body_hash"] || get_in(source, ["latest_revision", "body_hash"])}</code>
        </p>
        <p :for={field <- Analysis.fields()}>
          <strong>{field_label(field)}:</strong> {@recommendation["guidance"][field]}
        </p>
        <p>
          Exact claim <code>{@recommendation["claim_id"]}</code>
          · revision <code>{@recommendation["revision_hash"]}</code>
          · current state: {@recommendation["status"]}.
        </p>
      </details>
      <p class="field-help">
        Continue to deliberately edit or reject guidance and decide its exact revision. Claim approval and the separate plan approval remain required before building and exporting.
      </p>
      <button
        id="corpus-continue-review"
        type="button"
        class="button primary"
        phx-click="corpus_continue_review"
        phx-value-corpus_generation={@generation}
        phx-value-claim_id={@recommendation["claim_id"]}
        phx-value-revision_hash={@recommendation["revision_hash"]}
        disabled={!@recommendation["eligible"] || @recommendation["superseded"]}
      >Continue exact recommendation review</button>
    </article>
    """
  end

  attr :inspection, :string, required: true
  attr :generation, :string, required: true
  attr :interactive, :boolean, required: true

  defp block_use(assigns) do
    ~H"""
    <details id={"corpus-revision-block-" <> @inspection} class="corpus-boundary">
      <summary>Block use of this exact revision</summary>
      <p id={"corpus-revision-block-help-" <> @inspection}>
        This prevents inspection, retrieval, analysis and harness compilation from this opened revision.
        Further capture of this source is also blocked. This action cannot be undone here; stored bytes may remain.
      </p>
      <button
        id={"corpus-revision-block-confirm-" <> @inspection}
        type="button"
        class="button secondary"
        phx-click="corpus_revision_block"
        phx-value-corpus_generation={@generation}
        phx-value-inspection={@inspection}
        aria-describedby={"corpus-revision-block-help-" <> @inspection}
        disabled={!@interactive}
      >Block use</button>
    </details>
    """
  end

  attr :restriction, :map, required: true
  attr :generation, :string, required: true
  attr :interactive, :boolean, required: true

  defp restriction_notice(assigns) do
    assigns =
      assigns
      |> assign(:receipt, assigns.restriction[:receipt])
      |> assign(:operation, assigns.restriction[:operation])
      |> assign(:restriction_error, assigns.restriction[:error])
      |> assign(:event_id, assigns.restriction[:event_id])

    ~H"""
    <section
      :if={@receipt || @restriction_error}
      id="corpus-restriction"
      class="corpus-card"
      aria-labelledby="corpus-restriction-title"
    >
      <h2 id="corpus-restriction-title">Revision use restriction</h2>
      <p
        :if={@restriction_error}
        id="corpus-restriction-error"
        class="notice error"
        role="alert"
        tabindex="-1"
      >
        {@restriction_error}
      </p>
      <div :if={@receipt} id="corpus-restriction-receipt" role="status" tabindex="-1">
        <p>
          <strong>Use blocked.</strong>
          Inspection, retrieval, analysis and harness compilation are denied.
        </p>
        <p :if={@receipt["cleanup_state"] == "pending"} id="corpus-restriction-pending">
          Cleanup pending; stored bytes may remain.
        </p>
        <p :if={@receipt["cleanup_state"] == "completed"} id="corpus-restriction-completed">
          Cleanup completed. Use remains blocked; stored bytes may remain.
        </p>
        <details id="corpus-restriction-identities">
          <summary>Exact revision and recovery receipt</summary>
          <p>
            Source <code>{@receipt["source_id"]}</code>
            · revision <code>{@receipt["revision_id"]}</code>.
          </p>
          <p>Body hash <code>{@receipt["body_hash"]}</code>.</p>
          <p>
            Receipt <code>{@receipt["event_id"]}</code>
            · cleanup version {@receipt["cleanup_version"]}.
          </p>
          <p>This receipt contains no source text. Refreshing this page checks its saved status.</p>
        </details>
      </div>
      <p :if={@operation} class="field-help">
        Retrying uses the same saved command for this exact revision. It does not create a new request or restore access.
      </p>
      <div class="company-actions">
        <button
          :if={@receipt && @receipt["cleanup_state"] == "pending"}
          id="corpus-restriction-cleanup"
          type="button"
          class="button primary"
          phx-click="corpus_revision_cleanup"
          phx-value-corpus_generation={@generation}
          disabled={!@interactive}
        >Resume cleanup</button>
        <button
          :if={@event_id}
          id="corpus-restriction-status"
          type="button"
          class="button secondary"
          phx-click="corpus_revision_status"
          phx-value-corpus_generation={@generation}
          disabled={!@interactive}
        >Check saved status</button>
        <button
          :if={@operation}
          id="corpus-restriction-retry"
          type="button"
          class="button secondary"
          phx-click="corpus_revision_retry"
          phx-value-corpus_generation={@generation}
          disabled={!@interactive}
        >Retry the same block request</button>
        <.link href="/company/corpus" class="button secondary">Return to current evidence</.link>
      </div>
      <p :if={@receipt && @receipt["cleanup_state"] == "pending"} class="field-help">
        Each resume processes a bounded batch. Completing cleanup does not remove the restriction or erase the captured source.
      </p>
    </section>
    """
  end

  defp choice_rows(state, key), do: get_in(state, [:choices, key, "rows"]) || []
  defp choice_cursor(state, key), do: get_in(state, [:choices, key, "next_cursor"])
  defp page_rows(nil), do: []
  defp page_rows(page), do: page["rows"] || []

  defp off_page_choice(state, key, field) do
    selected = get_in(state, [:selected_choices, key])

    if selected && selected["id"] == state.selection[field] &&
         !Enum.any?(choice_rows(state, key), &(&1["id"] == selected["id"])),
       do: selected
  end

  defp choice_label("connection"), do: "captured corpora"
  defp choice_label("project"), do: "saved projects"
  defp choice_label("goal"), do: "assigned goals"
  defp empty_choice_label("connection"), do: "No active captured connection on this page."
  defp empty_choice_label("project"), do: "No saved project on this page."
  defp empty_choice_label("goal"), do: "Choose a saved project to see its assigned goals."
  defp known(nil), do: "unknown"
  defp known(""), do: "unknown"
  defp known(value), do: value

  defp connections_path(nil), do: "/?setup=connections"

  defp connections_path(id),
    do: "/?" <> URI.encode_query(%{"view" => "connections", "setup_return" => id})

  defp claim_review_path(claim, setup_return) do
    params = %{"company_review" => claim["id"], "revision_hash" => claim["revision_hash"]}
    params = if setup_return, do: Map.put(params, "setup_return", setup_return), else: params
    "/?" <> URI.encode_query(params)
  end

  defp boolean_label(true), do: "yes"
  defp boolean_label(false), do: "no"
  defp boolean_label(_), do: "unknown"

  defp omitted_entries(%{declaration: %{"entries" => entries}}),
    do: Enum.filter(entries, &(&1["requirement"] == "optional" && &1["state"] == "omitted"))

  defp omitted_entries(_), do: []
  defp field_label("evaluation_criterion"), do: "Evaluation criterion"
  defp field_label(field), do: String.capitalize(field)

  defp resolution_required?(report),
    do:
      get_in(report, ["recommendation", "status"]) in ~w(uncertain conflicted) or
        Enum.any?(report["findings"], &(&1["kind"] == "conflict"))

  attr :state, :map, required: true
  attr :scope, :map, default: nil
  attr :generation, :string, required: true
  attr :interactive, :boolean, default: false
  attr :setup_return, :string, default: nil

  def pipeline(assigns) do
    assigns =
      assign(
        assigns,
        :local_capture,
        get_in(assigns.scope || %{}, ["connection", "provider"]) == "local"
      )

    ~H"""
    <section
      id="company-corpus-pipeline"
      class="corpus-card"
      aria-labelledby="company-corpus-pipeline-title"
    >
      <h2 id="company-corpus-pipeline-title" tabindex="-1">
        {if @state.corpus, do: "2. Ask a company question", else: "2. Capture company evidence"}
      </h2>
      <p :if={@state.error} id="company-corpus-error" class="notice error" role="alert" tabindex="-1">
        {@state.error}
      </p>
      <p :if={@state.busy} role="status">Working with the selected evidence…</p>
      <.link
        :if={@state.corpus && @local_capture}
        href={assistant_access_path(@state.corpus, @scope)}
        id="company-corpus-assistant-access"
        class="button secondary"
      >Connect an assistant</.link>
      <p :if={!@local_capture} id="company-corpus-capture-unsupported" class="context-note">
        Directory capture is unsupported for this connection. Existing remote captures remain inspectable.
        <.link href={connections_path(@setup_return)}>Choose an approved local directory in Connections</.link>
        for directory capture.
      </p>
      <p :if={@state.capture} id="company-corpus-capture-brief" class="field-help" role="status">
        Capture: {@state.capture["state"]}. Discovery and semantic coverage remain unknown.
      </p>
      <p
        :if={
          @state.capture &&
            (@state.capture["state"] in ~w(paused failed cancelled) || @state.capture["error_code"])
        }
        id="company-corpus-capture-recovery"
        class="notice error"
        role="alert"
      >
        Capture needs attention. <a href="#company-corpus-capture-details">Review capture status and recovery controls</a>.
      </p>
      <.capture_controls
        :if={is_nil(@state.capture)}
        state={@state}
        local_capture={@local_capture}
        generation={@generation}
      />
      <.form
        :if={@state.corpus}
        for={%{}}
        id="company-corpus-question"
        phx-change="corpus_question_change"
        phx-submit="corpus_retrieve"
        phx-auto-recover="ignore"
      >
        <input type="hidden" name="corpus_generation" value={@generation} />
        <label for="company-corpus-question-text">What should the harness help your company do?</label>
        <textarea
          id="company-corpus-question-text"
          name="retrieval[question]"
          maxlength="256"
          rows="3"
          aria-describedby="company-corpus-question-help"
          disabled={@state.busy}
          required
        >{@state.question}</textarea>
        <button id="company-corpus-retrieve" class="button primary" disabled={@state.busy}>Find supporting and contrary evidence</button>
        <details id="company-corpus-question-settings">
          <summary>
            Search options · {if @state.mode == "graphiti_hybrid",
              do: "Graph and keyword passages",
              else: "Keyword passages"}
          </summary>
          <p id="company-corpus-question-help" class="field-help">
            At most 256 characters and 1,024 UTF-8 bytes. The draft stays in this open scope while you work; a fresh page requires re-selection. Changing scope or privacy clears it.
          </p>
          <label for="company-corpus-retrieval-mode">Evidence search</label>
          <select id="company-corpus-retrieval-mode" name="retrieval[mode]" disabled={@state.busy}><option
            value="fts"
            selected={@state.mode == "fts"}
          >
            Keyword passages
          </option><option value="graphiti_hybrid" selected={@state.mode == "graphiti_hybrid"}>
            Graph and keyword passages (requires a qualified graph)
          </option></select>
        </details>
      </.form>
      <.capture_controls
        :if={@state.capture}
        state={@state}
        local_capture={@local_capture}
        generation={@generation}
      />
      <section
        :if={@state.run}
        id="company-corpus-results"
        tabindex="-1"
        aria-labelledby="company-corpus-run-title"
      >
        <h3 id="company-corpus-run-title">Evidence for this question</h3>
        <p>
          {run_summary(@state.run)} Selected passages: {@state.run["selected_count"]}. Search cannot establish complete company-wide coverage.
        </p>
        <p>
          <strong>Submitted question:</strong> {@state.submitted_question} · search: {@state.run[
            "mode"
          ]}.
        </p>
        <.question_search run={@state.run} busy={@state.busy} />
        <p>
          Relations below are provisional search labels. Inspect the original passage before relying on them.
        </p>
        <p class="field-help">
          Source names show current display identities. A sealed recommendation keeps its original exact versions.
        </p>
        <div :for={row <- (@state.page && @state.page["rows"]) || []} class="corpus-result">
          <h4>{known(row["title"])}</h4>
          <p>
            {row["lane"]} · {row["relation"]} · {if is_nil(row["selected_order"]),
              do: "additional candidate outside selected synthesis input",
              else: "included in selected analysis passages"}
          </p>
          <p>
            Document status: {known(row["document_status"])} · event: {known(row["event_at"])} · effective: {known(
              row["effective_at"]
            )} · captured: {known(row["captured_at"])}.
          </p>
          <blockquote>{snippet_preview(row)}</blockquote>
          <p :if={snippet_shortened?(row)} class="field-help">
            Shortened excerpt—open exact context for the complete passage.
          </p>
          <p :if={row["parent_incomplete"]}>
            Parent context is incomplete; inspect the exact window before judging meaning.
          </p>
          <details>
            <summary>Exact source, revision and passage identities</summary>
            <p>
              Source <code>{row["source_id"]}</code>
              · revision <code>{row["revision_id"]}</code>
              · body hash <code>{row["body_hash"]}</code>.
            </p>
            <p>
              Original passage UTF-8 bytes {row["start_byte"]}–{row["end_byte"]} (exclusive end) · snippet hash <code>{row["snippet_hash"]}</code>.
            </p>
            <p>
              Parent bytes {row["parent_start_byte"]}–{row["parent_end_byte"]} · parent hash <code>{row["parent_hash"]}</code>.
            </p>
            <a :if={row_url(row)} href={row_url(row)} target="_blank" rel="noopener noreferrer">Open stored source link (opens in a new tab)</a>
            <p :if={!row_url(row)}>Source link unavailable.</p>
            <p>Stored links may have changed since capture.</p>
          </details>
          <button
            class="button secondary"
            phx-click="corpus_run_passage"
            phx-value-corpus_generation={@generation}
            phx-value-passage_id={row["passage_id"]}
          >Inspect exact context from {known(row["title"])}</button>
        </div>
        <button
          :if={@state.page && @state.page["next_cursor"]}
          class="button secondary"
          phx-click="corpus_run_next"
          phx-value-corpus_generation={@generation}
        >More evidence</button>
        <div
          :if={@state.passage}
          id="company-corpus-exact-passage"
          tabindex="-1"
          aria-label="Exact selected passage context"
        >
          <h4>{@state.passage["title"]}</h4><p>
            Original UTF-8 bytes {@state.passage["parent_start_byte"]}–{@state.passage[
              "parent_end_byte"
            ]}
          </p>
          <p :if={@state.passage["parent_incomplete"]}>
            Partial parent context; omitted text may change meaning.
          </p>
          <pre class="corpus-passage-text" tabindex="0" aria-label="Exact captured parent context">{@state.passage["parent_text"]}</pre>
          <.block_use inspection="selected" generation={@generation} interactive={@interactive} />
          <button
            type="button"
            class="button secondary"
            phx-click="corpus_run_passage_close"
            phx-value-corpus_generation={@generation}
          >Close context and return to evidence</button>
        </div>
        <button
          :if={@state.run["state"] == "ready"}
          class="button primary"
          phx-click="corpus_stage_prepare"
          phx-value-corpus_generation={@generation}
          disabled={@state.busy}
        >Review synthesis scope</button>
      </section>
      <section
        :if={@state.stage}
        id="company-corpus-synthesis-consent"
        aria-labelledby="company-corpus-synthesis-title"
      >
        <h3 id="company-corpus-synthesis-title" tabindex="-1">
          Allow this model to analyse these exact versions?
        </h3>
        <p>{@state.stage["provider"]} · {@state.stage["model"]} · {@state.stage["endpoint"]}</p>
        <p>
          {@state.stage["passage_count"]} passages from {@state.stage["source_count"]} source versions, with the saved project, company context and goal. New or changed source versions require another review.
        </p>
        <p>
          No recommendation is approved by this action. Model usage is reserved against the run's configured budget.
          Additional candidates and supplementary inspection are outside the selected analysis passages; graph lineage remains separately pinned in the sealed manifest.
        </p>
        <button
          class="button primary"
          phx-click="corpus_synthesize"
          phx-value-corpus_generation={@generation}
          disabled={@state.busy}
        >Allow synthesis and propose guidance</button>
      </section>
      <section :if={@state.claim} id="company-corpus-proposal" tabindex="-1">
        <h3>Proposed guidance is ready for review</h3>
        <p>
          Read the findings, correct or reject the guidance, and decide on this exact revision. A separate plan approval is required before building.
          Exported files and static integrity PASS are separate from representative task results. A task marked BLOCKED: model_not_selected has not been dispatched or passed.
        </p>
        <.link
          class="button primary"
          href={claim_review_path(@state.claim, @setup_return)}
        >Review and correct proposed guidance</.link>
      </section>
    </section>
    """
  end

  attr :state, :map, required: true
  attr :local_capture, :boolean, required: true
  attr :generation, :string, required: true

  defp capture_controls(assigns) do
    ~H"""
    <details
      id="company-corpus-capture-details"
      open={
        is_nil(@state.capture) || @state.capture["state"] in ~w(paused failed cancelled) ||
          !is_nil(@state.capture["error_code"])
      }
    >
      <summary>
        Capture and index details{if @state.capture, do: " · " <> @state.capture["state"]}
      </summary>
      <p class="field-help">
        Capture the approved local directory in bounded batches. A complete scan does not establish company-wide coverage, semantic sufficiency or recommendation approval.
      </p>
      <button
        id="company-corpus-capture"
        class="button primary"
        phx-click="corpus_capture_start"
        phx-value-corpus_generation={@generation}
        disabled={@state.busy || !@local_capture}
      >Capture selected local directory</button>
      <div :if={@state.capture} id="company-corpus-capture-status">
        <p role="status">
          Capture: {@state.capture["state"]} · checkpoint {known(
            get_in(@state.capture, ["capture", "checkpoint"])
          )} · local scan complete: {boolean_label(get_in(@state.capture, ["capture", "complete"]))}.
        </p>
        <p :if={@state.capture["state"] in ~w(paused failed)}>
          Capture is incomplete. Refresh status for details. Resuming a paused capture is not available in this view.
        </p>
        <p>
          Observed entries in this scan: {Enum.map_join(
            Enum.sort(get_in(@state.capture, ["capture", "counts"]) || %{}),
            " · ",
            fn {state, count} -> "#{state}: #{count}" end
          )}.
        </p>
        <p>
          Keyword index: {known(get_in(@state.capture, ["fts", "indexed"]))} / {known(
            get_in(@state.capture, ["fts", "expected"])
          )} active captured members.
          Discovery coverage and semantic coverage remain unknown. A complete local scan is not complete company coverage.
        </p>
        <p :if={@state.capture["error_code"]}>Capture reason: {@state.capture["error_code"]}.</p>
        <button
          class="button secondary"
          phx-click="corpus_capture_status"
          phx-value-corpus_generation={@generation}
        >Refresh capture and index status</button>
      </div>
    </details>
    """
  end

  defp row_url(row),
    do: Analysis.source_url(%{"latest_revision" => %{"source_url" => row["source_url"]}})

  defp snippet_preview(row), do: row["snippet"] |> known() |> String.slice(0, 360)

  defp snippet_shortened?(row),
    do: is_binary(row["snippet"]) && String.length(row["snippet"]) > 360

  attr :run, :map, required: true
  attr :busy, :boolean, required: true

  defp question_search(assigns) do
    diagnostic = get_in(assigns.run, ["coverage", "search", "question"])
    question = if is_map(diagnostic), do: diagnostic, else: %{}

    lexical =
      question["status"] == "lexical" and is_integer(question["candidates"]) and
        is_integer(question["selected"]) and is_list(question["searched_terms"])

    assigns = assigns |> assign(:question, question) |> assign(:lexical, lexical)

    ~H"""
    <div id="company-corpus-question-coverage" class="field-help">
      <%= if @lexical do %>
        <p>
          Question-derived candidates: {@question["candidates"]} · selected for synthesis: {@question[
            "selected"
          ]}.
        </p>
        <p :if={@question["candidates"] == 0}>
          <strong>No question-matched evidence found; background evidence only.</strong>
        </p>
        <p :if={@question["candidates"] > 0 and @question["selected"] == 0}>
          <strong>Question-matched candidates were found; none were selected for synthesis.</strong>
        </p>
        <p>Goal and follow-up searches may supply background evidence.</p>
        <details id="company-corpus-question-search-details">
          <summary>Question search details</summary>
          <p>
            Searched question terms: <code>{if @question["searched_terms"] == [],
              do: "None; search used saved goal terms",
              else: Enum.join(@question["searched_terms"], ", ")}</code>.
          </p>
          <p>Query plan version: <code>{known(@question["query_plan_version"])}</code>.</p>
        </details>
      <% else %>
        <p>Question search details: unknown for this run.</p>
      <% end %>
      <p>Matches do not establish that this question can be answered.</p>
      <button
        id="company-corpus-retry-question"
        type="button"
        class="button secondary"
        phx-click={Phoenix.LiveView.JS.focus(to: "#company-corpus-question-text")}
        disabled={@busy}
      >Edit question and search again</button>
    </div>
    """
  end

  defp assistant_access_path(corpus, scope) do
    "/mcp/access?" <>
      URI.encode_query(%{
        "corpus_id" => corpus["id"],
        "expected_generation" => corpus["semantic_generation"],
        "project_id" => scope["project"]["id"],
        "goal_id" => scope["goal"]["id"],
        "goal_hash" => scope["goal"]["content_hash"]
      })
  end

  defp run_summary(%{"state" => "ready"}),
    do:
      "Evidence gathered for review; capture, index and context checks passed. Semantic coverage remains unknown."

  defp run_summary(%{"selected_count" => 0}),
    do: "No passages selected; this does not prove that relevant or contrary evidence is absent."

  defp run_summary(_),
    do:
      "Search is incomplete: capture, indexing, omitted candidates or parent context need review. Synthesis is unavailable for this run."
end

defmodule HarnessForgeWeb.Company.Analysis do
  @moduledoc false
  use HarnessForgeWeb, :html
  alias HarnessForge.Goals
  alias HarnessForge.Models.CompanyAnalysis, as: AnalysisOutput

  @fields ~w(rule workflow check evaluation_criterion)
  def fields, do: @fields
  def empty, do: %{"project_id" => "", "source_ids" => [], "goal_id" => ""}

  def scoped(records, profile, project, key) do
    ids =
      (get_in(profile || %{}, ["payload", key]) || []) ++
        (get_in(project || %{}, ["payload", key]) || [])

    Enum.filter(records, &(&1["id"] in ids))
  end

  def capture(attrs, prior, pins, sources, goals) do
    ids = Enum.reject(attrs["source_ids"] || [], &(&1 == "")) |> Enum.uniq()
    draft = Map.take(attrs, ~w(project_id goal_id)) |> Map.put("source_ids", ids)
    changed = draft["project_id"] != prior["project_id"]
    pins = if changed, do: %{}, else: pins
    refs = Map.get(pins, :sources, %{})

    refs =
      Map.new(ids, fn id ->
        source = Enum.find(sources, &(&1["id"] == id))
        revision = source && source["latest_revision"]

        ref =
          if revision,
            do: %{
              "source_id" => id,
              "revision_id" => revision["id"],
              "body_hash" => revision["body_hash"]
            }

        {id, Map.get(refs, id, ref)}
      end)

    goal = Enum.find(goals, &(&1["id"] == draft["goal_id"]))

    hash =
      if !changed && draft["goal_id"] == prior["goal_id"],
        do: pins[:goal_hash],
        else: goal && Goals.content_hash(goal)

    {draft, %{sources: refs, goal_hash: hash}}
  end

  def input(draft, pins) do
    refs = Enum.map(draft["source_ids"], &get_in(pins, [:sources, &1]))

    if length(refs) in 2..4 && Enum.all?(refs, &is_map/1) &&
         draft["project_id"] not in [nil, ""] && draft["goal_id"] not in [nil, ""] &&
         is_binary(pins[:goal_hash]),
       do:
         {:ok,
          %{
            "project_id" => draft["project_id"],
            "source_refs" => Enum.sort_by(refs, & &1["source_id"]),
            "goal_id" => draft["goal_id"],
            "goal_content_hash" => pins.goal_hash
          }},
       else: {:error, :invalid_company_analysis_input}
  end

  def edit(claim) do
    claim["basis"]["guidance"]
    |> Map.merge(%{
      "id" => claim["id"],
      "expected_revision_hash" => claim["revision_hash"],
      "review_resolution" => claim["basis"]["review_resolution"] || ""
    })
  end

  def resolution_required?(%{"basis" => %{"kind" => "company_analysis", "report" => report}}) do
    get_in(report, ["recommendation", "status"]) in ~w(uncertain conflicted) ||
      Enum.any?(report["findings"] || [], &(&1["kind"] == "conflict"))
  end

  def resolution_required?(_), do: false
  def analysis?(claim), do: match?(%{"kind" => "company_analysis"}, claim["basis"])

  def error_message(reason) do
    case reason do
      :invalid_company_analysis_input ->
        "Choose one saved project, 2–4 distinct current sources and one assigned saved goal."

      :company_analysis_out_of_scope ->
        "The selected sources or goal are outside this company/project scope. Review their saved assignments."

      :company_analysis_input_too_large ->
        "These sources exceed the analysis size limit. Choose fewer or smaller captured sources."

      :invalid_company_analysis_output ->
        "The model returned an invalid analysis. No recommendation was admitted. Review the configured model before a new request."

      :stale_company_analysis_context ->
        "The selected source, goal or company context changed. Clear the selection and explicitly choose current inputs for a new analysis."

      :model_configuration_changed ->
        "Model settings or consent changed during this request. Review Connections before starting a new analysis."

      :analysis_resolution_required ->
        "Save a human resolution for the original uncertainty or conflict before approving."

      :stale_revision ->
        "This exact recommendation revision changed. Reopen the current revision before saving."

      :dirty_draft ->
        "Save or discard the guidance edits before leaving this review."

      reason when reason in [:cloud_consent_required, :company_context_consent_required] ->
        "In Connections, explicitly permit these sources and company context for the chosen cloud provider."

      reason
      when reason in [
             :model_unavailable,
             :model_not_selected,
             :model_not_configured,
             :provider_unavailable,
             :service_unavailable,
             :model_service_unavailable
           ] ->
        "Company analysis is unavailable. Select an available model in Connections. Existing approved plans can still be built."

      reason
      when reason in [
             :budget_exceeded,
             :budget_exhausted,
             :request_budget_exceeded,
             :token_budget_exceeded,
             :cost_budget_exceeded
           ] ->
        "The model budget refused this request. Review the budget before making a new request."

      reason when reason in [:request_already_dispatched, :request_outcome_unknown] ->
        "This request was already dispatched or its outcome is unknown. No automatic retry was made. Review saved recommendations and request history before a new request."

      :model_authentication_denied ->
        "The model provider rejected authentication. Review the credential reference and model access in Connections."

      :credential_unavailable ->
        "The configured credential reference is unavailable. Review it in Connections."

      :model_rate_limited ->
        "The model provider rate limited this request. No automatic retry was made."

      :claim_origin_change ->
        "The original report, citations and context must remain unchanged. Edit only current guidance and the human resolution."

      _ ->
        "Analysis could not complete. Review the selected inputs, model availability, consent and budget before starting a new request."
    end
  end

  attr :target, :any, required: true
  attr :generation, :string, required: true
  attr :reset_token, :integer, required: true
  attr :draft, :map, required: true
  attr :pins, :map, required: true
  attr :projects, :list, required: true
  attr :sources, :list, required: true
  attr :goals, :list, required: true
  attr :profile, :any, required: true
  attr :claims, :list, required: true
  attr :selected, :any, required: true
  attr :edit, :any, required: true
  attr :dirty, :boolean, required: true
  attr :pending, :any, required: true
  attr :error, :any, required: true
  attr :notice, :any, required: true
  attr :model_status, :map, required: true
  attr :open, :boolean, required: true

  def builder(assigns) do
    project = Enum.find(assigns.projects, &(&1["id"] == assigns.draft["project_id"]))

    assigns =
      assigns
      |> assign(:scoped_sources, scoped(assigns.sources, assigns.profile, project, "source_ids"))
      |> assign(:scoped_goals, scoped(assigns.goals, assigns.profile, project, "goal_ids"))
      |> assign(:saved, Enum.filter(assigns.claims, &analysis?/1))

    ~H"""
    <HarnessForgeWeb.Company.Guide.section
      name="analysis"
      title="Manual analysis · 2–4 selected sources"
      open={@open}
      target={@target}
      company_event_generation={@generation}
    >
      <div class="company-step company-analysis" id="company-analysis-step">
        <h3>Manual selected-source alternative</h3>
        <p>
          For a manually selected subset, choose 2–4 captured sources and one saved goal. Corpus analysis uses its own selected corpus and does not require these per-document assignments. Either path proposes guidance; your exact Evidence decision and a separate Company plan decision remain required.
        </p>
        <p id="company-analysis-availability" role="status">
          Configured model: {@model_status["model"] || "None selected"} · {@model_status[
            "availability"
          ] || "unavailable"} · {@model_status["reason"] || "configured"}. No automatic retry or alternative model is used.
        </p>
        <div :if={@error} id="company-analysis-error" class="notice error" role="alert" tabindex="-1">
          {@error}
        </div>
        <div
          :if={@notice}
          id="company-analysis-result"
          class="context-note"
          role="status"
          tabindex="-1"
        >
          {@notice}
        </div>
        <.form
          for={%{}}
          id="company-analysis-form"
          phx-change="company_analysis_change"
          phx-submit="company_analysis_start"
          phx-target={@target}
          phx-auto-recover="ignore"
          data-company-reset-token={@reset_token}
          class="stack"
        >
          <input type="hidden" name="company_event_generation" value={@generation} />
          <fieldset disabled={@pending != nil || @dirty} class="company-analysis-selection">
            <legend>Included scope</legend>
            <label for="company-analysis-project">Saved project</label>
            <select id="company-analysis-project" name="analysis[project_id]" required>
              <option value="" selected={@draft["project_id"] == ""}>Choose a saved project</option>
              <option
                :for={project <- @projects}
                value={project["id"]}
                selected={@draft["project_id"] == project["id"]}
              >
                {project["payload"]["name"]}
              </option>
            </select>
            <fieldset
              id="company-analysis-sources"
              class="company-choices"
              aria-describedby="company-analysis-coverage"
            >
              <legend>Manual selection · choose 2–4 captured sources</legend>
              <input type="hidden" name="analysis[source_ids][]" value="" />
              <p :if={@draft["project_id"] == ""}>Choose a project to see assigned sources.</p>
              <div
                :for={source <- @scoped_sources}
                :if={@draft["project_id"] != ""}
                class="company-analysis-source"
              >
                <label for={"company-analysis-source-" <> source["id"]} class="company-choice">
                  <input
                    id={"company-analysis-source-" <> source["id"]}
                    type="checkbox"
                    name="analysis[source_ids][]"
                    value={source["id"]}
                    checked={source["id"] in @draft["source_ids"]}
                    disabled={!current_source?(source)}
                  />
                  <span><strong>{source["title"]}</strong><small>{source_freshness(source, @pins)}</small></span>
                </label>
                <p :if={source["latest_revision"]} class="field-help">
                  Revision <code>{source["latest_revision"]["id"]}</code>
                  · captured {source["latest_revision"]["captured_at"] || "date unavailable"} · source last updated {source[
                    "latest_revision"
                  ]["source_updated_at"] || "unknown"}
                </p>
                <a
                  :if={source_url(source)}
                  id={"company-analysis-source-link-" <> source["id"]}
                  href={source_url(source)}
                  target="_blank"
                  rel="noopener noreferrer"
                >Open stored source link (opens in a new tab)</a>
                <p :if={!source_url(source)} class="field-help">Source link unavailable.</p>
              </div>
            </fieldset>
            <p id="company-analysis-coverage" class="field-help">
              For this manual analysis, only checked sources are included. Unchecked, unassigned and uncaptured material is excluded; completeness and current policy are unknown. Capture dates do not establish policy chronology.
            </p>
            <p class="field-help">
              Manual selection: {length(@draft["source_ids"])} selected · {length(@scoped_sources)} assigned sources · external freshness unverified.
            </p>
            <label for="company-analysis-goal">Saved future goal</label>
            <select id="company-analysis-goal" name="analysis[goal_id]" required>
              <option value="" selected={@draft["goal_id"] == ""}>Choose one assigned goal</option>
              <option
                :for={goal <- @scoped_goals}
                :if={@draft["project_id"] != ""}
                value={goal["id"]}
                selected={@draft["goal_id"] == goal["id"]}
              >
                {goal["title"]} · {goal["owner"]} · {goal["acceptance"]}
              </option>
            </select>
            <p :if={@pins[:goal_hash]} class="field-help">
              Pinned goal hash <code>{@pins.goal_hash}</code>
            </p>
            <div class="company-actions">
              <button
                id="company-analysis-start"
                class="button primary"
                type="submit"
                disabled={@pending != nil || @dirty}
              >Analyse selected context</button>
              <button
                id="company-analysis-clear"
                type="button"
                class="button secondary"
                phx-click="company_analysis_clear"
                phx-value-company_event_generation={@generation}
                phx-target={@target}
                disabled={@pending != nil || @dirty}
              >Clear selection</button>
            </div>
          </fieldset>
        </.form>
        <p :if={@pending} id="company-analysis-busy" role="status">
          Analysing the pinned sources and saved goal… Selection is locked for this request.
        </p>
        <details :if={@saved != []} id="company-analysis-saved" class="company-analysis-saved">
          <summary>Reopen saved recommendations ({length(@saved)})</summary>
          <div :for={claim <- @saved} class="company-record">
            <p>{claim["text"]}</p><p>
              {claim["status"]}{if claim["superseded"], do: " · has successor"}
            </p>
            <button
              id={"company-analysis-open-" <> claim["id"]}
              type="button"
              class="button secondary"
              phx-click="company_analysis_open"
              phx-value-company_event_generation={@generation}
              phx-value-id={claim["id"]}
              phx-value-revision_hash={claim["revision_hash"]}
              phx-target={@target}
              disabled={@pending != nil || @dirty}
            >Open exact recommendation</button>
          </div>
        </details>
        <article :if={@selected} id="company-analysis-review" tabindex="-1">
          <.report claim={@selected} id="company-analysis-original" goals={@goals} sources={@sources} />
          <.form
            for={%{}}
            id="company-analysis-edit-form"
            phx-change="company_analysis_edit_change"
            phx-submit="company_analysis_revise"
            phx-target={@target}
            phx-auto-recover="ignore"
            data-company-reset-token={@reset_token}
            class="stack"
          >
            <input type="hidden" name="company_event_generation" value={@generation} />
            <input type="hidden" name="analysis_edit[id]" value={@edit["id"]} />
            <input
              type="hidden"
              name="analysis_edit[expected_revision_hash]"
              value={@edit["expected_revision_hash"]}
            />
            <h4>Current guidance · save a separate proposed revision</h4>
            <div :for={field <- fields()} class="stack">
              <label for={"company-analysis-edit-" <> field}>{field_label(field)}</label>
              <textarea
                id={"company-analysis-edit-" <> field}
                name={"analysis_edit[#{field}]"}
                maxlength="1000"
                required
                aria-describedby="company-analysis-edit-help"
              >{@edit[field]}</textarea>
            </div>
            <label for="company-analysis-resolution">Human resolution {if resolution_required?(
                                                                            @selected
                                                                          ),
                                                                          do:
                                                                            "· required before approval",
                                                                          else: "· optional"}</label>
            <textarea
              id="company-analysis-resolution"
              name="analysis_edit[review_resolution]"
              maxlength="1000"
              required={resolution_required?(@selected)}
              aria-describedby="company-analysis-edit-help"
            >{@edit["review_resolution"]}</textarea>
            <p id="company-analysis-edit-help" class="field-help">
              Saving preserves the original report and citations and creates an unapproved successor. A human resolution records your judgment about uncertainty or conflict; it is not automated proof.
            </p>
            <p :if={@dirty} id="company-analysis-dirty" role="status">
              Unsaved edits. Save or discard before opening Evidence for an exact decision.
            </p>
            <div class="company-actions">
              <button
                id="company-analysis-save"
                type="submit"
                class="button primary"
                disabled={@selected["superseded"] || @pending != nil}
              >Save proposed guidance revision</button>
              <button
                id="company-analysis-discard"
                type="button"
                class="button secondary"
                phx-click="company_analysis_discard"
                phx-value-company_event_generation={@generation}
                phx-target={@target}
              >Discard guidance edits</button>
              <button
                id="company-analysis-evidence"
                type="button"
                class="button secondary"
                phx-click="company_navigate"
                phx-value-company_event_generation={@generation}
                phx-value-tab="evidence"
                phx-target={@target}
                disabled={@dirty}
              >Review exact revision in Evidence</button>
            </div>
          </.form>
        </article>
      </div>
    </HarnessForgeWeb.Company.Guide.section>
    """
  end

  attr :claim, :map, required: true
  attr :id, :string, required: true
  attr :goals, :list, default: []
  attr :sources, :list, default: []
  attr :source_refs, :any, default: nil

  def report(assigns) do
    basis = assigns.claim["basis"]

    count =
      basis["report"]["findings"]
      |> Enum.flat_map(& &1["citations"])
      |> Enum.map(& &1["source_id"])
      |> Enum.uniq()
      |> length()

    goal =
      Enum.find(
        assigns.goals,
        &(&1["id"] == basis["goal_id"] && Goals.content_hash(&1) == basis["goal_content_hash"])
      )

    assigns =
      assigns
      |> assign(:basis, basis)
      |> assign(:report, basis["report"])
      |> assign(:coverage, count)
      |> assign(:origin_refs, context_sources(assigns.claim, assigns.source_refs))
      |> assign(:goal, goal)

    ~H"""
    <div id={@id} class="company-analysis-report">
      <h4>Company analysis · history and saved future intent</h4>
      <p>Original recommendation status: <strong>{@report["recommendation"]["status"]}</strong></p>
      <p><strong>Uncertainty:</strong> {@report["uncertainty"]}</p>
      <p><strong>Goal rationale:</strong> {@report["recommendation"]["goal_rationale"]}</p>
      <p :if={@goal}>
        <strong>Saved goal:</strong> {@goal["title"]} · Owner: {@goal["owner"]} · Acceptance: {@goal[
          "acceptance"
        ]}
      </p>
      <p :if={!@goal} class="context-note">
        The pinned goal is unavailable or changed. Review current saved intent before deciding or building.
      </p>
      <p>
        Structural citation coverage: {@coverage} distinct sources. Exact excerpts establish provenance; they do not prove semantic truth or complete coverage.
      </p>
      <p :if={resolution_required?(@claim)} class="context-note">
        The original report declares uncertainty or conflict. Approval requires a saved human resolution, including when its status is supported.
      </p>
      <p :if={@basis["review_resolution"]}>
        <strong>Saved human resolution:</strong> {@basis["review_resolution"]}
      </p>
      <details open>
        <summary>Original findings and excerpts</summary>
        <article
          :for={{finding, index} <- Enum.with_index(@report["findings"])}
          id={@id <> "-finding-#{index}"}
          class="company-record"
        >
          <h5>{String.capitalize(finding["kind"])}</h5><p>{finding["statement"]}</p>
          <div
            :for={{citation, citation_index} <- Enum.with_index(finding["citations"])}
            id={@id <> "-finding-#{index}-excerpt-#{citation_index}"}
          >
            <blockquote>
              <p>{citation["snippet"]}</p><small>Source {citation["source_id"]} · revision {citation[
                "revision_id"
              ]} · UTF-8 bytes {citation["start_byte"]}–{citation["end_byte"]} (exclusive end)</small>
            </blockquote>
            <% metadata = citation_metadata(@claim, citation, @sources, @origin_refs) %>
            <div :if={metadata} class="company-analysis-capture">
              <p :if={metadata.title}>
                <strong>Current source name (may have changed):</strong> {metadata.title}
              </p>
              <p :if={!metadata.title}>Current source name unavailable.</p>
              <p :if={metadata.captured_at}>
                <strong>Captured at:</strong>
                <time datetime={metadata.captured_at}>{metadata.captured_at}</time>
              </p>
              <p :if={!metadata.captured_at}>Capture date unavailable.</p>
              <a
                :if={metadata.url}
                id={@id <> "-finding-#{index}-excerpt-#{citation_index}-source-link"}
                href={metadata.url}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={"Open stored source link (opens in a new tab), finding #{index + 1}, excerpt #{citation_index + 1}"}
                aria-describedby={@id <> "-finding-#{index}-excerpt-#{citation_index}-link-note"}
              >Open stored source link (opens in a new tab)</a>
              <p
                :if={metadata.url}
                id={@id <> "-finding-#{index}-excerpt-#{citation_index}-link-note"}
              >
                This link was stored with the capture. Its destination may have changed.
              </p>
              <p :if={!metadata.url}>Source link unavailable.</p>
            </div>
            <p :if={!metadata} class="context-note">
              Current capture details are not shown from the loaded metadata. The original excerpt and pin are retained; this display alone does not establish whether the capture changed.
            </p>
          </div>
        </article>
      </details>
      <details>
        <summary>Original recommendation, included context and attribution</summary>
        <p :for={field <- fields()}>
          <strong>{field_label(field)}:</strong> {@report["recommendation"][field]}
        </p>
        <p>Project <code>{@basis["project_id"]}</code> · goal <code>{@basis["goal_id"]}</code></p>
        <p>Pinned goal hash <code>{@basis["goal_content_hash"]}</code></p>
        <p :for={ref <- @origin_refs} :if={valid_source_ref?(ref)}>
          Included source <code>{ref["source_id"]}</code>
          · revision <code>{ref["revision_id"]}</code>
          · body hash <code>{ref["body_hash"]}</code>
        </p>
        <p>
          Provider {@basis["provider"]} · model {@basis["model"]}. Attribution does not grant approval.
        </p>
        <p>Exact claim revision <code>{@claim["revision_hash"]}</code></p>
      </details>
    </div>
    """
  end

  defp field_label("evaluation_criterion"), do: "Evaluation criterion"
  defp field_label(field), do: String.capitalize(field)

  @doc false
  def current_source?(source) when is_map(source) and not is_struct(source) do
    revision = source["latest_revision"]

    source["status"] == "active" and plain_map?(revision) and
      AnalysisOutput.uuid?(source["id"]) and AnalysisOutput.uuid?(revision["id"]) and
      revision["source_id"] == source["id"] and AnalysisOutput.digest?(revision["body_hash"]) and
      current_pointer?(source, revision) and captured_content?(source, revision)
  end

  def current_source?(_), do: false

  defp captured_content?(%{"eligible" => true} = source, revision),
    do:
      nonblank_text?(source["workspace_id"]) and
        source["workspace_id"] == revision["workspace_id"] and
        is_integer(revision["body_bytes"]) and revision["body_bytes"] > 0

  defp captured_content?(%{"eligible" => _}, _), do: false

  defp captured_content?(_, revision),
    do:
      is_binary(revision["body"]) and String.valid?(revision["body"]) and
        byte_size(revision["body"]) > 0

  defp current_pointer?(source, revision) do
    case Map.fetch(source, "latest_revision_id") do
      {:ok, id} -> id == revision["id"]
      :error -> source["eligible"] == true
    end
  end

  defp source_freshness(source, pins) do
    pin = get_in(pins, [:sources, source["id"]])

    cond do
      !current_source?(source) ->
        "Unavailable or uncaptured · excluded"

      pin &&
          (pin["revision_id"] != source["latest_revision"]["id"] ||
             pin["body_hash"] != source["latest_revision"]["body_hash"]) ->
        "Selected capture changed · clear and choose current inputs"

      pin ->
        "Pinned selected capture · current"

      true ->
        "Current captured revision · unchecked"
    end
  end

  # These checks establish correspondence with already-scoped caller data, not authorization.
  defp citation_metadata(claim, citation, sources, refs) do
    with true <- plain_map?(citation) and is_list(sources),
         true <- AnalysisOutput.uuid?(citation["source_id"]),
         true <- AnalysisOutput.uuid?(citation["revision_id"]),
         true <- Enum.all?(refs, &valid_source_ref?/1),
         ids = Enum.map(refs, & &1["source_id"]),
         true <- length(ids) == length(Enum.uniq(ids)),
         [ref] <- Enum.filter(refs, &(&1["source_id"] == citation["source_id"])),
         true <- ref["revision_id"] == citation["revision_id"],
         true <- Enum.all?(sources, &plain_map?/1),
         [source] <- Enum.filter(sources, &(&1["id"] == citation["source_id"])),
         true <- source["status"] == "active",
         revision = source["latest_revision"],
         true <- plain_map?(revision),
         true <- not Map.has_key?(source, "eligible") or current_source?(source),
         true <- revision["source_id"] == citation["source_id"],
         true <- current_pointer?(source, revision),
         true <- revision["id"] == citation["revision_id"],
         true <- AnalysisOutput.digest?(revision["body_hash"]),
         true <- ref["body_hash"] == revision["body_hash"],
         workspace = claim["workspace_id"],
         true <- nonblank_text?(workspace),
         true <- workspace == source["workspace_id"] and workspace == revision["workspace_id"] do
      %{
        title: if(nonblank_text?(source["title"]), do: source["title"]),
        captured_at: capture_date(revision["captured_at"]),
        url: safe_source_url(revision["source_url"])
      }
    else
      _ -> nil
    end
  end

  defp context_sources(%{"basis" => %{"version" => 2}}, refs) when is_list(refs), do: refs

  defp context_sources(%{"basis" => %{"context" => %{"sources" => refs}}}, _) when is_list(refs),
    do: refs

  defp context_sources(_, _), do: []

  defp valid_source_ref?(ref) when is_map(ref),
    do:
      plain_map?(ref) and AnalysisOutput.uuid?(ref["source_id"]) and
        AnalysisOutput.uuid?(ref["revision_id"]) and AnalysisOutput.digest?(ref["body_hash"])

  defp valid_source_ref?(_), do: false

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp nonblank_text?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, value)

  defp capture_date(value) do
    with true <- nonblank_text?(value),
         {:ok, _, _} <- DateTime.from_iso8601(value) do
      value
    else
      _ -> nil
    end
  end

  @doc false
  def source_url(%{"latest_revision" => %{"source_url" => url}}), do: safe_source_url(url)
  def source_url(_), do: nil

  # Navigation hygiene only: preserve admitted bytes and never fetch or repair a stored URL.
  defp safe_source_url(url) when is_binary(url) and byte_size(url) in 1..2048 do
    with true <- String.valid?(url),
         false <- Regex.match?(~r/[\p{Z}\p{Cc}\p{Cf}\s\\<>"`{}|^]/u, url),
         false <- Regex.match?(~r/%(?![0-9a-f]{2})/i, url),
         false <- Regex.match?(~r/%(?:0[0-9a-f]|1[0-9a-f]|7f|5c)/i, url),
         [authority] <- Regex.run(~r/\Ahttps?:\/\/([^\/?#]+)/i, url, capture: :all_but_first),
         true <- valid_authority?(authority),
         %URI{scheme: scheme, host: host, userinfo: nil} <- URI.parse(url),
         true <- String.downcase(scheme) in ["http", "https"] and is_binary(host) and host != "" do
      url
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_source_url(_), do: nil

  defp valid_authority?("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [host, suffix] ->
        with true <- Regex.match?(~r/\A[0-9a-f:.]+\z/i, host),
             {:ok, address} <- :inet.parse_address(String.to_charlist(host)) do
          tuple_size(address) == 8 and valid_port_suffix?(suffix)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_authority?(authority) do
    case String.split(authority, ":") do
      [host] -> valid_host?(host)
      [host, port] -> valid_host?(host) and valid_port?(port)
      _ -> false
    end
  end

  defp valid_port_suffix?(""), do: true
  defp valid_port_suffix?(":" <> port), do: valid_port?(port)
  defp valid_port_suffix?(_), do: false

  defp valid_port?(port),
    do: Regex.match?(~r/\A[0-9]+\z/, port) and String.to_integer(port) in 1..65535

  defp valid_host?(host) do
    if Regex.match?(~r/\A[0-9.]+\z/, host) do
      Regex.match?(~r/\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z/, host) and
        Enum.all?(String.split(host, "."), &(String.to_integer(&1) <= 255))
    else
      dns =
        if String.ends_with?(host, "."), do: binary_part(host, 0, byte_size(host) - 1), else: host

      labels = String.split(dns, ".")

      byte_size(dns) in 1..253 and
        Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i, &1)) and
        not Regex.match?(~r/\A(?:[0-9]+|0x[0-9a-f]+)\z/i, List.last(labels))
    end
  end
end

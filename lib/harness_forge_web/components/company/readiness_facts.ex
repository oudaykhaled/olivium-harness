defmodule HarnessForgeWeb.Company.ReadinessFacts do
  @moduledoc "Independent evidence facts; no overall completion or release score."
  use HarnessForgeWeb, :html

  @facts [
    {"capture", "Source capture"},
    {"understanding", "Company understanding"},
    {"review", "Exact review"},
    {"candidate", "Harness candidate"},
    {"evaluation", "Task evaluation"},
    {"release", "Release"}
  ]
  @statuses %{
    "unknown" => "Unknown",
    "not_started" => "Not started",
    "running" => "Running",
    "needs_input" => "Needs input",
    "complete_for_selected_scope" => "Recorded for selected scope",
    "blocked" => "Blocked",
    "cancelled" => "Cancelled",
    "stale" => "Stale"
  }
  @reasons %{
    "not_observed" => "No observation is available.",
    "backing_record_unavailable" => "The supporting record is unavailable.",
    "scope_selection_required" => "Choose a saved scope first.",
    "scope_binding_unavailable" => "Exact record bindings are unavailable.",
    "stale_generation" => "The selected source generation changed.",
    "stale_declaration" => "The saved source coverage declaration changed.",
    "declared_scope_verified" =>
      "Required captured scope was checked; optional omissions are listed below.",
    "required_scope_incomplete" => "Required source coverage is incomplete.",
    "declared_scope_unknown" => "The declared source coverage cannot be established.",
    "undeclared_members" => "Some captured members are outside the declared connections.",
    "superseded_revision" => "A newer plan version supersedes this revision.",
    "scope_mismatch" => "The observation belongs to another scope.",
    "invalid_metadata" => "The observation could not be verified.",
    "missing_required_pins" => "Required revision or generation bindings are missing.",
    "capture_verified" => "Capture was verified for the selected scope.",
    "capture_incomplete" => "Some selected sources remain uncaptured.",
    "capture_running" => "Source capture is running.",
    "capture_cancelled" => "Source capture was cancelled.",
    "analysis_running" => "Company analysis is running.",
    "analysis_proposed" => "Analysis produced proposed guidance for review.",
    "analysis_abstained" => "Analysis abstained; more evidence or clarification is needed.",
    "analysis_failed" => "Analysis failed; understanding has not been established.",
    "analysis_unavailable" => "The analysis outcome is unavailable.",
    "exact_review_required" => "Review the exact claim and plan separately.",
    "exact_review_verified" => "Exact claim and plan decisions were checked.",
    "artifact_verified" => "The candidate artifact and plan binding were checked.",
    "artifact_binding_unavailable" => "The candidate's exact plan binding is unavailable.",
    "qualification_missing" => "Required qualification is missing.",
    "evaluation_not_selected" => "No exact evaluation is selected.",
    "evaluation_recorded" =>
      "An evaluation was recorded; its evidence kind limits what it establishes.",
    "release_not_observed" => "No actual release receipt was observed.",
    "release_verified" => "An exact release receipt was checked.",
    "optional_source_unavailable" => "This explicitly optional source scope is unavailable.",
    "graph_unavailable" => "Graph retrieval is unavailable.",
    "fts_available" => "Full-text retrieval is available."
  }

  attr :data, :map, required: true
  attr :id, :string, default: "company-readiness"

  def panel(assigns) do
    assigns = assign(assigns, :facts, @facts)

    ~H"""
    <section id={@id} aria-labelledby={@id <> "-title"}>
      <h3 id={@id <> "-title"}>Evidence and readiness</h3>
      <p>
        Each state applies only to its selected saved scope. Recorded analysis does not establish effectiveness; a built candidate does not establish release.
      </p>
      <dl>
        <div
          :for={{name, title} <- @facts}
          id={@id <> "-" <> name}
          data-status={@data["facts"][name]["status"]}
        >
          <dt>{title}</dt>
          <dd>
            <strong>{status(@data["facts"][name]["status"])}</strong>
            <span data-reason-code={@data["facts"][name]["reason_code"]}>{reason(
              @data["facts"][name]["reason_code"]
            )}</span>
            <small :if={@data["facts"][name]["evidence_kind"] == "current_session"}>Current session observation; not a persisted history.</small>
          </dd>
        </div>
      </dl>
      <p :for={omission <- @data["omissions"]} data-optional-omission={omission["connector_id"]}>
        Optional source omitted: <strong>{omission["connector_name"] || omission["connector_id"]}</strong>. {reason(
          omission["reason_code"]
        )}
      </p>
      <details id={@id <> "-details"}>
        <summary>View checked scope, records and retrieval availability</summary>
        <p :if={@data["observed_at"]}>Observed at {@data["observed_at"]}.</p>
        <dl>
          <div :for={{key, value} <- Enum.sort(@data["scope"])}>
            <dt>{key}</dt><dd><code>{value}</code></dd>
          </div>
        </dl>
        <p :for={name <- ~w(fts graph)}>
          {capability(name)}: {@data["capabilities"][name]["status"]}. {reason(
            @data["capabilities"][name]["reason_code"]
          )}
        </p>
        <div :for={{name, title} <- @facts}>
          <h4>{title}</h4>
          <p>Evidence kind: {@data["facts"][name]["evidence_kind"]}.</p>
          <dl>
            <div :for={{key, value} <- Enum.sort(@data["facts"][name]["pins"])}>
              <dt>{key}</dt><dd><code>{value}</code></dd>
            </div>
          </dl>
          <ul :if={@data["facts"][name]["references"] != []}>
            <li :for={ref <- @data["facts"][name]["references"]}>
              {ref["kind"]}:
              <code>{ref["id"]}</code><span :if={ref["digest"]}> · digest <code>{ref["digest"]}</code></span><span :if={
                ref["revision"]
              }> · revision <code>{ref["revision"]}</code></span>
            </li>
          </ul>
        </div>
      </details>
    </section>
    """
  end

  defp status(code), do: Map.get(@statuses, code, "Unknown")
  defp reason(code), do: Map.get(@reasons, code, "The observation could not be verified.")
  defp capability("fts"), do: "Full-text retrieval"
  defp capability("graph"), do: "Graph retrieval"
end

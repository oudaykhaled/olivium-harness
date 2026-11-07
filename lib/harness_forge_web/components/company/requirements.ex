defmodule HarnessForgeWeb.Company.Requirements do
  @moduledoc "Presentation of explicitly saved, checked connection coverage metadata."
  use HarnessForgeWeb, :html

  attr :state, :map, required: true
  attr :pipeline, :map, required: true
  attr :generation, :string, required: true

  def panel(assigns) do
    assigns =
      assigns
      |> assign(:saved, assigns.pipeline[:declaration])
      |> assign(:context, assigns.pipeline[:requirements_context])
      |> assign(:draft, assigns.pipeline[:requirements_draft] || %{})
      |> assign(:choices, assigns.pipeline[:requirements_choices] || %{"rows" => []})
      |> assign(:connections, get_in(assigns.state, [:choices, :connections, "rows"]) || [])

    ~H"""
    <details id="corpus-requirements" class="corpus-card" open={!is_nil(@saved) || !is_nil(@context)}>
      <summary>Declare required and optional source coverage</summary>
      <p id="corpus-requirements-help">
        The selected primary connection is required. You may declare one additional connection optional
        using an explicitly selected recorded capture. Saving classifies captured scope; semantic
        sufficiency remains unknown. It starts no capture and grants no consent or approval.
      </p>
      <div :if={@saved} id="corpus-requirements-saved" tabindex="-1" role="status">
        <h3>Saved selected coverage</h3>
        <p>Required captured scope: {@saved["required_status"]}. Semantic sufficiency: unknown.</p>
        <p :for={entry <- @saved["entries"]}>
          <strong>{entry["name"]}</strong> · {entry["requirement"]} · {entry["state"]}
          <span :if={entry["reason_code"]}> · {entry["reason_code"]}</span>
        </p>
        <p :for={omission <- @saved["omissions"]}>
          Optional scope omitted: {omission_name(@saved, omission)} · {omission["reason_code"]}.
        </p>
        <p :if={@saved["undeclared_members"] != 0}>
          Undeclared captured members: {@saved["undeclared_members"]}. They are outside this declared scope.
        </p>
        <button
          type="button"
          class="button secondary"
          phx-click="corpus_requirements_refresh"
          phx-value-corpus_generation={@generation}
          disabled={@pipeline.busy}
        >Refresh saved coverage</button>
        <details>
          <summary>Saved coverage references</summary>
          <p>
            Declaration <code>{@saved["id"]}</code>
            · revision {@saved["revision"]} · digest <code>{@saved["digest"]}</code>.
          </p>
        </details>
      </div>
      <p
        :if={@pipeline[:requirements_read_only]}
        id="corpus-requirements-read-only"
        class="field-help"
      >
        This saved declaration includes additional scopes and is read-only in this editor. All declared scopes remain included.
      </p>
      <p :if={!@pipeline.capture} class="field-help">
        Capture the selected primary directory above before saving coverage. A saved declaration can
        be reopened using its exact saved address.
      </p>
      <button
        id="corpus-requirements-begin"
        type="button"
        class="button secondary"
        phx-click="corpus_requirements_begin"
        phx-value-corpus_generation={@generation}
        disabled={@pipeline.busy || !@pipeline.capture || @pipeline[:requirements_read_only]}
      >Load current coverage choices</button>
      <.form
        :if={@context && !@pipeline[:requirements_read_only]}
        for={%{}}
        id="corpus-requirements-form"
        phx-change="corpus_requirements_change"
        phx-submit="corpus_requirements_save"
        phx-auto-recover="ignore"
        class="stack"
        aria-describedby="corpus-requirements-help"
      >
        <input type="hidden" name="corpus_generation" value={@generation} />
        <p>Required: {@state.scope["connection"]["name"]}.</p>
        <label for="corpus-requirements-optional">Optional additional connection</label>
        <select
          id="corpus-requirements-optional"
          name="requirements[optional_connection_id]"
          disabled={@pipeline.busy}
        >
          <option value="" selected={@draft["optional_connection_id"] in [nil, ""]}>
            No optional connection declared
          </option>
          <option
            :if={off_page(@choices["connection"], @connections)}
            value={@choices["connection"]["id"]}
            selected={@draft["optional_connection_id"] == @choices["connection"]["id"]}
          >
            {@choices["connection"]["title"]} · selected outside this page
          </option>
          <option
            :for={c <- @connections}
            :if={c["id"] != @state.selection["connection_id"]}
            value={c["id"]}
            selected={@draft["optional_connection_id"] == c["id"]}
          >
            {c["title"]}
          </option>
        </select>
        <button
          :if={get_in(@state, [:choices, :connections, "next_cursor"])}
          type="button"
          class="button secondary"
          phx-click="corpus_choices_next"
          phx-value-kind="connection"
          phx-value-corpus_generation={@generation}
          disabled={@pipeline.busy}
        >More connections</button>
        <label for="corpus-requirements-capture">Recorded optional capture</label>
        <input
          :if={@draft["optional_connection_id"] in [nil, ""]}
          type="hidden"
          name="requirements[capture_run_id]"
          value=""
        />
        <select
          id="corpus-requirements-capture"
          name="requirements[capture_run_id]"
          disabled={@pipeline.busy || @draft["optional_connection_id"] in [nil, ""]}
        >
          <option value="" selected={@draft["capture_run_id"] in [nil, ""]}>
            Choose a recorded capture when declaring optional scope
          </option>
          <option
            :if={off_page(@choices["selected"], @choices["rows"])}
            value={@choices["selected"]["id"]}
            selected={@draft["capture_run_id"] == @choices["selected"]["id"]}
          >
            {capture_label(@choices["selected"])} · selected outside this page
          </option>
          <option
            :for={c <- @choices["rows"]}
            value={c["id"]}
            selected={@draft["capture_run_id"] == c["id"]}
          >
            {capture_label(c)}
          </option>
        </select>
        <p
          :if={@draft["optional_connection_id"] not in [nil, ""] && @choices["rows"] == []}
          class="field-help"
        >
          No recorded captures on this page. Missing outcomes cannot establish an optional omission.
        </p>
        <button
          :if={@choices["next_cursor"]}
          id="corpus-requirements-next"
          type="button"
          class="button secondary"
          phx-click="corpus_requirements_next"
          phx-value-corpus_generation={@generation}
          disabled={@pipeline.busy}
        >More recorded captures</button>
        <button
          id="corpus-requirements-save"
          type="submit"
          class="button primary"
          disabled={@pipeline.busy || !@pipeline.capture}
        >Save coverage declaration</button>
      </.form>
    </details>
    """
  end

  defp off_page(nil, _), do: false
  defp off_page(selected, rows), do: !Enum.any?(rows, &(&1["id"] == selected["id"]))

  defp capture_label(c),
    do:
      "#{c["state"] || "unknown"} · #{c["inserted_at"] || "recorded time unavailable"} · revision #{c["revision"]}"

  defp omission_name(saved, omission) do
    case Enum.find(saved["entries"], &(&1["connection_id"] == omission["connector_id"])) do
      %{"name" => name} -> name
      _ -> "Unavailable connection"
    end
  end
end

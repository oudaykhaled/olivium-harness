defmodule HarnessForgeWeb.Company.Catalog do
  @moduledoc false
  use HarnessForgeWeb, :html
  alias HarnessForgeWeb.Company.Guide

  attr :target, :any, required: true
  attr :company_event_generation, :string, required: true
  attr :profile, :any, required: true
  attr :sources, :list, required: true
  attr :catalog_sources, :any, default: nil
  attr :source_selected_options, :list, default: []
  attr :goals, :list, required: true
  attr :repositories, :list, required: true
  attr :projects, :list, required: true
  attr :repository_edit, :any, required: true
  attr :project_edit, :any, required: true
  attr :capability_query, :string, required: true
  attr :capability_results, :any, required: true
  attr :consumer_repository, :any, required: true
  attr :consumer_results, :any, required: true
  attr :profile_draft, :any, default: nil
  attr :repository_draft, :any, default: nil
  attr :project_draft, :any, default: nil
  attr :open_sections, :any, required: true
  attr :form_error, :any, default: nil
  attr :company_reset_token, :integer, required: true

  def setup(assigns) do
    assigns =
      assigns
      |> assign(:profile_values, assigns.profile_draft || payload(assigns.profile))
      |> assign(:repository_values, assigns.repository_draft || payload(assigns.repository_edit))
      |> assign(:project_values, assigns.project_draft || payload(assigns.project_edit))
      |> assign(:source_choices, assigns.catalog_sources || assigns.sources)

    ~H"""
    <Guide.section
      name="profile"
      title="1. Company profile"
      open={MapSet.member?(@open_sections, "profile")}
      target={@target}
      company_event_generation={@company_event_generation}
    >
      <div class="company-step" id="company-profile-step">
        <h3>Describe your company</h3>
        <p>
          Save the name and context you choose. Assigned sources and goals describe where context applies; they do not approve any rule.
        </p>
        <.form
          for={%{}}
          id="company-profile-form"
          data-company-reset-token={@company_reset_token}
          phx-change="company_profile_change"
          phx-submit="company_profile_save"
          phx-target={@target}
          class="stack"
        >
          <input type="hidden" name="company_event_generation" value={@company_event_generation} />
          <.form_error section="profile" error={@form_error} />
          <p :if={@profile_draft != nil} class="company-draft-note">Unsaved profile changes</p>
          <input
            :if={@profile}
            id="company-profile-hash"
            type="hidden"
            name="profile[expected_content_hash]"
            value={expected_hash(@profile_draft, @profile)}
          />
          <label for="company-profile-name">Company name</label>
          <input
            id="company-profile-name"
            name="profile[name]"
            value={@profile_values["name"]}
            required
            maxlength="256"
          />
          <label for="company-profile-description">Company description</label>
          <textarea
            id="company-profile-description"
            name="profile[description]"
            maxlength="4096"
            rows="3"
          >{@profile_values["description"]}</textarea>
          <.choices
            id="company-profile-sources"
            name="profile[source_ids][]"
            label="Company-wide captured sources"
            options={source_options(@source_choices)}
            selected_options={@source_selected_options}
            selected={@profile_values["source_ids"] || []}
            empty="No captured sources yet."
          />
          <button
            :if={@sources == []}
            id="company-connect-sources"
            type="button"
            phx-click="company_navigate"
            phx-value-company_event_generation={@company_event_generation}
            phx-value-tab="connections"
            phx-target={@target}
            class="button secondary"
          >Connect and capture sources</button>
          <.choices
            id="company-profile-goals"
            name="profile[goal_ids][]"
            label="Company-wide goals · optional future intent"
            options={goal_options(@goals)}
            selected={@profile_values["goal_ids"] || []}
            empty="No goals saved yet."
          />
          <button
            :if={@goals == []}
            id="company-add-goals"
            type="button"
            phx-click="company_navigate"
            phx-value-company_event_generation={@company_event_generation}
            phx-value-tab="goals"
            phx-target={@target}
            class="button secondary"
          >Add optional goals</button>
          <div class="company-actions">
            <button id="company-profile-save" type="submit" class="button primary">Save company profile</button>
            <.discard
              :if={@profile_draft != nil}
              form="profile"
              target={@target}
              company_event_generation={@company_event_generation}
            />
          </div>
        </.form>
      </div>
    </Guide.section>

    <Guide.section
      name="repository"
      title="2. Repositories and services"
      open={MapSet.member?(@open_sections, "repository")}
      target={@target}
      company_event_generation={@company_event_generation}
    >
      <div class="company-step" id="company-catalog-step">
        <h3>Build a reusable service catalogue</h3>
        <p>
          Record known capabilities and dependencies. A declared dependency is not a runtime compatibility check.
        </p>
        <p :if={@repositories == []} id="company-repositories-empty" class="context-note">
          No repositories saved. Add a repository or service before creating a project.
        </p>
        <div class="company-records">
          <article
            :for={repo <- @repositories}
            id={"company-repository-#{repo["id"]}"}
            class="company-record"
          >
            <h3>{repo["payload"]["name"]}</h3><code>{repo["payload"]["identity"]}</code>
            <p>{repo["payload"]["purpose"]}</p>
            <p class="field-help">
              Owner: {repo["payload"]["owner"]} · Capabilities: {Enum.join(
                repo["payload"]["capabilities"],
                ", "
              )}
            </p>
            <p class="field-help">
              Declared dependencies: {repository_names(
                repo["payload"]["dependency_ids"],
                @repositories
              )}
            </p>
            <div class="company-actions">
              <button
                id={"company-repository-edit-#{repo["id"]}"}
                phx-click="company_repository_edit"
                phx-value-company_event_generation={@company_event_generation}
                phx-value-id={repo["id"]}
                phx-target={@target}
                class="button secondary"
              >Edit {repo["payload"]["name"]}</button>
              <button
                id={"company-consumers-#{repo["id"]}"}
                phx-click="company_consumers"
                phx-value-company_event_generation={@company_event_generation}
                phx-value-id={repo["id"]}
                phx-target={@target}
                class="button secondary"
              >Find consumers</button>
            </div>
          </article>
        </div>
        <.form
          for={%{}}
          id="company-repository-form"
          data-company-reset-token={@company_reset_token}
          phx-change="company_repository_change"
          phx-submit="company_repository_save"
          phx-target={@target}
          class="stack"
        >
          <input type="hidden" name="company_event_generation" value={@company_event_generation} />
          <.form_error section="repository" error={@form_error} />
          <h3>{if @repository_edit, do: "Edit repository", else: "Add a repository or service"}</h3>
          <p :if={@repository_draft != nil} class="company-draft-note">
            Unsaved repository changes · discard before switching records
          </p>
          <input
            :if={@repository_edit}
            id="company-repository-id"
            type="hidden"
            name="repository[id]"
            value={@repository_edit["id"]}
          />
          <input
            :if={@repository_edit}
            id="company-repository-hash"
            type="hidden"
            name="repository[expected_content_hash]"
            value={expected_hash(@repository_draft, @repository_edit)}
          />
          <label for="company-repository-identity">Repository identity</label><input
            id="company-repository-identity"
            name="repository[identity]"
            value={@repository_values["identity"]}
            placeholder="example/payments"
            required
            maxlength="256"
          />
          <p class="field-help">
            Use a stable owner/name identity. Local paths, credentials and URLs are not repository identities.
          </p>
          <label for="company-repository-name">Repository or service name</label><input
            id="company-repository-name"
            name="repository[name]"
            value={@repository_values["name"]}
            required
            maxlength="256"
          />
          <label for="company-repository-purpose">Purpose</label><textarea
            id="company-repository-purpose"
            name="repository[purpose]"
            required
            maxlength="4096"
          >{@repository_values["purpose"]}</textarea>
          <label for="company-repository-owner">Owner</label><input
            id="company-repository-owner"
            name="repository[owner]"
            value={@repository_values["owner"]}
            required
            maxlength="256"
          />
          <label for="company-repository-capabilities">Capabilities · one per line</label><textarea
            id="company-repository-capabilities"
            name="repository[capabilities_text]"
            maxlength="16384"
            rows="3"
          >{text_lines(@repository_values, "capabilities_text", "capabilities")}</textarea>
          <label for="company-repository-interfaces">Interfaces · one per line</label><textarea
            id="company-repository-interfaces"
            name="repository[interfaces_text]"
            maxlength="16384"
          >{text_lines(@repository_values, "interfaces_text", "interfaces")}</textarea>
          <label for="company-repository-version">Version strategy</label><input
            id="company-repository-version"
            name="repository[version_strategy]"
            value={@repository_values["version_strategy"]}
            maxlength="4096"
            placeholder="For example, semantic versions"
          />
          <label for="company-repository-examples">Usage examples · one per line</label><textarea
            id="company-repository-examples"
            name="repository[examples_text]"
            maxlength="16384"
          >{text_lines(@repository_values, "examples_text", "examples")}</textarea>
          <.choices
            id="company-repository-dependencies"
            name="repository[dependency_ids][]"
            label="Declared dependencies"
            options={
              repository_options(
                Enum.reject(@repositories, &(@repository_edit && &1["id"] == @repository_edit["id"]))
              )
            }
            selected={@repository_values["dependency_ids"] || []}
            empty="No other repositories available."
          />
          <div class="company-actions">
            <button id="company-repository-save" type="submit" class="button primary">Save repository</button>
            <button
              :if={@repository_edit}
              id="company-repository-new"
              type="button"
              phx-click="company_repository_new"
              phx-value-company_event_generation={@company_event_generation}
              phx-target={@target}
              class="button secondary"
            >Add another repository</button>
            <.discard
              :if={@repository_draft != nil}
              form="repository"
              target={@target}
              company_event_generation={@company_event_generation}
            />
          </div>
        </.form>
        <div class="company-lookup">
          <h3>Find capabilities and consumers</h3>
          <p class="field-help">
            Search the saved catalogue using a few words, up to 256 characters. Results are bounded text matches; no model is called.
          </p>
          <.form
            for={%{}}
            id="company-capability-form"
            data-company-reset-token={@company_reset_token}
            phx-submit="company_capability_search"
            phx-target={@target}
            class="stack"
          >
            <input type="hidden" name="company_event_generation" value={@company_event_generation} />
            <label for="company-capability-query">Capability search</label><input
              id="company-capability-query"
              name="capability[query]"
              value={@capability_query}
              required
              maxlength="256"
              placeholder="For example, payments"
            />
            <button id="company-capability-search" type="submit" class="button secondary">Search saved capabilities</button>
          </.form>
          <div :if={@capability_results != nil} id="company-capability-results" role="status">
            <p :if={@capability_results == []}>No matching capabilities in this saved catalogue.</p>
            <p :for={repo <- @capability_results}>
              {repo["payload"]["name"]} · {Enum.join(repo["payload"]["capabilities"], ", ")}
            </p>
          </div>
          <div :if={@consumer_results != nil} id="company-consumer-results" role="status">
            <h4>Consumers of {repository_names([@consumer_repository], @repositories)}</h4>
            <p :if={@consumer_results == []}>No declared consumers found.</p>
            <p :for={repo <- @consumer_results}>
              {repo["payload"]["name"]} · {repo["payload"]["identity"]}
            </p>
            <p class="field-help">
              Direct declared dependencies only. Cycles do not imply verified compatibility.
            </p>
          </div>
        </div>
      </div>
    </Guide.section>

    <Guide.section
      name="project"
      title="3. Project membership"
      open={MapSet.member?(@open_sections, "project")}
      target={@target}
      company_event_generation={@company_event_generation}
    >
      <div class="company-step" id="company-project-step">
        <h3>Choose each project's context</h3>
        <p>
          A project includes only the repositories, captured sources and goals you select. Company-wide source and goal assignments also apply.
        </p>
        <p :if={@projects == []} id="company-projects-empty" class="context-note">
          No projects saved. Add a project and explicitly select at least one repository.
        </p>
        <article
          :for={project <- @projects}
          id={"company-project-#{project["id"]}"}
          class="company-record"
        >
          <h3>{project["payload"]["name"]}</h3><p>{project["payload"]["description"]}</p>
          <p class="field-help">
            Repositories: {repository_names(project["payload"]["repository_ids"], @repositories)}
          </p>
          <p class="field-help">
            {length(project["payload"]["source_ids"])} assigned sources · {length(
              project["payload"]["goal_ids"]
            )} assigned goals
          </p>
          <button
            id={"company-project-edit-#{project["id"]}"}
            phx-click="company_project_edit"
            phx-value-company_event_generation={@company_event_generation}
            phx-value-id={project["id"]}
            phx-target={@target}
            class="button secondary"
          >Edit {project["payload"]["name"]}</button>
        </article>
        <.form
          for={%{}}
          id="company-project-form"
          data-company-reset-token={@company_reset_token}
          phx-change="company_project_change"
          phx-submit="company_project_save"
          phx-target={@target}
          class="stack"
        >
          <input type="hidden" name="company_event_generation" value={@company_event_generation} />
          <.form_error section="project" error={@form_error} />
          <h3>{if @project_edit, do: "Edit project", else: "Add a project"}</h3>
          <p :if={@project_draft != nil} class="company-draft-note">
            Unsaved project changes · discard before switching records
          </p>
          <input
            :if={@project_edit}
            id="company-project-id"
            type="hidden"
            name="project[id]"
            value={@project_edit["id"]}
          />
          <input
            :if={@project_edit}
            id="company-project-hash"
            type="hidden"
            name="project[expected_content_hash]"
            value={expected_hash(@project_draft, @project_edit)}
          />
          <label for="company-project-name">Project name</label><input
            id="company-project-name"
            name="project[name]"
            value={@project_values["name"]}
            required
            maxlength="256"
          />
          <label for="company-project-description">Project description</label><textarea
            id="company-project-description"
            name="project[description]"
            maxlength="4096"
          >{@project_values["description"]}</textarea>
          <.choices
            id="company-project-repositories"
            name="project[repository_ids][]"
            label="Repositories in this project · select at least one"
            options={repository_options(@repositories)}
            selected={@project_values["repository_ids"] || []}
            empty="Save a repository above first."
          />
          <.choices
            id="company-project-sources"
            name="project[source_ids][]"
            label="Captured sources assigned to this project"
            options={source_options(@source_choices)}
            selected_options={@source_selected_options}
            selected={@project_values["source_ids"] || []}
            empty="Capture sources in Connections before assigning them."
          />
          <.choices
            id="company-project-goals"
            name="project[goal_ids][]"
            label="Goals assigned to this project · optional future intent"
            options={goal_options(@goals)}
            selected={@project_values["goal_ids"] || []}
            empty="Save goals in Goals before assigning them."
          />
          <div class="company-actions">
            <button
              id="company-project-save"
              type="submit"
              class="button primary"
              disabled={@repositories == []}
            >Save project</button>
            <button
              :if={@project_edit}
              id="company-project-new"
              type="button"
              phx-click="company_project_new"
              phx-value-company_event_generation={@company_event_generation}
              phx-target={@target}
              class="button secondary"
            >Add another project</button>
            <.discard
              :if={@project_draft != nil}
              form="project"
              target={@target}
              company_event_generation={@company_event_generation}
            />
          </div>
        </.form>
      </div>
    </Guide.section>
    """
  end

  attr :section, :string, required: true
  attr :error, :any, default: nil

  def form_error(assigns) do
    ~H"""
    <div
      :if={@error && @error.section == @section}
      id={"company-#{@section}-error"}
      class="form-error company-form-error"
      tabindex="-1"
      role="alert"
    >
      <strong>Action needs attention</strong>
      <p>{@error.message}</p>
    </div>
    """
  end

  attr :form, :string, required: true
  attr :target, :any, required: true
  attr :company_event_generation, :string, required: true

  def discard(assigns) do
    ~H"""
    <button
      id={"company-#{@form}-discard"}
      type="button"
      phx-click="company_draft_discard"
      phx-value-company_event_generation={@company_event_generation}
      phx-value-form={@form}
      phx-target={@target}
      class="button secondary"
    >Discard {@form} changes</button>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :selected, :list, default: []
  attr :selected_options, :list, default: []
  attr :empty, :string, default: "No options available."

  def choices(assigns) do
    visible = MapSet.new(Enum.map(assigns.options, & &1.value))

    retained =
      assigns.selected
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(visible, &1))
      |> Enum.map(fn id ->
        Enum.find(assigns.selected_options, &(&1.value == id)) ||
          %{key: id, value: id, label: "Unavailable saved selection", detail: id}
      end)

    assigns = assign(assigns, :retained_options, retained)

    ~H"""
    <fieldset id={@id} class="company-choices">
      <legend>{@label}</legend>
      <input id={@id <> "-empty"} type="hidden" name={@name} value="" />
      <p :if={@options == []} class="field-help">{@empty}</p>
      <label :for={option <- @options} for={@id <> "-" <> option.key} class="company-choice">
        <input
          id={@id <> "-" <> option.key}
          type="checkbox"
          name={@name}
          value={option.value}
          checked={option.value in @selected}
        />
        <span><strong>{option.label}</strong><small :if={option[:detail]}>{option.detail}</small></span>
      </label>
      <div :if={@retained_options != []} class="company-retained-choices">
        <p class="field-help">
          Saved selections outside this page or currently unavailable. Keep checked to preserve; uncheck only to remove that selection.
        </p>
        <label
          :for={option <- @retained_options}
          for={@id <> "-" <> option.key}
          class="company-choice"
        >
          <input
            id={@id <> "-" <> option.key}
            type="checkbox"
            name={@name}
            value={option.value}
            checked
          />
          <span><strong>{option.label}</strong><small :if={option[:detail]}>{option.detail}</small></span>
        </label>
      </div>
    </fieldset>
    """
  end

  def source_options(sources),
    do:
      Enum.map(
        sources,
        &%{
          key: &1["id"],
          value: &1["id"],
          label: &1["title"],
          detail:
            if(&1["eligible"] == false || &1["status"] != "active",
              do: "Unavailable captured source · " <> &1["id"],
              else: "Captured source · " <> &1["id"]
            )
        }
      )

  def goal_options(goals),
    do:
      Enum.map(
        goals,
        &%{
          key: &1["id"],
          value: &1["id"],
          label: &1["title"],
          detail: "Owner: " <> &1["owner"] <> " · " <> &1["acceptance"]
        }
      )

  def repository_options(repositories),
    do:
      Enum.map(
        repositories,
        &%{
          key: &1["id"],
          value: &1["id"],
          label: &1["payload"]["name"],
          detail: &1["payload"]["identity"]
        }
      )

  def repository_names(ids, repositories),
    do:
      Enum.map_join(ids, ", ", fn id ->
        case Enum.find(repositories, &(&1["id"] == id)) do
          nil -> "Unavailable repository"
          repo -> repo["payload"]["name"]
        end
      end)
      |> empty_label()

  defp empty_label(""), do: "None selected"
  defp empty_label(value), do: value
  defp payload(nil), do: %{}
  defp payload(record), do: record["payload"]

  defp expected_hash(draft, record),
    do: (draft && draft["expected_content_hash"]) || (record && record["content_hash"])

  defp text_lines(values, text_key, list_key),
    do: Map.get(values, text_key, join_lines(values[list_key]))

  defp join_lines(nil), do: ""
  defp join_lines(values), do: Enum.join(values, "\n")
end

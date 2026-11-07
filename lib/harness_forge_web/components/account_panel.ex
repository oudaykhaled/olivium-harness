defmodule HarnessForgeWeb.AccountPanel do
  @moduledoc "Explicit native-application account verification, separate from captured source scopes."
  use HarnessForgeWeb, :html

  attr :catalog, :list, required: true
  attr :service, :string, required: true
  attr :pending, :any, required: true
  attr :available_github_refs, :list, required: true

  def accounts(assigns) do
    ~H"""
    <div id="live-accounts-panel">
      <p class="eyebrow">LIVE CONNECTOR ACCESS</p>
      <h2>Live accounts</h2>
      <p>
        Connect the API account used by this application. Live listings are separate from captured source search and make no model call.
      </p>
      <article
        :for={account <- @catalog}
        id={"account-status-#{account["service"]}"}
        class="connection-row"
      >
        <div>
          <strong>{account["label"]}</strong>
          <small>{state_label(account["state"])}</small>
          <p :for={connection <- account["connections"]} class="field-help">
            {connection["identity"]["login"] || connection["name"]} · {connection["status"]} · last API verification {connection[
              "last_verified_at"
            ]}
          </p>
        </div>
        <div>
          <button
            phx-click="account_setup"
            phx-value-service={account["service"]}
            class="button secondary"
          >Set up {account["label"]}</button>
          <button
            :for={connection <- account["connections"]}
            :if={connection["status"] == "active"}
            phx-click="account_disconnect"
            phx-value-id={connection["id"]}
            class="text-button"
          >Disconnect</button>
        </div>
      </article>

      <div :if={@service == "github" && @available_github_refs != []} class="context-note">
        <h3>Existing GitHub access is available</h3>
        <p>Verify the existing server credential with GitHub. Its value stays in the environment.</p>
        <.form
          :for={reference <- @available_github_refs}
          for={%{}}
          id={"github-existing-#{reference}"}
          phx-submit="account_connect"
          class="stack"
        >
          <input type="hidden" name="account[service]" value="github" />
          <input type="hidden" name="account[credential_ref]" value={reference} />
          <button type="submit" class="button primary" disabled={@pending != nil}>Connect GitHub using {reference}</button>
        </.form>
      </div>

      <.form
        for={%{}}
        id="account-form"
        phx-change="account_changed"
        phx-submit="account_connect"
        class="stack"
      >
        <label for="account-service">Service account</label>
        <select id="account-service" name="account[service]" disabled={@pending != nil}>
          <option value="github" selected={@service == "github"}>GitHub</option>
          <option value="github_projects" selected={@service == "github_projects"}>
            GitHub Projects
          </option>
          <option value="slack" selected={@service == "slack"}>Slack</option>
          <option value="jira" selected={@service == "jira"}>Jira</option>
          <option value="confluence" selected={@service == "confluence"}>Confluence</option>
        </select>
        <p class="field-help">{requirements(@service)}</p>
        <label for="account-credential">API credential environment reference</label>
        <input
          id="account-credential"
          name="account[credential_ref]"
          required
          placeholder={reference_hint(@service)}
          disabled={@pending != nil}
        />
        <div :if={@service in ~w(jira confluence)} class="stack">
          <label for="account-endpoint">Atlassian site origin</label>
          <input
            id="account-endpoint"
            name="account[endpoint]"
            required
            placeholder="https://your-site.atlassian.net"
            disabled={@pending != nil}
          />
          <label for="account-username">Email environment reference</label>
          <input
            id="account-username"
            name="account[username_ref]"
            required
            placeholder="HARNESSFORGE_ATLASSIAN_EMAIL"
            disabled={@pending != nil}
          />
        </div>
        <p class="field-help">
          Enter variable names, never secret values. A saved account must pass a real API check; browser sign-in alone does not connect it.
        </p>
        <button id="account-connect" type="submit" class="button primary" disabled={@pending != nil}>{if @pending,
          do: "Verifying API access…",
          else: "Verify and connect account"}</button>
      </.form>
    </div>
    """
  end

  defp state_label("configured"), do: "Configured · API verified when connected"
  defp state_label("credential_missing"), do: "Server credential missing"
  defp state_label(_), do: "Application account setup required"

  defp requirements("github"),
    do:
      "Read-only account identity and owned repository metadata. Top repositories means most recently updated; each request states its coverage."

  defp requirements("github_projects"),
    do:
      "Requires GitHub Projects read permission (read:project for classic tokens). Repository permission alone is insufficient. A source import also requires selecting a board URL."

  defp requirements("slack"),
    do:
      "Requires a Slack user API token with channel-list/read permission for the intended workspace. Browser login does not provide an API token."

  defp requirements(_),
    do:
      "Requires a reachable Atlassian site, API token and email reference. Reauthenticate the service if access has expired."

  defp reference_hint(service) when service in ~w(github github_projects),
    do: "GITHUB_PERSONAL_ACCESS_TOKEN"

  defp reference_hint("slack"), do: "HARNESSFORGE_SLACK_TOKEN"
  defp reference_hint(_), do: "HARNESSFORGE_ATLASSIAN_TOKEN"
end

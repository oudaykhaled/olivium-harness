defmodule HarnessForgeWeb.ChatPanel do
  @moduledoc "Authenticated, read-only conversation UI; content is rendered as escaped text."
  use HarnessForgeWeb, :html

  attr :turns, :list, required: true
  attr :pending, :any, required: true
  attr :error, :any, required: true
  attr :catalog, :map, required: true
  attr :mode, :string, required: true
  attr :requires_live, :boolean, required: true

  def chat(assigns) do
    ~H"""
    <section id="chat-panel" class="chat-layout tab-panel" aria-label="Connector chat">
      <div class="panel chat-conversation">
        <div class="section-heading">
          <div>
            <p class="eyebrow">CONNECTED EVIDENCE</p>
            <h2>Your connector assistant</h2>
            <p>
              Read live account metadata, search captured sources, or ask your configured AI model.
            </p>
          </div>
          <button id="chat-clear" phx-click="chat_clear" class="button secondary">Clear conversation</button>
        </div>
        <p class="field-help">
          This conversation stays in the current browser session. Refreshing clears it.
          Live account listings are fetched when requested. Evidence search reads captured snapshots.
        </p>
        <div
          id="chat-transcript"
          class="chat-transcript"
          role="log"
          aria-label="Conversation"
          aria-live="polite"
          aria-relevant="additions"
        >
          <div :if={@turns == [] && is_nil(@pending)} class="chat-empty">
            <span class="pill local">READ ACCESS</span>
            <h3>What would you like to find?</h3>
            <p>Try “List for me the top 10 repositories on my GitHub.”</p>
          </div>
          <article :for={turn <- @turns} id={"chat-turn-#{turn.id}"} class="chat-turn">
            <div class="chat-question">
              <strong>You</strong><p>{turn.question}</p>
            </div>
            <div class="chat-answer">
              <span class="pill neutral">{mode_label(turn.reply["mode"])}</span>
              <p class="chat-text">{answer_text(turn.reply)}</p>
              <ol :if={turn.reply["mode"] == "live"} class="chat-live-results">
                <li :for={row <- turn.reply["rows"]}>
                  <a
                    :if={https_link?(row_url(row))}
                    href={row_url(row)}
                    target="_blank"
                    rel="noopener noreferrer"
                  >{row_label(row)}</a>
                  <span :if={!https_link?(row_url(row))}>{row_label(row)}</span>
                  <small :if={row["updated_at"]}>Updated {row["updated_at"]}</small>
                </li>
              </ol>
              <p :if={turn.reply["mode"] == "live"} class="field-help">
                Fetched {turn.reply["fetched_at"]} · Account {turn.reply["account_login"]} · No model call
              </p>
              <p :if={turn.reply["mode"] == "model"} class="field-help">
                {turn.reply["provider"]} · {turn.reply["model"]} · Check the supporting excerpts before relying on this answer.
              </p>
              <div :if={turn.reply["citations"] != []} class="chat-citations">
                <h4>Supporting evidence</h4>
                <details :for={citation <- turn.reply["citations"]} class="citation">
                  <summary>{citation["id"]} · {citation["title"]} · {citation["provider"]}</summary>
                  <blockquote>{citation["snippet"]}</blockquote>
                  <span>Revision {short(citation["revision_id"])} · Bytes {citation["start_byte"]}–{citation[
                    "end_byte"
                  ]}</span>
                  <p :if={citation["captured_at"]} class="field-help">
                    Captured {citation["captured_at"]}
                  </p>
                  <a
                    :if={https_link?(citation["source_url"])}
                    href={citation["source_url"]}
                    target="_blank"
                    rel="noopener noreferrer"
                  >Open source</a>
                </details>
              </div>
            </div>
          </article>
          <div :if={@pending} id="chat-pending" class="chat-turn" role="status">
            <div class="chat-question">
              <strong>You</strong><p>{@pending.question}</p>
            </div>
            <p>Reading the current permitted evidence…</p>
          </div>
        </div>
        <p :if={@error} id="chat-error" class="notice error" role="alert">{@error}</p>
        <button
          :if={@requires_live}
          id="chat-use-assistant"
          phx-click="chat_use_assistant"
          class="button primary"
        >Use live assistant</button>
        <.form
          for={%{}}
          id="chat-form"
          phx-change="chat_mode_changed"
          phx-submit="chat_send"
          class="stack chat-composer"
        >
          <label for="chat-question">Message</label>
          <textarea
            id="chat-question"
            name="chat[question]"
            rows="3"
            required
            maxlength="4000"
            placeholder="Ask about your connected sources…"
            disabled={@pending != nil}
          ></textarea>
          <div class="chat-composer-actions">
            <div>
              <label for="chat-mode">Answer mode</label>
              <select id="chat-mode" name="chat[mode]" disabled={@pending != nil}>
                <option value="assistant" selected={@mode == "assistant"}>
                  Live connector assistant
                </option>
                <option value="evidence" selected={@mode == "evidence"}>Local evidence search</option>
                <option value="model" selected={@mode == "model"}>Configured AI model</option>
              </select>
            </div>
            <button id="chat-send" class="button primary" type="submit" disabled={@pending != nil}>Send message
            <span aria-hidden="true">→</span></button>
          </div>
          <p class="field-help">
            Live assistant runs supported read-only metadata requests through verified accounts. Local search reads captured evidence. AI mode requires configured model consent. Chat cannot approve claims, write to connectors or run coding agents.
          </p>
        </.form>
      </div>
      <aside class="chat-connectors" aria-label="Chat connector access">
        <div class="panel">
          <h3>Source connectors</h3>
          <p>Access is limited to current, active snapshots in this workspace.</p>
          <article
            :for={connector <- @catalog["connectors"]}
            id={"chat-connector-#{connector["provider"]}"}
            class="chat-connector"
          >
            <strong>{connector["label"]}</strong>
            <span :if={connector["connections"] == []} class="pill neutral">NO CAPTURED SOURCES</span>
            <p :if={connector["provider"] != "local"} class="field-help">
              {account_state(@catalog, connector["provider"])}
            </p>
            <button
              :if={connector["provider"] != "local"}
              phx-click="account_setup"
              phx-value-service={connector["provider"]}
              class="button secondary"
            >Set up live access</button>
            <div :for={connection <- connector["connections"]} class="chat-connection">
              <p>{connection["name"]}</p>
              <small>{connection["access_state"]} · {connection["source_count"]} captured sources · {if connection[
                                                                                                          "sync_complete"
                                                                                                        ],
                                                                                                        do:
                                                                                                          "scan complete",
                                                                                                        else:
                                                                                                          "scan incomplete"}</small>
              <button
                :if={connection["access_state"] == "active"}
                id={"chat-sync-#{connection["id"]}"}
                phx-click="chat_sync"
                phx-value-id={connection["id"]}
                class="button secondary"
                phx-disable-with="Queuing…"
              >Sync next page</button>
            </div>
          </article>
          <button phx-click="tab" phx-value-tab="connections" class="button secondary">Manage connections</button>
        </div>
        <div class="context-note">
          <h3>Model access</h3>
          <p>
            Selected provider: {@catalog["model"]["provider"] || "not configured"}. Model: {@catalog[
              "model"
            ]["model"] || "not selected"}.
          </p>
          <p>
            Supports Ollama, OpenAI Chat, OpenAI Responses and Anthropic Messages. Cloud chat requires explicit source and chat-context consent.
          </p>
          <h3>Coding agent targets</h3>
          <p :for={runtime <- @catalog["runtimes"]}>{runtime["label"]} · native export available</p>
          <p>
            Codex and Claude Code managed execution is unavailable. The assistant cannot launch a coding session.
          </p>
        </div>
      </aside>
    </section>
    """
  end

  defp short(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short(_), do: "unavailable"

  defp answer_text(%{"mode" => "evidence", "citations" => [_ | _] = citations}) do
    "Found #{length(citations)} matching captured excerpts. Open the supporting evidence below to read the exact source text. This local search made no model call."
  end

  defp answer_text(%{"mode" => "live", "provider" => "github"} = reply) do
    "#{reply["account_login"]}: #{length(reply["rows"])} most recently updated owned repositories visible to this credential. More repositories may exist; this is one bounded API page."
  end

  defp answer_text(%{"mode" => "live"} = reply),
    do:
      "#{reply["account_login"]}: #{length(reply["rows"])} live results. This is one bounded API page; more resources may exist."

  defp answer_text(reply), do: reply["answer"]

  defp mode_label("live"), do: "LIVE CONNECTOR RESULT"
  defp mode_label("model"), do: "AI ANSWER"
  defp mode_label(_), do: "LOCAL EVIDENCE SEARCH"

  defp row_url(row), do: row["html_url"] || row["url"]

  defp row_label(row),
    do: row["full_name"] || row["name"] || row["title"] || row["key"] || row["label"] || "Result"

  defp account_state(catalog, provider) do
    case Enum.find(catalog["accounts"] || [], &(&1["service"] == provider)) do
      %{"state" => "configured"} ->
        "Live account configured; API checked when connected."

      %{"state" => "credential_missing"} ->
        "The server API credential is missing."

      _ when provider == "github_projects" ->
        "Live access needs a GitHub credential with Projects read permission."

      _ when provider == "slack" ->
        "Live access needs a Slack API credential and workspace permissions."

      _ when provider in ["jira", "confluence"] ->
        "Live access needs Atlassian API credentials and a reachable site."

      _ ->
        "Live account setup is required."
    end
  end

  defp https_link?(value) when is_binary(value) do
    uri = URI.parse(value)
    uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo)
  end

  defp https_link?(_), do: false
end

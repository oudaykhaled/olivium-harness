defmodule HarnessForgeWeb.MCPAccessHTML do
  use HarnessForgeWeb, :html

  def index(assigns) do
    assigns =
      Map.put(
        assigns,
        :selection,
        case assigns.preview do
          {:ok, value, _} -> value
          _ -> nil
        end
      )

    ~H"""
    <main class="content stack company-builder" style="max-width:64rem;margin:0 auto;" id="mcp-access">
      <nav><.link href="/" class="button secondary">Home</.link>
        <.link href="/company/corpus" class="button secondary">Choose sources</.link></nav>
      <header>
        <p class="eyebrow">ASSISTANT ACCESS</p><h1>Connect an assistant</h1>
        <p>Source review → exact access → expires in 30 minutes</p>
      </header>
      <section :if={@selection} class="panel">
        <h2>✓ {length(@selection["members"])} current sources selected</h2>
        <p>{@selection_labels.project} · {@selection_labels.goal}</p>
        <.form for={%{}} action="/mcp/access" method="post" id="mcp-access-form">
          <input type="hidden" name="reviewed" value={@reviewed} />
          <label for="mcp-client-name">Assistant name</label>
          <input
            id="mcp-client-name"
            name="name"
            value="Local test assistant"
            maxlength="200"
            required
          />
          <label><input type="checkbox" name="synthetic" value="confirmed" required />
          These are synthetic local files. Allow this local client to inspect them.</label>
          <button class="button primary">Create access &amp; download key</button>
        </.form>
        <details>
          <summary>Access details</summary>
          <p>
            Read only · local client · temporary memory · no downstream use.
            The downloaded key is private. Revoke access below. Changed sources require a new decision.
          </p>
          <ul>
            <li :for={member <- @selection["members"]}>
              <code>{member["source_id"]}</code> · <code>{member["body_hash"]}</code>
            </li>
          </ul>
        </details>
      </section>
      <p :if={is_nil(@selection)} role="status" id="mcp-access-empty">
        {if @preview == :unavailable,
          do: "⚠ Source selection changed. Choose current sources.",
          else: "○ Choose a source scope to create access."}
      </p>
      <section class="panel">
        <h2>Source access</h2>
        <p :if={@grants == []}>○ No access grants</p>
        <article :for={grant <- @grants}>
          <p>{grant["state"]} · <code>{grant["id"]}</code> · expires {grant["expires_at"]}</p>
          <.form :if={grant["state"] == "active"} for={%{}} action="/mcp/access/revoke" method="post">
            <input type="hidden" name="kind" value="grant" /><input
              type="hidden"
              name="target_id"
              value={grant["id"]}
            />
            <button class="button secondary">Revoke access</button>
          </.form>
        </article>
      </section>
      <details class="panel">
        <summary>Assistants · {length(@clients)}</summary>
        <article :for={client <- @clients}>
          <p>{client["name"]} · {client["state"]}</p>
          <.form :if={client["state"] == "active"} for={%{}} action="/mcp/access/revoke" method="post">
            <input type="hidden" name="kind" value="client" /><input
              type="hidden"
              name="target_id"
              value={client["id"]}
            />
            <button class="button secondary">Revoke assistant</button>
          </.form>
        </article>
        <p>Most recent 50 records. Keys are never shown here.</p>
      </details>
    </main>
    """
  end
end

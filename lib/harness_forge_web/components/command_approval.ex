defmodule HarnessForgeWeb.CommandApproval do
  @moduledoc "An exact, single-use decision for a pending isolated command."
  use HarnessForgeWeb, :html

  attr :rows, :list, required: true
  attr :run_id, :string, required: true
  attr :message, :string, default: nil
  attr :ready, :boolean, default: false

  def panel(assigns) do
    ~H"""
    <section id="command-review" class="panel stack" aria-labelledby="command-review-title">
      <h3 id="command-review-title">Review agent commands</h3>
      <p>
        Each decision covers the displayed command and its child processes inside the isolated candidate.
        Allowing it once does not approve later commands or certify the task result.
      </p>
      <p :if={@message} role="status">{@message}</p>
      <p :if={@rows == []}>No command requests are available for this evaluation.</p>
      <article :for={row <- @rows} id={"command-request-#{row["id"]}"} class="context-note stack">
        <strong>{state_label(row)}</strong>
        <pre class="code-preview"><code>{row["payload"]["command"]}</code></pre>
        <p>Working directory: <code>{row["payload"]["cwd"]}</code></p>
        <p>Decision expires: <time datetime={row["expires_at"]}>{row["expires_at"]}</time></p>
        <div :if={pending?(row)} class="form-actions">
          <button
            type="button"
            class="button primary"
            phx-click="command_approval_decide"
            phx-value-run_id={@run_id}
            phx-value-id={row["id"]}
            phx-value-request_digest={row["request_digest"]}
            phx-value-decision="accept_once"
            phx-disable-with="Recording…"
            disabled={!@ready}
          >Allow once</button>
          <button
            type="button"
            class="button secondary"
            phx-click="command_approval_decide"
            phx-value-run_id={@run_id}
            phx-value-id={row["id"]}
            phx-value-request_digest={row["request_digest"]}
            phx-value-decision="decline"
            phx-disable-with="Recording…"
            disabled={!@ready}
          >Deny</button>
        </div>
        <details>
          <summary>Original request and exact scope</summary>
          <p>Original model arguments:</p>
          <pre class="code-preview"><code>{row["payload"]["original_arguments"]}</code></pre>
          <dl>
            <dt>Evaluation</dt><dd><code>{@run_id}</code></dd>
            <dt>Harness</dt><dd><code>{row["artifact_digest"]}</code></dd>
            <dt>Isolation profile</dt><dd><code>{row["profile_digest"]}</code></dd>
            <dt>Request</dt><dd><code>{row["request_digest"]}</code></dd>
          </dl>
        </details>
      </article>
    </section>
    """
  end

  defp pending?(row), do: row["state"] == "pending" and not expired?(row)

  defp expired?(row) do
    case DateTime.from_iso8601(row["expires_at"] || "") do
      {:ok, deadline, _} -> DateTime.compare(deadline, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  defp state_label(row) do
    cond do
      row["state"] in ~w(pending accepted) and expired?(row) ->
        "Expired; no permission is available"

      row["state"] == "pending" ->
        "Waiting for your decision"

      row["state"] == "accepted" ->
        "Allowed once; waiting for the agent to collect the decision"

      row["state"] == "consumed" ->
        "Decision delivered once; inspect the task result separately"

      row["state"] == "declined" ->
        "Denied or expired"

      true ->
        "Unavailable"
    end
  end
end

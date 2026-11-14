defmodule HarnessForgeWeb.SessionHTML do
  use HarnessForgeWeb, :html

  def new(assigns) do
    ~H"""
    <main class="login-shell">
      <div class="login-story">
        <a class="brand" href={~p"/login"} aria-label="Olivium Harness login"><img
          src={~p"/images/olivium-harness.png"}
          alt=""
          width="35"
          height="35"
        /><span class="brand-text">OLIVIUM<strong>HARNESS</strong></span></a>
        <div>
          <p class="eyebrow">THE WORKSPACE FOR AGENT CONTEXT</p>
          <h1>Good agents start<br />with clear evidence.</h1>
          <p>Build a versioned harness from the decisions your team can stand behind.</p>
        </div>
        <span class="local-indicator"><span></span> Local workspace · Private by default</span>
      </div>
      <section class="login-panel" aria-labelledby="login-title">
        <div class="login-card">
          <p class="eyebrow">WELCOME TO YOUR WORKSPACE</p>
          <h2 id="login-title">Unlock Olivium Harness</h2>
          <p>Use the access code saved on this computer. Your code is never included in a URL.</p>
          <.form for={%{}} action={~p"/login"} id="login-form" class="stack">
            <label for="access-code">Workspace access code</label>
            <input
              id="access-code"
              name="access_code"
              type="password"
              autocomplete="current-password"
              required
              maxlength="256"
              aria-describedby="login-help login-error"
            />
            <p :if={@error} id="login-error" class="form-error" role="alert">{@error}</p>
            <button id="unlock-workspace" type="submit" class="button primary">Unlock workspace
            <span aria-hidden="true">→</span></button>
          </.form>
          <div id="login-help" class="access-help">
            <strong>Find your access code</strong>
            <p>Open this local file and paste its contents above:</p>
            <code>{@access_path}</code>
          </div>
          <p class="fine-print">
            Only this workspace is unlocked. Restarting Olivium Harness ends active sessions.
          </p>
        </div>
      </section>
    </main>
    """
  end
end

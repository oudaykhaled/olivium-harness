defmodule HarnessForgeWeb.HarnessLive do
  @moduledoc "Authenticated, current text preview of one exact generated harness."
  use HarnessForgeWeb, :live_view
  alias HarnessForge.{Contracts, Workspaces}
  alias HarnessForgeWeb.HarnessDelivery
  alias HarnessForgeWeb.EvaluationReason
  alias HarnessForgeWeb.Plugs.OperatorSession

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(HarnessForge.PubSub, "workspace:" <> Workspaces.current_id())

    {:ok,
     socket
     |> detach_hook(:authenticate_event, :handle_event)
     |> attach_hook(:authenticate_event, :handle_event, &authenticate/3)
     |> assign(
       page_title: "Your harness",
       workspace_id: Workspaces.current_id(),
       digest: nil,
       harness: nil,
       recovery: nil,
       generation: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
       reset_token: 0,
       check_details: nil,
       message: nil
     )}
  end

  @impl true
  def handle_params(%{"digest" => digest}, _uri, socket),
    do: {:noreply, socket |> assign(:digest, bounded_digest(digest)) |> load_current()}

  def handle_params(_, _uri, socket),
    do: {:noreply, socket |> assign(:digest, nil) |> load_current()}

  @impl true
  def handle_event("harness_refresh", attrs, socket) when map_size(attrs) == 0,
    do: {:noreply, load_current(socket)}

  def handle_event("inspect_check", %{"id" => id} = attrs, socket) when map_size(attrs) == 1 do
    socket = assign(socket, :check_details, nil)

    case HarnessDelivery.check_details(socket.assigns.digest, id) do
      {:ok, details} ->
        if authorized?(socket),
          do: {:noreply, assign(socket, :check_details, details)},
          else: {:noreply, revoke(socket)}

      _ ->
        {:noreply,
         socket
         |> load_current()
         |> assign(
           :message,
           "This check record is unavailable. Refresh to check the harness's current access."
         )}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, load_current(socket)}

  @impl true
  def handle_info(:operator_session_revoked, socket), do: {:noreply, revoke(socket)}

  def handle_info(event, socket) when event in [:company_cache_reset, :corpus_cache_reset] do
    {:noreply,
     socket
     |> assign(harness: nil, recovery: nil, check_details: nil)
     |> assign(:reset_token, socket.assigns.reset_token + 1)
     |> assign(
       :message,
       "Workspace evidence or privacy changed. Refresh to check this exact harness again."
     )}
  end

  def handle_info({:company_changed, _}, socket),
    do:
      {:noreply,
       socket
       |> assign(harness: nil, recovery: nil, check_details: nil)
       |> assign(:reset_token, socket.assigns.reset_token + 1)
       |> assign(
         :message,
         "Company decisions changed. Refresh to check this exact harness again."
       )}

  def handle_info(_, socket), do: {:noreply, socket}

  defp authenticate(_event, _attrs, socket) do
    if authorized?(socket), do: {:cont, socket}, else: {:halt, revoke(socket)}
  end

  defp load_current(socket) do
    socket = assign(socket, harness: nil, recovery: nil, check_details: nil, message: nil)

    if authorized?(socket) do
      case HarnessDelivery.preview(socket.assigns.digest) do
        {:ok, harness} ->
          if authorized?(socket), do: assign(socket, :harness, harness), else: revoke(socket)

        _ ->
          case HarnessDelivery.recovery(socket.assigns.digest, caller(socket)) do
            {:ok, recovery} ->
              if authorized?(socket) do
                assign(socket,
                  recovery: recovery,
                  message:
                    "Your coverage selection changed. Review current evidence before generating a new harness."
                )
              else
                revoke(socket)
              end

            _ ->
              if authorized?(socket), do: unavailable(socket), else: revoke(socket)
          end
      end
    else
      revoke(socket)
    end
  end

  defp authorized?(socket),
    do:
      OperatorSession.valid?(socket.assigns.operator_auth) and
        socket.assigns.workspace_id == Workspaces.current_id()

  defp caller(socket) do
    auth = socket.assigns.operator_auth
    workspace = socket.assigns.workspace_id

    [
      authorize: fn -> OperatorSession.valid?(auth) and workspace == Workspaces.current_id() end,
      session_fingerprint: Contracts.digest(auth),
      view_generation: socket.assigns.generation,
      reset_token: socket.assigns.reset_token
    ]
  end

  defp revoke(socket),
    do:
      socket
      |> assign(harness: nil, recovery: nil, check_details: nil, message: nil)
      |> redirect(to: "/login")

  defp unavailable(socket),
    do:
      assign(socket,
        harness: nil,
        recovery: nil,
        check_details: nil,
        message:
          "This harness is unavailable or its evidence, decisions or stored bytes changed. Review current inputs and rebuild; no cached files are shown."
      )

  defp bounded_digest(value) when is_binary(value) and byte_size(value) <= 128, do: value
  defp bounded_digest(_), do: nil

  defp check_history(harness) do
    case get_in(harness || %{}, ["verification", "recorded_checks"]) do
      %{"status" => "available", "rows" => rows} when is_list(rows) ->
        %{status: "available", rows: rows |> Enum.take(10) |> Enum.map(&check_row/1)}

      %{"status" => "unavailable"} ->
        %{status: "unavailable", rows: []}

      _ ->
        %{status: "unknown", rows: []}
    end
  end

  defp check_row(row) when is_map(row) do
    kind =
      if row["kind"] in ~w(static_integrity runtime_smoke task), do: row["kind"], else: "unknown"

    outcome =
      if row["outcome"] in ~w(pending running passed failed blocked cancelled interrupted),
        do: row["outcome"],
        else: "unknown"

    id =
      case row["id"] do
        id when is_binary(id) and byte_size(id) == 36 ->
          case Ecto.UUID.cast(id) do
            {:ok, checked} -> checked
            _ -> "Unknown"
          end

        _ ->
          "Unknown"
      end

    %{
      id: id,
      kind: kind,
      outcome: outcome,
      time: check_time(row["inserted_at"]),
      reason: check_reason(row["reason"])
    }
  end

  defp check_row(_), do: check_row(%{})

  defp check_time(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} ->
        %{
          datetime: DateTime.to_iso8601(time),
          label: Calendar.strftime(time, "%d %b %Y, %H:%M UTC")
        }

      _ ->
        %{datetime: nil, label: "Unknown date"}
    end
  end

  defp check_time(_), do: %{datetime: nil, label: "Unknown date"}

  defp check_reason(nil), do: "No reason recorded."

  defp check_reason(code) when is_binary(code) and byte_size(code) <= 128 do
    label = EvaluationReason.label(code)
    if label == EvaluationReason.label("unknown"), do: "Unknown reason.", else: label
  end

  defp check_reason(_), do: "Unknown reason."

  defp check_kind("static_integrity"), do: "Static integrity"
  defp check_kind("runtime_smoke"), do: "Runtime check"
  defp check_kind("task"), do: "Task check"
  defp check_kind(_), do: "Unknown check"
  defp check_outcome("passed"), do: "PASS"
  defp check_outcome("failed"), do: "FAIL"
  defp check_outcome("blocked"), do: "BLOCKED"
  defp check_outcome("pending"), do: "Pending"
  defp check_outcome("running"), do: "Running"
  defp check_outcome("cancelled"), do: "Cancelled"
  defp check_outcome("interrupted"), do: "Interrupted"
  defp check_outcome(_), do: "Unknown"

  attr :check, :map, required: true
  attr :index, :integer, required: true

  defp recorded_check(assigns) do
    ~H"""
    <article
      id={"harness-recorded-check-#{@index}"}
      class="artifact-row"
      data-kind={@check.kind}
      data-outcome={@check.outcome}
    >
      <h3>{check_kind(@check.kind)} · {check_outcome(@check.outcome)}</h3>
      <p><time datetime={@check.time.datetime}>{@check.time.label}</time></p>
      <p>{@check.reason}</p>
      <button
        :if={@check.id != "Unknown"}
        type="button"
        class="button secondary"
        phx-click="inspect_check"
        phx-value-id={@check.id}
      >
        Inspect recorded evidence
      </button>
    </article>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:check_details, fn -> nil end)
      |> assign(:recorded_checks, check_history(assigns.harness))

    assigns =
      assign(
        assigns,
        :last_recorded_task,
        Enum.find(assigns.recorded_checks.rows, &(&1.kind == "task"))
      )

    ~H"""
    <main id="harness-outcome" class="content company-builder harness-outcome">
      <nav class="company-actions" aria-label="Harness journey">
        <.link href="/?setup=company" class="button secondary">Return to company scope</.link>
        <.link href="/?view=package" class="button secondary">All your harnesses</.link>
        <.link href="/?view=evaluations" class="button secondary">Checks</.link>
      </nav>
      <header class="page-heading">
        <div>
          <p class="eyebrow">YOUR HARNESS</p><h1>Your generated files</h1>
          <p>Inspect your agent instructions and download the complete harness.</p>
        </div>
      </header>
      <section
        :if={@message}
        id="harness-recovery"
        class="panel"
        aria-labelledby="harness-recovery-title"
      >
        <div class="harness-recovery-heading">
          <span class="harness-stage-symbol" aria-hidden="true">↻</span>
          <h2 id="harness-recovery-title">Needs a refresh</h2>
        </div>
        <p id="harness-unavailable" class="notice error" role="alert">{@message}</p>
        <.link
          id="harness-review-inputs"
          href={if @recovery, do: @recovery["href"], else: "/?setup=company"}
          class={if @recovery, do: "button primary", else: "button secondary"}
        >{if @recovery, do: "Review current evidence", else: "Review inputs"}</.link>
      </section>
      <button id="harness-refresh" phx-click="harness_refresh" type="button" class="button secondary">Refresh current eligibility</button>
      <section :if={@harness} id="harness-preview" aria-labelledby="harness-name">
        <header class="panel harness-output-summary">
          <h2 id="harness-name">{@harness["name"]} · {@harness["version"]}</h2>
          <p>Agent target: {@harness["target"]}. {length(@harness["files"])} generated files.</p>
          <div class="company-actions">
            <a
              id="harness-download"
              href={"/harnesses/" <> @harness["digest"] <> "/download"}
              download
              class="button primary"
            >Download ZIP</a>
            <a href="#harness-files-title" class="button secondary">Inspect files</a>
            <.link href="/?view=evaluations" class="button secondary">Check a task</.link>
          </div>
          <ol
            id="harness-journey"
            class="harness-journey"
            aria-label="Harness evidence and next steps"
          >
            <li data-state={
              if @harness["verification"]["current_decisions"] == "eligible",
                do: "available",
                else: "unknown"
            }>
              <span class="harness-stage-symbol" aria-hidden="true">1</span>
              <div>
                <h3>Current decisions</h3>
                <p>
                  {if @harness["verification"]["current_decisions"] == "eligible",
                    do: "Eligible at this check",
                    else: "Unobserved"}
                </p>
              </div>
            </li>
            <li data-state={
              if @harness["verification"]["generated"] == true, do: "available", else: "unknown"
            }>
              <span class="harness-stage-symbol" aria-hidden="true">2</span>
              <div>
                <h3>Generated files</h3>
                <p>
                  {if @harness["verification"]["generated"] == true,
                    do: "Available to inspect",
                    else: "Unobserved"}
                </p>
              </div>
            </li>
            <li data-state="unknown">
              <span class="harness-stage-symbol" aria-hidden="true">3</span>
              <div>
                <h3>Task outcome</h3>
                <p>Unobserved here</p>
                <p
                  :if={@last_recorded_task}
                  id="harness-last-recorded-task"
                  class="harness-recorded-summary"
                  data-outcome={@last_recorded_task.outcome}
                >
                  Last recorded task: <strong>{check_outcome(@last_recorded_task.outcome)}</strong>
                  ·
                  <time datetime={@last_recorded_task.time.datetime}>{@last_recorded_task.time.label}</time>
                </p>
                <a href="#harness-recorded-checks">Inspect recorded checks</a>
              </div>
            </li>
          </ol>
          <p class="field-help">
            The ZIP contains the complete stored files, including any text shortened in the preview.
          </p>
          <details>
            <summary>Exact harness identity</summary><p id="harness-digest">
              <code>{@harness["digest"]}</code>
            </p>
          </details>
        </header>
        <section id="harness-files" class="panel" aria-labelledby="harness-files-title">
          <h2 id="harness-files-title" tabindex="-1">Files in this harness</h2>
          <nav id="harness-file-tree" aria-label="Generated file tree">
            <ul>
              <li :for={{file, index} <- Enum.with_index(@harness["files"])}>
                <a href={"#harness-file-#{index}"}><span aria-hidden="true">▤</span><code>{file[
                  "path"
                ]}</code></a>
              </li>
            </ul>
          </nav>
          <details
            :for={{file, index} <- Enum.with_index(@harness["files"])}
            id={"harness-file-#{index}"}
            class="harness-file"
            open={file["path"] == "AGENTS.md"}
          >
            <summary><code>{file["path"]}</code> · {file["bytes"]} bytes</summary>
            <p :if={file["truncated"]} class="field-help">
              Shortened preview. Download the ZIP for this file’s complete bytes.
            </p>
            <pre tabindex="0" aria-label={"Generated text: " <> file["path"]}>{file["content"]}</pre>
            <p class="field-help">SHA-256 <code>{file["sha256"]}</code></p>
          </details>
        </section>
        <details id="harness-proof" class="panel" aria-labelledby="harness-proof-title">
          <summary id="harness-proof-title">Integrity and qualification details</summary>
          <dl class="harness-proof-list">
            <div>
              <dt>Generated files</dt><dd>
                {if @harness["verification"]["generated"] == true, do: "Available", else: "Unobserved"}
              </dd>
            </div>
            <div>
              <dt>Stored byte integrity</dt><dd>
                {if @harness["verification"]["integrity"] == "verified",
                  do: "Verified for this exact harness",
                  else: "Unobserved"}
              </dd>
            </div>
            <div>
              <dt>Current decisions</dt><dd>
                {if @harness["verification"]["current_decisions"] == "eligible",
                  do: "Eligible at this page check",
                  else: "Unobserved"}
              </dd>
            </div>
            <div>
              <dt>Representative-task outcome</dt><dd>
                Unobserved here. Generated files do not establish task success.
              </dd>
            </div>
            <div>
              <dt>Release qualification</dt><dd>
                Unobserved here. Review the separate checks and release gates.
              </dd>
            </div>
          </dl>
        </details>
        <section
          id="harness-recorded-checks"
          class="panel"
          aria-labelledby="harness-recorded-checks-title"
        >
          <h2 id="harness-recorded-checks-title">
            Previously recorded checks for this exact harness
          </h2>
          <p>
            Historical records do not establish current applicability, company quality or release qualification.
          </p>
          <%= cond do %>
            <% @recorded_checks.status == "unavailable" -> %>
              <p id="harness-recorded-unavailable" role="status">
                Recorded check history is unavailable.
              </p>
            <% @recorded_checks.status == "unknown" -> %>
              <p id="harness-recorded-unknown" role="status">Recorded check history is unknown.</p>
            <% @recorded_checks.rows == [] -> %>
              <p id="harness-recorded-empty">No matching recorded checks.</p>
            <% true -> %>
              <p>
                Latest {length(@recorded_checks.rows)} recorded checks, newest first; at most ten.
              </p>
              <.recorded_check
                :for={{check, index} <- @recorded_checks.rows |> Enum.take(3) |> Enum.with_index()}
                check={check}
                index={index}
              />
              <details
                :if={length(@recorded_checks.rows) > 3}
                id="harness-recorded-more"
                open={
                  Enum.any?(Enum.drop(@recorded_checks.rows, 3), &(&1.outcome in ~w(failed blocked)))
                }
              >
                <summary>More recorded checks · {length(@recorded_checks.rows) - 3}</summary>
                <.recorded_check
                  :for={{check, index} <- @recorded_checks.rows |> Enum.drop(3) |> Enum.with_index(3)}
                  check={check}
                  index={index}
                />
              </details>
              <details id="harness-recorded-identities">
                <summary>Exact recorded run identities</summary>
                <p :for={check <- @recorded_checks.rows}>
                  {check_kind(check.kind)} · <code>{check.id}</code>
                </p>
              </details>
          <% end %>
          <section
            :if={@check_details}
            id="harness-check-details"
            aria-labelledby="harness-check-details-title"
          >
            <h3 id="harness-check-details-title">Recorded execution evidence</h3>
            <p>{check_kind(@check_details["kind"])} · {check_outcome(@check_details["outcome"])}</p>
            <p>
              Historical evidence for this exact harness. Company task benefit and release qualification require separate checks.
            </p>
            <p :if={@check_details["checks"] == []}>
              No task transcript was recorded for this check.
            </p>
            <article
              :for={{task, index} <- Enum.with_index(@check_details["checks"])}
              id={"harness-task-evidence-#{index}"}
            >
              <h4>
                {if task["name"] == "", do: "Task #{index + 1}", else: task["name"]} · {check_outcome(
                  task["outcome"]
                )}
              </h4>
              <p :if={task["solver_stopped"]}>The solver stopped before protected grading.</p>
              <details :if={task["candidate_before"] != "" or task["candidate_after"] != ""}>
                <summary>Inspect code before and after</summary>
                <h5>Before</h5><pre tabindex="0">{task["candidate_before"]}</pre>
                <h5>After</h5><pre tabindex="0">{task["candidate_after"]}</pre>
              </details>
              <details :if={task["grader_output"] != ""}>
                <summary>Protected test output</summary><pre tabindex="0">{task["grader_output"]}</pre>
              </details>
              <details :if={task["agent_output"] != ""}>
                <summary>Agent transcript</summary><pre tabindex="0">{task["agent_output"]}</pre>
              </details>
            </article>
          </section>
        </section>
      </section>
    </main>
    """
  end
end

defmodule HarnessForge.Evidence.Corpora do
  @moduledoc "Relational, workspace-scoped corpus authority with conservative generation invalidation."
  import Ecto.Query
  alias HarnessForge.{Audit, Repo, Workspaces}
  alias HarnessForge.Company.AssessmentAttempts
  alias HarnessForge.Evidence.{Connection, Corpus, Revision, RevisionUseHolds, Source, Store}
  alias HarnessForge.Privacy.Purge
  @salt "corpus-page-v1"

  defdelegate requirements_context(corpus_id, project_id, goal_id, goal_hash, caller),
    to: HarnessForge.Evidence.Requirements,
    as: :context

  defdelegate declare_requirements(corpus_id, expected, attrs, caller),
    to: HarnessForge.Evidence.Requirements,
    as: :declare

  defdelegate requirements_summary(id, digest, caller),
    to: HarnessForge.Evidence.Requirements,
    as: :summary

  defdelegate requirements_saved_choice(corpus_id, project_id, goal_id, goal_hash, caller),
    to: HarnessForge.Evidence.Requirements,
    as: :saved_choice

  defdelegate requirement_capture_choices(corpus_id, connection_id, attrs, caller),
    to: HarnessForge.Evidence.Requirements,
    as: :capture_choices

  def create(attrs, caller) do
    guard(caller, fn ->
      with :ok <- keys(attrs, ["name"]),
           true <- text?(attrs["name"], 200) do
        with {:ok, corpus} <-
               Repo.insert(%Corpus{
                 workspace_id: Store.workspace(),
                 name: String.trim(attrs["name"])
               }),
             {:ok, _} <- Audit.append("corpus.created", %{"corpus_id" => corpus.id}) do
          {:ok, Store.dto(corpus)}
        end
      else
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  def page(attrs, caller) do
    guard(caller, fn ->
      with :ok <- keys(attrs, [], ["cursor"]),
           {:ok, after_id} <- cursor(attrs["cursor"], %{"kind" => "corpora"}, caller) do
        rows =
          Repo.all(
            from(c in Store.scoped(Corpus), where: c.id > ^after_id, order_by: c.id, limit: 26)
          )

        {:ok, paged(Enum.map(rows, &Store.dto/1), %{"kind" => "corpora"}, caller)}
      end
    end)
  end

  def members(id, attrs, caller) do
    guard(caller, fn ->
      with :ok <- keys(attrs, [], ["cursor"]),
           {:ok, corpus} <- get(id),
           binding = %{
             "kind" => "members",
             "corpus_id" => id,
             "generation" => corpus.semantic_generation
           },
           {:ok, after_id} <- cursor(attrs["cursor"], binding, caller) do
        found =
          rows(
            "SELECT source_id AS id,source_id,revision_id,status,passage_set_id FROM corpus_members WHERE workspace_id=? AND corpus_id=? AND source_id>? ORDER BY source_id LIMIT 26",
            [Store.workspace(), id, after_id]
          )

        {:ok, paged(found, binding, caller)}
      end
    end)
  end

  def apply_members(id, generation, changes, caller) do
    guard(caller, fn ->
      with {:ok, corpus} <- get(id),
           true <- is_integer(generation) and corpus.semantic_generation == generation,
           true <- is_list(changes) and length(changes) in 1..100,
           true <- Enum.all?(changes, &valid_change?/1),
           true <- length(Enum.uniq_by(changes, & &1["source_id"])) == length(changes),
           {:ok, changed} <- apply_changes(id, changes) do
        if changed, do: advance(id)
        {:ok, Store.dto(Repo.get!(Corpus, id))}
      else
        false -> {:error, :stale_generation}
        error -> error
      end
    end)
  end

  def assert_current(id, generation, authorization) do
    with :ok <- Purge.ready(),
         {:ok, corpus} <- get(id),
         true <- corpus.state == "active",
         true <-
           corpus.semantic_generation == generation and
             corpus.authorization_generation == authorization,
         :ok <- RevisionUseHolds.assert_corpus_unheld(id) do
      :ok
    else
      false -> {:error, :stale_generation}
      {:error, :not_found} -> {:error, :invalid_scope}
      error -> error
    end
  end

  @doc "Trusted source-change hook; caller holds the root source/privacy fence and transaction."
  def invalidate_source(id, reason) do
    if uuid?(id) do
      invalidate_page(id, reason, "")
    else
      {:error, :invalid_input}
    end
  end

  @doc "Trusted bounded propagation page; root persists the fence/cursor and owns its transaction."
  def invalidate_source_page(source_id, reason, after_id) do
    if uuid?(source_id) and is_binary(after_id) do
      found =
        rows(
          "SELECT corpus_id,status FROM corpus_members WHERE workspace_id=? AND source_id=? AND corpus_id>? ORDER BY corpus_id LIMIT 100",
          [Store.workspace(), source_id, after_id]
        )

      latest =
        rows(
          "SELECT s.latest_revision_id,s.status,c.status AS connection_status FROM evidence_sources s JOIN source_connections c ON c.id=s.connection_id AND c.workspace_id=s.workspace_id WHERE s.workspace_id=? AND s.id=?",
          [Store.workspace(), source_id]
        )

      held? =
        case RevisionUseHolds.assert_source_unheld(source_id) do
          :ok -> false
          {:error, :revision_use_denied} -> true
          {:error, reason} -> Repo.rollback(reason)
        end

      Enum.each(found, fn row ->
        case {held?, row["status"], latest} do
          {true, "removed", _} ->
            query!(
              "UPDATE corpus_members SET passage_set_id=NULL,updated_at=? WHERE workspace_id=? AND corpus_id=? AND source_id=?",
              [now(), Store.workspace(), row["corpus_id"], source_id]
            )

          {true, _, _} ->
            query!(
              "UPDATE corpus_members SET status='denied',passage_set_id=NULL,updated_at=? WHERE workspace_id=? AND corpus_id=? AND source_id=?",
              [now(), Store.workspace(), row["corpus_id"], source_id]
            )

          {false, _,
           [
             %{
               "latest_revision_id" => revision,
               "status" => "active",
               "connection_status" => "active"
             }
           ]}
          when is_binary(revision) ->
            query!(
              "UPDATE corpus_members SET revision_id=?,passage_set_id=NULL,updated_at=? WHERE workspace_id=? AND corpus_id=? AND source_id=?",
              [revision, now(), Store.workspace(), row["corpus_id"], source_id]
            )

          _ ->
            query!(
              "UPDATE corpus_members SET status='denied',passage_set_id=NULL,updated_at=? WHERE workspace_id=? AND corpus_id=? AND source_id=?",
              [now(), Store.workspace(), row["corpus_id"], source_id]
            )
        end

        authorization? =
          held? or
            reason in [
              :revoked,
              :source_revoked,
              :connection_revoked,
              :scope_changed,
              "revoked",
              "scope_changed"
            ]

        advance(row["corpus_id"], authorization?)
      end)

      next = if found == [], do: after_id, else: List.last(found)["corpus_id"]
      {:ok, %{"next_cursor" => next, "done" => length(found) < 100}}
    else
      {:error, :invalid_input}
    end
  end

  defp invalidate_page(source_id, reason, after_id) do
    case invalidate_source_page(source_id, reason, after_id) do
      {:ok, %{"done" => true}} -> :ok
      {:ok, %{"next_cursor" => next}} -> invalidate_page(source_id, reason, next)
      error -> error
    end
  end

  defp apply_changes(id, changes) do
    Enum.reduce_while(changes, {:ok, false}, fn change, {:ok, changed} ->
      case put_member(id, change) do
        {:ok, value} -> {:cont, {:ok, changed or value}}
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  def put_member(id, %{"source_id" => source, "revision_id" => revision, "action" => action}) do
    with {:ok, _} <- member_source(source, revision, action) do
      previous =
        rows(
          "SELECT revision_id,status FROM corpus_members WHERE workspace_id=? AND corpus_id=? AND source_id=?",
          [Store.workspace(), id, source]
        )

      status = if action == "include", do: "active", else: "removed"
      changed = previous != [%{"revision_id" => revision, "status" => status}]

      if changed do
        query!(
          "INSERT INTO corpus_members(workspace_id,corpus_id,source_id,revision_id,status,inserted_at,updated_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(corpus_id,source_id) DO UPDATE SET revision_id=excluded.revision_id,status=excluded.status,passage_set_id=NULL,updated_at=excluded.updated_at",
          [Store.workspace(), id, source, revision, status, now(), now()]
        )
      end

      {:ok, changed}
    end
  end

  @doc false
  def current_source(source_id, revision_id) do
    with {:ok, source} <- Store.get(Source, source_id),
         :ok <- RevisionUseHolds.assert_source_unheld(source_id),
         {:ok, revision} <- Store.get(Revision, revision_id),
         {:ok, connection} <- Store.get(Connection, source.connection_id),
         true <-
           source.status == "active" and connection.status == "active" and
             source.latest_revision_id == revision.id and revision.source_id == source.id,
         :ok <-
           HarnessForge.Connectors.Registry.document_scope(connection, %{
             "external_id" => source.external_id,
             "source_url" => revision.source_url,
             "metadata" => revision.metadata
           }),
         :ok <-
           RevisionUseHolds.assert_use(source_id, revision_id, revision.body_hash, "inspection") do
      {:ok, %{source: source, revision: revision, connection: connection}}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  # Removing an exact current identity does not read its body or grant use.
  defp member_source(source_id, revision_id, "remove") do
    with {:ok, source} <- Store.get(Source, source_id),
         true <- source.latest_revision_id == revision_id,
         [revision] <-
           rows(
             "SELECT id FROM evidence_revisions WHERE workspace_id=? AND source_id=? AND id=?",
             [Store.workspace(), source_id, revision_id]
           ) do
      {:ok, revision}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp member_source(source_id, revision_id, "include"),
    do: current_source(source_id, revision_id)

  @doc false
  def get(id), do: Store.get(Corpus, id)
  @doc false
  def advance(id, authorization? \\ false) do
    query!(
      "UPDATE corpora SET semantic_generation=semantic_generation+1,authorization_generation=authorization_generation+?,lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND id=?",
      [if(authorization?, do: 1, else: 0), now(), Store.workspace(), id]
    )

    HarnessForge.Graphiti.Runtime.forget_corpus(id)
    :ok
  end

  @doc false
  def guard(caller, fun) do
    with :ok <- AssessmentAttempts.options(caller), :ok <- AssessmentAttempts.authorize(caller) do
      Purge.synchronize(fn ->
        Store.transaction(fn ->
          with :ok <- Workspaces.ensure_writable(),
               :ok <- Purge.ready(),
               :ok <- AssessmentAttempts.authorize(caller),
               {:ok, result} <- fun.(),
               :ok <- AssessmentAttempts.authorize(caller),
               :ok <- Purge.ready() do
            {:ok, result}
          end
        end)
      end)
    end
  end

  @doc "Read-only machine inspection fence. Operator mutation authority is never inferred."
  def inspection_guard(%HarnessForge.MCP.ClientContext{} = caller, fun) do
    Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- Workspaces.ensure_writable(),
             :ok <- Purge.ready(),
             :ok <- HarnessForge.MCP.ClientContext.authorize(caller),
             {:ok, result} <- fun.(),
             :ok <- HarnessForge.MCP.ClientContext.authorize(caller),
             :ok <- Purge.ready(),
             do: {:ok, result}
      end)
    end)
  end

  def inspection_guard(caller, fun), do: guard(caller, fun)

  @doc false
  def keys(attrs, required, optional \\ []) do
    if is_map(attrs) and not is_struct(attrs) and Enum.all?(Map.keys(attrs), &is_binary/1) and
         Map.keys(attrs) -- (required ++ optional) == [] and
         Enum.all?(required, &Map.has_key?(attrs, &1)), do: :ok, else: {:error, :invalid_input}
  end

  @doc false
  def uuid?(id), do: is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id))
  @doc false
  def digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  @doc false
  def text?(value, bytes),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..bytes and
        String.trim(value) != ""

  @doc false
  def now, do: DateTime.to_iso8601(Store.now())
  @doc false
  def rows(sql, params) do
    %{columns: columns, rows: rows} = query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  @doc false
  def query!(sql, params), do: Repo.query!(sql, params, log: false)
  @doc false
  def decode(value) when is_map(value), do: value
  def decode(value), do: Jason.decode!(value)

  @doc false
  def paged(found, binding, %HarnessForge.MCP.ClientContext{} = caller) do
    visible = Enum.take(found, 8)
    next = if length(found) > 8, do: continuation(List.last(visible)["id"], binding, caller)
    %{"rows" => visible, "next_cursor" => next}
  end

  def paged(found, binding, caller) do
    visible = Enum.take(found, 25)

    next =
      if length(found) > 25, do: sign(Map.put(binding, "after", List.last(visible)["id"]), caller)

    %{"rows" => visible, "next_cursor" => next}
  end

  @doc false
  def continuation(after_id, binding, caller),
    do: sign(Map.put(binding, "after", after_id), caller)

  @doc false
  def cursor(value, _, _) when value in [nil, ""], do: {:ok, ""}

  def cursor(value, binding, caller) when is_binary(value) and byte_size(value) <= 8192 do
    with {:ok, payload} <- Phoenix.Token.verify(secret(), @salt, value, max_age: 600),
         true <- payload["caller"] == caller_binding(caller),
         after_id when is_binary(after_id) <- payload["after"],
         true <- Map.drop(payload, ["caller", "after"]) == binding do
      {:ok, after_id}
    else
      _ -> {:error, :invalid_cursor}
    end
  rescue
    _ -> {:error, :invalid_cursor}
  end

  def cursor(_, _, _), do: {:error, :invalid_cursor}

  defp sign(binding, caller),
    do: Phoenix.Token.sign(secret(), @salt, Map.put(binding, "caller", caller_binding(caller)))

  defp caller_binding(%HarnessForge.MCP.ClientContext{} = caller),
    do: HarnessForge.MCP.ClientContext.binding(caller)

  defp caller_binding(caller),
    do: %{
      "workspace_id" => Store.workspace(),
      "session_fingerprint" => caller[:session_fingerprint],
      "view_generation" => caller[:view_generation],
      "reset_token" => caller[:reset_token]
    }

  defp secret,
    do:
      Application.fetch_env!(:harness_forge, HarnessForgeWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

  defp valid_change?(change),
    do:
      keys(change, ~w(source_id revision_id action)) == :ok and uuid?(change["source_id"]) and
        uuid?(change["revision_id"]) and change["action"] in ["include", "remove"]
end

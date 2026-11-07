defmodule HarnessForge.MCP.DisclosureGrants do
  @moduledoc "Exact, expiring owner disclosure decisions for synthetic local current inspection only."
  alias HarnessForge.{Audit, Contracts, Repo}
  alias HarnessForge.Company.Retrieval
  alias HarnessForge.Evidence.{Corpora, Store}
  alias HarnessForge.MCP.{ClientContext, Clients}

  @profile %{
    "dataset" => "owner_declared_synthetic_local",
    "purpose" => "current_inspection",
    "role" => "local_assistant",
    "retention" => "ephemeral_memory",
    "downstream_use" => "inspection_only",
    "egress" => "local_client_only"
  }
  @request ~w(corpus_id project_id goal_id goal_hash expected_generation)
  @hash_fields ~w(id workspace_id client_id client_generation corpus_id project_id goal_id goal_hash semantic_generation authorization_generation profile_hash project_hash profile generation expires_at inserted_at)

  def profile, do: @profile

  def list(owner) do
    Corpora.guard(owner, fn ->
      rows =
        Corpora.rows(
          "SELECT g.id,g.client_id,c.name AS client_name,g.corpus_id,g.project_id,g.goal_id,g.state,g.generation,g.expires_at,g.revoked_at,g.inserted_at FROM mcp_disclosure_grants g JOIN mcp_clients c ON c.id=g.client_id AND c.workspace_id=g.workspace_id WHERE g.workspace_id=? ORDER BY g.inserted_at DESC,g.id DESC LIMIT 51",
          [Store.workspace()]
        )

      rows =
        Enum.map(rows, &Map.put(&1, "scope_label", "Owner-declared synthetic local inspection"))

      {:ok, %{"grants" => Enum.take(rows, 50), "truncated" => length(rows) > 50}}
    end)
  end

  def preview(attrs, owner) do
    Corpora.guard(owner, fn ->
      with :ok <- Corpora.keys(attrs, @request),
           {:ok, scope} <- Retrieval.disclosure_scope(attrs, owner),
           {:ok, members} <- current_members(scope["corpus_id"]) do
        {:ok, %{"scope" => scope, "members" => members, "profile" => @profile}}
      end
    end)
  end

  def issue(attrs, owner) do
    Corpora.guard(owner, fn ->
      with :ok <- Corpora.keys(attrs, @request ++ ~w(client_id members profile ttl_seconds)),
           true <- attrs["profile"] == @profile,
           true <- is_integer(attrs["ttl_seconds"]) and attrs["ttl_seconds"] in 1..3600,
           {:ok, client} <- Clients.get(attrs["client_id"]),
           true <- client["state"] == "active",
           {:ok, scope} <- Retrieval.disclosure_scope(Map.take(attrs, @request), owner),
           {:ok, members} <- current_members(scope["corpus_id"]),
           true <- attrs["members"] == members do
        row = %{
          "id" => Ecto.UUID.generate(),
          "workspace_id" => Store.workspace(),
          "client_id" => client["id"],
          "client_generation" => client["generation"],
          "corpus_id" => scope["corpus_id"],
          "project_id" => scope["project_id"],
          "goal_id" => scope["goal_id"],
          "goal_hash" => scope["goal_hash"],
          "semantic_generation" => scope["semantic_generation"],
          "authorization_generation" => scope["authorization_generation"],
          "profile_hash" => scope["profile"]["content_hash"],
          "project_hash" => scope["project"]["content_hash"],
          "profile" => @profile,
          "generation" => 0,
          "expires_at" => System.system_time(:second) + attrs["ttl_seconds"],
          "inserted_at" => Corpora.now(),
          "members" => members
        }

        row = Map.put(row, "revision_hash", digest(row))
        columns = @hash_fields ++ ["revision_hash"]

        values =
          Enum.map(columns, fn key ->
            if key == "profile", do: Jason.encode!(row[key]), else: row[key]
          end)

        marks = Enum.map_join(columns, ",", fn _ -> "?" end)

        with {:ok, _} <-
               Repo.query(
                 "INSERT INTO mcp_disclosure_grants(#{Enum.join(columns, ",")},state) VALUES(#{marks},'active')",
                 values,
                 log: false
               ),
             :ok <- insert_items(row),
             {:ok, _} <-
               Audit.append("mcp.disclosure.granted", %{
                 "actor" => client["id"],
                 "request_digest" => row["revision_hash"],
                 "count" => length(members),
                 "status" => "synthetic_local_inspection"
               }) do
          {:ok, Map.take(row, ~w(id revision_hash expires_at client_id generation profile))}
        end
      else
        false -> {:error, :invalid_disclosure_grant}
        error -> error
      end
    end)
  end

  def revoke(id, owner) do
    Corpora.guard(owner, fn ->
      with {:ok, grant} <- get(id),
           {:ok, _} <-
             Repo.query(
               "UPDATE mcp_disclosure_grants SET state='revoked',generation=generation+1,revoked_at=? WHERE workspace_id=? AND id=? AND state='active'",
               [Corpora.now(), Store.workspace(), id],
               log: false
             ),
           {:ok, _} <-
             Audit.append("mcp.disclosure.revoked", %{
               "actor" => grant["client_id"],
               "request_digest" => grant["revision_hash"],
               "status" => "revoked"
             }) do
        {:ok, %{"id" => id, "state" => "revoked"}}
      end
    end)
  end

  def resolve(client, id) do
    with {:ok, grant} <- get(id),
         true <-
           client["id"] == grant["client_id"] and
             client["generation"] == grant["client_generation"],
         true <- grant["state"] == "active" and grant["expires_at"] > System.system_time(:second),
         true <- grant["profile"] == @profile and digest(grant) == grant["revision_hash"],
         {:ok, scope} <- current_scope(grant) do
      context = %ClientContext{
        client_id: client["id"],
        client_generation: client["generation"],
        token_hash: client["token_hash"],
        grant_id: id,
        grant_generation: grant["generation"],
        grant_digest: grant["revision_hash"],
        scope: scope,
        profile: grant["profile"]
      }

      with :ok <- ClientContext.authorize(context), do: {:ok, context}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def validate(%ClientContext{} = context) do
    with {:ok, grant} <- get(context.grant_id),
         true <- grant["state"] == "active" and grant["expires_at"] > System.system_time(:second),
         true <- grant["profile"] == @profile,
         true <-
           grant["client_id"] == context.client_id and
             grant["client_generation"] == context.client_generation,
         true <-
           grant["generation"] == context.grant_generation and
             grant["revision_hash"] == context.grant_digest,
         true <- digest(grant) == grant["revision_hash"],
         {:ok, scope} <- current_scope(grant),
         true <- scope == context.scope,
         {:ok, members} <- current_members(grant["corpus_id"]),
         true <- members == grant["members"] do
      :ok
    else
      _ -> {:error, :client_grant_unavailable}
    end
  end

  defp current_scope(grant) do
    with :ok <-
           Corpora.assert_current(
             grant["corpus_id"],
             grant["semantic_generation"],
             grant["authorization_generation"]
           ),
         {:ok, scope} <-
           Retrieval.disclosure_scope_current(%{
             "corpus_id" => grant["corpus_id"],
             "project_id" => grant["project_id"],
             "goal_id" => grant["goal_id"],
             "goal_hash" => grant["goal_hash"],
             "expected_generation" => grant["semantic_generation"]
           }),
         true <-
           scope["profile"]["content_hash"] == grant["profile_hash"] and
             scope["project"]["content_hash"] == grant["project_hash"],
         do: {:ok, scope},
         else: (_ -> {:error, :client_grant_unavailable})
  end

  defp get(id) do
    if Corpora.uuid?(id) do
      case Corpora.rows("SELECT * FROM mcp_disclosure_grants WHERE workspace_id=? AND id=?", [
             Store.workspace(),
             id
           ]) do
        [row] ->
          members =
            Corpora.rows(
              "SELECT source_id,revision_id,body_hash,passage_set_id FROM mcp_disclosure_grant_items WHERE grant_id=? ORDER BY source_id",
              [id]
            )

          {:ok, row |> Map.update!("profile", &Corpora.decode/1) |> Map.put("members", members)}

        _ ->
          {:error, :client_grant_unavailable}
      end
    else
      {:error, :client_grant_unavailable}
    end
  end

  defp current_members(corpus_id) do
    rows =
      Corpora.rows(
        "SELECT m.source_id,m.revision_id,r.body_hash,m.passage_set_id,s.provider,c.provider AS connection_provider,c.status AS connection_status,s.status AS source_status,s.latest_revision_id FROM corpus_members m JOIN evidence_sources s ON s.id=m.source_id AND s.workspace_id=m.workspace_id JOIN evidence_revisions r ON r.id=m.revision_id AND r.source_id=m.source_id AND r.workspace_id=m.workspace_id JOIN source_connections c ON c.id=s.connection_id AND c.workspace_id=m.workspace_id WHERE m.workspace_id=? AND m.corpus_id=? AND m.status='active' ORDER BY m.source_id LIMIT 501",
        [Store.workspace(), corpus_id]
      )

    [%{"n" => count}] =
      Corpora.rows(
        "SELECT count(*) AS n FROM corpus_members WHERE workspace_id=? AND corpus_id=? AND status='active'",
        [Store.workspace(), corpus_id]
      )

    if length(rows) == count and length(rows) in 1..500 and
         Enum.all?(
           rows,
           &(&1["provider"] == "local" and &1["connection_provider"] == "local" and
               &1["connection_status"] == "active" and &1["source_status"] == "active" and
               &1["latest_revision_id"] == &1["revision_id"] and
               Corpora.uuid?(&1["passage_set_id"]))
         ),
       do:
         {:ok, Enum.map(rows, &Map.take(&1, ~w(source_id revision_id body_hash passage_set_id)))},
       else: {:error, :unsupported_disclosure_scope}
  end

  defp digest(row),
    do: Contracts.digest(Map.take(row, @hash_fields) |> Map.put("members", row["members"]))

  defp insert_items(row) do
    Enum.reduce_while(row["members"], :ok, fn item, :ok ->
      case Repo.query(
             "INSERT INTO mcp_disclosure_grant_items(grant_id,source_id,revision_id,body_hash,passage_set_id) VALUES(?,?,?,?,?)",
             [
               row["id"],
               item["source_id"],
               item["revision_id"],
               item["body_hash"],
               item["passage_set_id"]
             ],
             log: false
           ) do
        {:ok, _} -> {:cont, :ok}
        _ -> {:halt, {:error, :invalid_disclosure_grant}}
      end
    end)
  end
end

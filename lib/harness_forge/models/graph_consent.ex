defmodule HarnessForge.Models.GraphConsent do
  @moduledoc "Paged explicit source grants and reusable exact-scope consent certificates."
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.{GraphManifests, Store}
  alias HarnessForge.Models.{StageAuthority, StageControl}
  @categories ~w(company_context source_body)

  @doc "Explicit operator grant for this exact source certificate and immutable stage pin."
  def start_grant(auth, stage_id), do: start(auth, stage_id, nil, "grant")

  @doc "Certify existing grants without adding or broadening any source permission."
  def start_verification(auth, stage_id, consent_id),
    do: start(auth, stage_id, consent_id, "verify")

  defp start(auth, stage_id, consent_id, mode) do
    synchronize(fn ->
      with {:ok, _} <- StageControl.graph_current(auth),
           {:ok, m} <-
             GraphManifests.validate_scope_certificate(
               auth.manifest_id,
               auth.manifest_digest,
               auth
             ),
           {:ok, pin} <- StageAuthority.load_pin(stage_id),
           true <- Enum.any?(auth.stage_pins, &(&1 == pin)),
           {:ok, consent} <- consent(pin, consent_id, mode) do
        identity = %{
          "source_manifest_id" => m["manifest_id"],
          "source_manifest_digest" => m["digest"],
          "stage_config_id" => stage_id,
          "stage_config_hash" => pin["config_digest"],
          "consent_id" => consent,
          "consent_revision" => pin["consent_revision"],
          "category_policy_hash" => policy(),
          "semantic_generation" => auth.semantic_generation,
          "authorization_generation" => auth.authorization_generation,
          "source_count" => m["effective_source_count"]
        }

        id = Ecto.UUID.generate()
        now = DateTime.to_iso8601(Store.now())

        with {:ok, _} <-
               Repo.query(
                 """
                 INSERT INTO graph_consent_certificates(id,workspace_id,source_manifest_id,source_manifest_digest,
                  stage_config_id,stage_config_hash,consent_id,consent_revision,category_policy_hash,
                  semantic_generation,authorization_generation,source_count,mode,state,inserted_at,updated_at)
                 VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'checking',?,?)
                 ON CONFLICT(source_manifest_id,stage_config_id,consent_id,category_policy_hash) DO NOTHING
                 """,
                 [
                   id,
                   Store.workspace(),
                   identity["source_manifest_id"],
                   identity["source_manifest_digest"],
                   stage_id,
                   pin["config_digest"],
                   consent,
                   pin["consent_revision"],
                   policy(),
                   auth.semantic_generation,
                   auth.authorization_generation,
                   m["effective_source_count"],
                   mode,
                   now,
                   now
                 ]
               ),
             {:ok, %{rows: [[found]]}} <-
               Repo.query(
                 "SELECT id FROM graph_consent_certificates WHERE workspace_id=? AND source_manifest_id=? AND stage_config_id=? AND consent_id=? AND category_policy_hash=?",
                 [Store.workspace(), auth.manifest_id, stage_id, consent, policy()]
               ) do
          {:ok,
           %{
             "certificate_id" => found,
             "consent_id" => consent,
             "source_count" => m["effective_source_count"]
           }}
        end
      else
        _ -> {:error, :consent_required}
      end
    end)
  end

  def advance(id, auth) do
    synchronize(fn ->
      with {:ok, row} <- current_row(id, auth), true <- row["state"] in ~w(checking sealed) do
        if row["state"] == "sealed" do
          {:ok, dto(row)}
        else
          advance_page(row, auth)
        end
      else
        _ -> {:error, :consent_required}
      end
    end)
  end

  def validate(id, auth, pin, consent_id) do
    with {:ok, row} <- current_row(id, auth),
         true <-
           row["state"] == "sealed" and row["stage_config_id"] == pin["id"] and
             row["stage_config_hash"] == pin["config_digest"] and row["consent_id"] == consent_id and
             row["next_ordinal"] == row["source_count"] and row["digest"] == identity_digest(row) do
      :ok
    else
      _ -> {:error, :consent_required}
    end
  end

  def certificate_for(auth, pin, consent_id) do
    with {:ok, %{rows: [[id]]}} <-
           Repo.query(
             """
             SELECT id FROM graph_consent_certificates WHERE workspace_id=? AND source_manifest_id=?
               AND stage_config_id=? AND consent_id=? AND category_policy_hash=? AND state='sealed'
             """,
             [Store.workspace(), auth.manifest_id, pin["id"], consent_id, policy()]
           ),
         :ok <- validate(id, auth, pin, consent_id) do
      {:ok, id}
    else
      _ -> {:error, :consent_required}
    end
  end

  defp advance_page(row, auth) do
    with {:ok, %{rows: rows}} <-
           Repo.query(
             """
             SELECT ordinal,source_id,revision_id,content_hash FROM origin_dependencies
             WHERE workspace_id=? AND manifest_id=? AND kind='source_revision' AND ordinal>=?
             ORDER BY ordinal LIMIT 100
             """,
             [Store.workspace(), row["source_manifest_id"], row["next_ordinal"]]
           ),
         true <- length(rows) == min(100, row["source_count"] - row["next_ordinal"]),
         true <-
           Enum.with_index(rows, row["next_ordinal"])
           |> Enum.all?(fn {[ordinal, _, _, _], i} -> ordinal == i end),
         :ok <- check_rows(row, rows),
         {:ok, _} <- StageControl.graph_current(auth) do
      next = row["next_ordinal"] + length(rows)
      sealed = next == row["source_count"]

      with {:ok, %{num_rows: 1}} <-
             Repo.query(
               """
               UPDATE graph_consent_certificates SET next_ordinal=?,state=?,digest=?,updated_at=?
               WHERE workspace_id=? AND id=? AND state='checking' AND next_ordinal=?
               """,
               [
                 next,
                 if(sealed, do: "sealed", else: "checking"),
                 if(sealed, do: identity_digest(row)),
                 DateTime.to_iso8601(Store.now()),
                 Store.workspace(),
                 row["id"],
                 row["next_ordinal"]
               ]
             ) do
        {:ok,
         dto(
           Map.merge(row, %{
             "next_ordinal" => next,
             "state" => if(sealed, do: "sealed", else: "checking")
           })
         )}
      end
    else
      _ -> {:error, :consent_required}
    end
  end

  defp check_rows(row, rows) do
    Enum.reduce_while(rows, :ok, fn [_, s, r, h], :ok ->
      result =
        Enum.reduce_while(@categories, :ok, fn category, :ok ->
          if row["mode"] == "grant" do
            Repo.query!(
              "INSERT INTO stage_consent_sources(workspace_id,consent_id,source_id,revision_id,body_hash,category) VALUES(?,?,?,?,?,?) ON CONFLICT DO NOTHING",
              [Store.workspace(), row["consent_id"], s, r, h, category]
            )
          end

          case Repo.query(
                 "SELECT 1 FROM stage_consent_sources WHERE workspace_id=? AND consent_id=? AND source_id=? AND revision_id=? AND body_hash=? AND category=?",
                 [Store.workspace(), row["consent_id"], s, r, h, category]
               ) do
            {:ok, %{rows: [[1]]}} -> {:cont, :ok}
            _ -> {:halt, {:error, :consent_required}}
          end
        end)

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp current_row(id, auth) do
    with {:ok, _} <- StageControl.graph_current(auth),
         {:ok, m} <-
           GraphManifests.validate_scope_certificate(auth.manifest_id, auth.manifest_digest, auth),
         {:ok, %{rows: [values], columns: columns}} <-
           Repo.query("SELECT * FROM graph_consent_certificates WHERE workspace_id=? AND id=?", [
             Store.workspace(),
             id
           ]),
         row = Map.new(Enum.zip(columns, values)),
         true <-
           row["source_manifest_id"] == m["manifest_id"] and
             row["source_manifest_digest"] == m["digest"] and
             row["source_count"] == m["effective_source_count"] and
             row["category_policy_hash"] == policy() and
             row["semantic_generation"] == auth.semantic_generation and
             row["authorization_generation"] == auth.authorization_generation,
         {:ok, pin} <- StageAuthority.load_pin(row["stage_config_id"]),
         true <-
           pin["config_digest"] == row["stage_config_hash"] and
             Enum.any?(auth.stage_pins, &(&1 == pin)),
         {:ok, _} <- consent(pin, row["consent_id"], "verify") do
      {:ok, row}
    else
      _ -> {:error, :consent_required}
    end
  end

  defp consent(pin, nil, "grant") do
    id = Ecto.UUID.generate()

    with {:ok, _} <-
           Repo.query(
             "INSERT INTO stage_consent_revisions(id,workspace_id,stage_config_id,revision,state,inserted_at) VALUES(?,?,?,?,'active',?)",
             [
               id,
               Store.workspace(),
               pin["id"],
               pin["consent_revision"],
               DateTime.to_iso8601(Store.now())
             ]
           ) do
      {:ok, id}
    else
      _ -> {:error, :consent_required}
    end
  end

  defp consent(pin, id, "verify") do
    with {:ok, %{rows: [[1]]}} <-
           Repo.query(
             "SELECT 1 FROM stage_consent_revisions WHERE workspace_id=? AND id=? AND stage_config_id=? AND revision=? AND state='active'",
             [Store.workspace(), id, pin["id"], pin["consent_revision"]]
           ) do
      {:ok, id}
    else
      _ -> {:error, :consent_required}
    end
  end

  defp consent(_, _, _), do: {:error, :consent_required}

  defp identity_digest(row),
    do:
      Contracts.digest(
        Map.take(
          row,
          ~w(source_manifest_id source_manifest_digest stage_config_id stage_config_hash consent_id consent_revision category_policy_hash semantic_generation authorization_generation source_count)
        )
      )

  defp policy,
    do: Contracts.digest(%{"format" => "graph-stage-categories-v1", "categories" => @categories})

  defp dto(row), do: Map.take(row, ~w(id state next_ordinal source_count consent_id))

  defp synchronize(fun),
    do: HarnessForge.Privacy.Purge.synchronize(fn -> Store.transaction(fun) end)
end
